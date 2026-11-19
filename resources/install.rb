# frozen_string_literal: true
#
# Cookbook:: chef_client_updater_enterprise
# Resource:: install
#
# Copyright:: 2026, Corey Hemminger
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

unified_mode true

require 'fileutils'

resource_name :chef_client_updater_enterprise_install
provides :chef_client_updater_enterprise_install

use 'partials'

property :license_key, [String, NilClass],
         sensitive: true,
         desired_state: false,
         description: 'Chef license key (CHEF_LICENSE_KEY). Required for chef-ice downloads.',
         default: lazy { ENV.fetch('CHEF_LICENSE_KEY', nil) }

property :product_name, String,
         description: 'Commercial Download API product key and native OS package name.',
         default: 'chef-ice'

property :channel, [String, Symbol],
         equal_to: %i(stable current),
         coerce: proc { |c| c.to_s.downcase.to_sym },
         description: 'Download channel. Accepts a String or a Symbol in any casing.',
         default: :stable

property :download_dir, String,
         desired_state: false,
         default: lazy { Chef::Config[:file_cache_path] },
         description: 'Directory to stage downloaded packages before install.'

property :download_url, String,
         desired_state: false,
         description: 'Direct package URL bypassing the Commercial Download API. Use for airgapped environments or local file servers.'

property :checksum, String,
         desired_state: false,
         description: 'SHA256 checksum for the direct download_url package.'

property :download_retries, Integer,
         desired_state: false,
         callbacks: { 'must be zero or greater' => ->(v) { v >= 0 } },
         default: 5,
         description: 'Times to retry the package download. A newly published release can be ' \
                      'advertised by the Commercial Download API before it has propagated to the ' \
                      "caller's nearest CDN edge (most often for the Windows MSI), so the first " \
                      'attempts may 403/404 or return a body that fails checksum verification.'

property :download_retry_delay, Integer,
         desired_state: false,
         callbacks: { 'must be zero or greater' => ->(v) { v >= 0 } },
         default: 30,
         description: 'Seconds to wait between package download attempts. Raise this (or ' \
                      'download_retries) if a slow CDN edge needs longer to serve a brand-new release.'

property :manage_binlinks, [true, false],
         desired_state: false,
         default: true,
         description: 'Automatically run the binlinks resource after a successful install.'

property :update_scheduler_resources, [true, false],
         desired_state: false,
         default: true,
         description: 'When this converge actually installs a new chef-ice version, reconverge any ' \
                      'chef_client_cron/chef_client_launchd/chef_client_systemd_timer/' \
                      'chef_client_scheduled_task resources found in the resource collection, ' \
                      'explicitly setting their chef_binary_path to the just-installed Habitat ' \
                      'binary so the next scheduled run uses the new chef-client. This works ' \
                      'regardless of whether those resources are declared before or after this one, ' \
                      'since Chef fully compiles the resource collection before convergence begins. ' \
                      'Requires manage_binlinks true (or an externally managed, current binlink). ' \
                      'Set false only if an external mechanism already keeps those resources\' ' \
                      'chef_binary_path current.'

property :preserve_omnibus, [true, false],
         desired_state: false,
         default: true,
         description: 'Pass --preserve-omnibus true to migrate-ice to keep the existing omnibus Chef installation.'

property :fstab_handling, String,
         equal_to: %w(apply fail ignore),
         desired_state: false,
         default: lazy { preserve_omnibus ? 'ignore' : 'apply' },
         description: 'Value passed to migrate-ice\'s --fstab flag on the migration (non---fresh-install) code ' \
                      'path, controlling what it does when /opt/chef is its own dedicated mount point: ' \
                      '"apply" (migrate-ice\'s own default) remounts that device at /hab, "fail" aborts, ' \
                      '"ignore" leaves the mount alone. Defaults to "ignore" whenever preserve_omnibus is true, ' \
                      'since preserving the omnibus install and moving its filesystem out from under it are ' \
                      'contradictory, and "apply" hard-fails in that case (see resources/install.rb).'

default_action :install

action_class do
  include ChefClientUpdaterEnterprise::Helpers

  # Resolves the artifact's download URL, sha256 and concrete version via Chef's
  # Commercial Download API. Returns a Hash with 'url', 'sha256' and 'version'.
  def artifact_info
    if new_resource.license_key.nil? || new_resource.license_key.to_s.strip.empty?
      raise Chef::Exceptions::ConfigurationError,
            'chef_client_updater_enterprise_install: license_key is required. ' \
            "Set the CHEF_LICENSE_KEY environment variable or pass `license_key 'YOUR_KEY'` " \
            'to the resource. A valid license key is required to download chef-ice packages.'
    end

    api_platform, api_platform_version = download_api_platform_info

    commercial_artifact_metadata(
      product: new_resource.product_name,
      version: new_resource.version,
      channel: new_resource.channel,
      license_key: new_resource.license_key,
      platform: api_platform,
      platform_version: api_platform_version,
      architecture: node['kernel']['machine'] == 'arm64' ? 'aarch64' : node['kernel']['machine']
    )
  end

  # Resolves the package file extension from the URL the artifact is actually
  # fetched from, raising an actionable error when it cannot be derived. Both call
  # sites work from a full file URL (see Helpers#package_extension_from_url), so a
  # nil here means the URL does not point at an installable package.
  def package_extension_for(url)
    ext = package_extension_from_url(url)
    return ext if ext

    raise Chef::Exceptions::ValidationFailed,
          'chef_client_updater_enterprise_install: could not determine a package type from ' \
          "#{url.to_s.split('?').first} — the URL's path must end in one of " \
          "#{ChefClientUpdaterEnterprise::Helpers::PACKAGE_EXTENSIONS.map { |e| ".#{e}" }.join(', ')}."
  end
end

action :install do
  # return early if the requested version is already installed
  unless new_resource.version == 'latest'
    installed = current_installed_version(new_resource.product_name, new_resource.habitat_package)
    # The version lookup can report a release whose directory has no IDENT (an
    # incomplete migration). Skip only when a complete release of that version
    # exists, so an incomplete one reaches the install path and its verification.
    complete = hab_pkg_dirs(new_resource.habitat_package).any? { |d| hab_dir_version(d) == new_resource.version }
    if installed == new_resource.version && complete
      Chef::Log.debug("chef_client_updater_enterprise_install: #{new_resource.product_name} #{new_resource.version} already installed, skipping.")
      # A failed earlier run may have left the installer settings file behind.
      file "remove stale #{ChefClientUpdaterEnterprise::Helpers::CHEF_ENV_FILE}" do
        path ChefClientUpdaterEnterprise::Helpers::CHEF_ENV_FILE
        action :delete
        sensitive true
      end unless windows?
      return
    end
  end

  # Declares the chef_client_updater_enterprise_scheduler_reconvergence resource up front so later
  # `notifies` calls have something to target. This resource repoints any
  # chef_client_scheduled_task/chef_client_cron/chef_client_launchd/chef_client_systemd_timer resource
  # in the run's resource collection at the chef-ice version this converge just installed, so the next
  # SCHEDULED run uses the new client instead of whatever binary the schedule was originally written
  # against.
  chef_client_updater_enterprise_scheduler_reconvergence 'default' do
    habitat_package new_resource.habitat_package
    version new_resource.version
    action :nothing
    only_if { new_resource.update_scheduler_resources }
  end

  if new_resource.download_url
    # Direct download path — skip the Commercial Download API entirely
    pkg_url = new_resource.download_url
    pkg_ext = package_extension_for(pkg_url)
    safe_ver = new_resource.version == 'latest' ? 'custom' : new_resource.version
    pkg_path = ::File.join(new_resource.download_dir, "#{new_resource.product_name}-#{safe_ver}.#{pkg_ext}")
    file_checksum = new_resource.checksum
    # 'latest' has no known version when bypassing the Commercial Download API; the package
    # resource's own source-file inspection is the only idempotency signal available.
    pkg_version = new_resource.version == 'latest' ? nil : new_resource.version
  else
    # Commercial Download API path — license validation happens inside artifact_info
    artifact = artifact_info
    raise "No artifact found for #{new_resource.product_name} #{new_resource.version}" if artifact.nil?

    pkg_url = artifact['url']
    pkg_ext = package_extension_for(pkg_url)
    pkg_path = ::File.join(new_resource.download_dir, "#{new_resource.product_name}-#{artifact['version']}.#{pkg_ext}")
    file_checksum = artifact['sha256']
    pkg_version = artifact['version']
  end

  # Downloads routinely fail for a few minutes after a new release appears: the
  # Commercial Download API advertises the version as soon as it is published, but
  # the artifact still has to propagate to the caller's nearest CDN edge. Until it
  # does, that edge answers with a 403/404 (or, worse, a short error-page body with
  # a 200). This is most pronounced for the Windows MSI.
  #
  # Two properties handle that, and they are load-bearing together:
  #
  #   retries/retry_delay — re-run the whole download on ANY failure, including the
  #     CDN's 403/404 and the verify failure below.
  #   verify — remote_file's own `checksum` property does NOT verify the download.
  #     It only compares an ALREADY-PRESENT local file to decide whether to skip
  #     fetching (Chef::Provider::RemoteFile::Content#current_resource_matches_target_checksum?).
  #     The verify block is what actually enforces the API-advertised sha256 against
  #     the freshly-staged tempfile, so a truncated transfer or a CDN error page is
  #     rejected instead of being handed to rpm/dpkg/msiexec as a "package".
  #
  # Retrying is safe: verification happens before the tempfile is moved into place,
  # so a rejected body never becomes the cached artifact, and
  # CacheControlData.load_and_validate discards its saved etag/mtime whenever they
  # don't match the local file — the retry re-downloads in full rather than being
  # answered with a 304.
  expected_checksum = file_checksum

  remote_file pkg_path do
    source pkg_url
    checksum expected_checksum if expected_checksum
    retries new_resource.download_retries
    retry_delay new_resource.download_retry_delay
    if expected_checksum
      verify do |path|
        actual = Chef::Digester.checksum_for_file(path)
        unless actual == expected_checksum
          Chef::Log.warn('chef_client_updater_enterprise_install: downloaded artifact checksum ' \
                         "#{actual} does not match the expected #{expected_checksum} — the CDN " \
                         'has most likely not finished propagating this release yet; retrying.')
        end
        actual == expected_checksum
      end
    end
    sensitive true
    action :create
  end

  # chef-ice releases up to and including 19.4.50 predate the installer fixes this
  # resource relies on (settings passed to migrate-ice via /tmp/chef_env or MSI
  # properties, skip-binlinking, side-by-side upgrades). Fail before touching the
  # system rather than half-installing a release whose installer ignores them.
  unsupported_chef_ice_version!(pkg_version) if pkg_version

  # The fixed installers always run migrate-ice themselves. If THIS chef-client is
  # the omnibus install, migrate-ice must not be asked to delete /opt/chef: its
  # running-client guard would wait on this very process and fail. Removal of the
  # omnibus install is chef_client_updater_enterprise_remove_omnibus's job.
  preserve_omnibus = new_resource.preserve_omnibus
  if !preserve_omnibus && running_under_omnibus?
    Chef::Log.warn('chef_client_updater_enterprise_install: preserve_omnibus false ignored while ' \
                   'chef-client itself runs from the omnibus install; use ' \
                   'chef_client_updater_enterprise_remove_omnibus to remove it on a later run.')
    preserve_omnibus = true
  end

  # True when the target version's Habitat package is already on disk. Nil
  # pkg_version (download_url with version 'latest') leaves idempotency to the
  # native package resource below.
  hab_pkg = new_resource.habitat_package
  already_current = lambda do
    pkg_version && hab_pkg_dirs(hab_pkg).any? { |d| hab_dir_version(d) == pkg_version }
  end

  installed_version = current_native_version(new_resource.product_name)
  pkg_action = installed_version.nil? ? :install : :upgrade
  reconverge = 'chef_client_updater_enterprise_scheduler_reconvergence[default]'

  if windows?
    # PowerShell's PostInstall custom action reads CHEF_LICENSE_KEY only from the
    # environment, so it is set Machine-scoped just for the msiexec run. `:before`
    # runs windows_package in why-run first and only fires when it would install,
    # so the key is written only for a real install and removed afterwards.
    repair_windows_path!

    # license_key is nil on the download_url path; windows_env rejects a nil value
    # even with action :nothing, so stage it only when there is a key.
    license_env = 'windows_env[CHEF_LICENSE_KEY for chef-ice MSI install]' if new_resource.license_key
    if license_env
      windows_env 'CHEF_LICENSE_KEY for chef-ice MSI install' do
        key_name 'CHEF_LICENSE_KEY'
        value new_resource.license_key
        sensitive true
        action :nothing
      end
    end

    # TARGETDIR pins the install root to C:\ (see WINDOWS_MSI_TARGETDIR).
    msi_options = ["TARGETDIR=#{ChefClientUpdaterEnterprise::Helpers::WINDOWS_MSI_TARGETDIR}"]
    msi_options << 'CHEF_PRESERVE_OMNIBUS=1' if preserve_omnibus
    msi_options << 'CHEF_SKIP_BINLINKING=1' unless new_resource.manage_binlinks
    # Old releases stay until `cleanup`; the installer must not remove them.
    msi_options << 'CHEF_SKIP_OLD_RELEASE_REMOVAL=1'

    win_pkg = windows_package new_resource.product_name do
      source pkg_path
      version pkg_version if pkg_version
      installer_type :msi
      options msi_options.join(' ')
      # The MSI runs migrate-ice inside the transaction: 7-13 minutes observed.
      timeout 1800
      action :install
      if license_env
        notifies :create, license_env, :before
        notifies :delete, license_env, :delayed
      end
      notifies :reconverge, reconverge, :delayed
    end

    # Same failure mode as RPM/DEB: the MSI stays registered when migrate-ice
    # left the release incomplete, so windows_package reports "up to date".
    # Reinstall the same MSI in maintenance mode. Properties must be passed on
    # an /i REINSTALL=ALL command line; `msiexec /fa` dropped them in testing
    # and migrate-ice then removed older releases. A ProductCode-only repair
    # failed (1706, source not found) once the original MSI was gone.
    if pkg_version
      repair_needed = lambda do
        !win_pkg.updated_by_last_action? && !already_current.call && native_version_installed?(new_resource.product_name, pkg_version)
      end
      # Windows Installer accepts a maintenance install only from a package with
      # the file name it recorded at install time (SourceList PackageName);
      # another name fails SecureRepair with 1603. Stage the downloaded MSI under
      # that name next to it. `v` re-caches the package from this source.
      repair_msi = Chef::DelayedEvaluator.new do
        name = windows_msi_package_name(new_resource.product_name, pkg_version)
        # File names are case-insensitive on Windows: same name means no copy.
        name && !name.casecmp?(::File.basename(pkg_path)) ? ::File.join(::File.dirname(pkg_path), name) : pkg_path
      end
      remote_file "stage #{new_resource.product_name} #{pkg_version} MSI for repair" do
        path repair_msi
        source lazy { "file:///#{pkg_path.tr('\\', '/')}" }
        only_if { repair_needed.call && repair_msi.call(self) != pkg_path }
      end

      win_log = ::File.join(new_resource.download_dir, "#{new_resource.product_name}-#{pkg_version}-repair.log").tr('/', '\\')
      execute "reinstall #{new_resource.product_name} #{pkg_version}" do
        command(lazy { "msiexec.exe /i \"#{repair_msi.call(self).tr('/', '\\')}\" REINSTALL=ALL REINSTALLMODE=vamus #{msi_options.join(' ')} /qn /norestart /l*v \"#{win_log}\"" })
        returns [0, 3010]
        timeout 1800
        only_if { repair_needed.call }
        if license_env
          notifies :create, license_env, :before
          notifies :delete, license_env, :delayed
        end
        notifies :reconverge, reconverge, :delayed
      end
    end
  else
    # The rpm/deb/dmg post-install scripts read their settings from /tmp/chef_env
    # (root-owned, not group/world writable; parsed, never sourced) and delete it on
    # exit whatever the outcome. It is written only via a `:before` notification, so
    # it exists only when the package resource is actually about to install.
    env_lines = []
    env_lines << "CHEF_PRESERVE_OMNIBUS=#{preserve_omnibus}"
    env_lines << "CHEF_SKIP_BINLINKING=#{!new_resource.manage_binlinks}"
    # Old releases stay until `cleanup`; the installer must not remove them.
    env_lines << 'CHEF_SKIP_OLD_RELEASE_REMOVAL=true'
    env_lines << "CHEF_FSTAB=#{new_resource.fstab_handling}" unless platform?('mac_os_x')
    env_lines << "CHEF_LICENSE_KEY=#{new_resource.license_key}" if new_resource.license_key

    file ChefClientUpdaterEnterprise::Helpers::CHEF_ENV_FILE do
      content "#{env_lines.join("\n")}\n"
      owner 'root'
      group 0
      mode '0600'
      sensitive true
      action :nothing
    end
    chef_env = "file[#{ChefClientUpdaterEnterprise::Helpers::CHEF_ENV_FILE}]"

    if platform?('mac_os_x')
      unless pkg_version
        raise Chef::Exceptions::ValidationFailed,
              'chef_client_updater_enterprise_install: an explicit version is required with ' \
              'download_url on macOS (the dmg volume is named after it).'
      end

      # dmg_package's own idempotency checks a .app or an unversioned pkgutil receipt,
      # neither of which tells chef-ice releases apart, so the Habitat package
      # directory is the guard.
      dmg_package "#{new_resource.product_name}-#{pkg_version}" do
        file pkg_path
        type 'pkg'
        volumes_dir "Chef Infra Client #{pkg_version}"
        not_if { already_current.call }
        notifies :create, chef_env, :before
        notifies :delete, chef_env, :delayed
        notifies :reconverge, reconverge, :delayed
      end
    elsif platform_family?('debian')
      deb_pkg = dpkg_package new_resource.product_name do
        source pkg_path
        version pkg_version if pkg_version
        action pkg_action
        not_if { already_current.call }
        notifies :create, chef_env, :before
        notifies :delete, chef_env, :delayed
        notifies :reconverge, reconverge, :delayed
      end

      # Same failure mode as RPM below: dpkg records the version even when
      # postinst (migrate-ice) failed, and dpkg_package then reports "up to
      # date". `dpkg -i` of the same .deb re-runs postinst configure, and
      # migrate-ice re-extracts the exact incomplete target release.
      if pkg_version
        execute "reinstall #{new_resource.product_name} #{pkg_version}" do
          command ['dpkg', '-i', pkg_path]
          environment('DEBIAN_FRONTEND' => 'noninteractive')
          only_if { !deb_pkg.updated_by_last_action? && !already_current.call && native_version_installed?(new_resource.product_name, pkg_version) }
          notifies :create, chef_env, :before
          notifies :delete, chef_env, :delayed
          notifies :reconverge, reconverge, :delayed
        end
      end
    else
      # rpm_package works on every rpm platform family (dnf/yum/zypper alike) from a
      # local file. chef-ice's %preun only acts on a full erase, so an upgrade
      # leaves the previous version's /hab/pkgs directory in place.
      rpm_pkg = rpm_package new_resource.product_name do
        source pkg_path
        version pkg_version if pkg_version
        action pkg_action
        not_if { already_current.call }
        notifies :create, chef_env, :before
        notifies :delete, chef_env, :delayed
        notifies :reconverge, reconverge, :delayed
      end

      # rpm records a package even when its %post (migrate-ice) fails, so a
      # failed migration leaves rpm reporting the target version while no
      # release with IDENT exists under /hab/pkgs. rpm_package then reports
      # "up to date" forever (Chef's package provider short-circuits on an
      # installed version match), so reinstall the same file explicitly in
      # exactly that state. --replacepkgs re-runs %post; migrate-ice removes the
      # exact incomplete target release directory (no IDENT) and retries. If it
      # still fails, the verification below fails the converge.
      if pkg_version
        execute "reinstall #{new_resource.product_name} #{pkg_version}" do
          command ['rpm', '-U', '--replacepkgs', pkg_path]
          only_if { !rpm_pkg.updated_by_last_action? && !already_current.call && native_version_installed?(new_resource.product_name, pkg_version) }
          notifies :create, chef_env, :before
          notifies :delete, chef_env, :delayed
          notifies :reconverge, reconverge, :delayed
        end
      end
    end
  end

  # Native installers can report success after migrate-ice failed (rpm only
  # warns on a failing %post). Fail the converge if the expected release is
  # not on disk with an IDENT. This proves the release was unpacked, not that
  # every migration step succeeded. Skipped when the version is unknown
  # (download_url with version 'latest').
  if pkg_version
    ruby_block "verify #{hab_pkg} #{pkg_version} release" do
      block do
        raise "chef_client_updater_enterprise_install: #{new_resource.product_name} #{pkg_version} " \
              "was installed but no #{hab_pkg} #{pkg_version} release with an IDENT file exists under " \
              "#{hab_pkg_root(hab_pkg)}. The migration did not complete; see the migrate-ice log " \
              '(/var/log/chef-hab-migrate.log; on Windows %TEMP%\\chef-migration-logs\\chef-hab-migrate.log ' \
              'and C:\\ProgramData\\Chef\\Logs\\chef-infra-install.log).'
      end
      not_if { already_current.call }
    end
  end

  # Remove a settings file left behind by an earlier failed run. Declared after
  # the package step, so the installer has already consumed it.
  file "remove stale #{ChefClientUpdaterEnterprise::Helpers::CHEF_ENV_FILE}" do
    path ChefClientUpdaterEnterprise::Helpers::CHEF_ENV_FILE
    action :delete
    sensitive true
  end unless windows?

  unless windows? || hab_binary
    link '/bin/hab' do
      to lazy {
        pkg = hab_pkg_dirs('chef/hab').any? ? 'chef/hab' : 'core/hab'
        target_dir = hab_pkg_dirs(pkg).last
        raise "chef_client_updater_enterprise_install: No Habitat #{pkg} package found to link." unless target_dir

        ::File.join(target_dir, 'bin', 'hab')
      }
      link_type :symbolic
      only_if { hab_pkg_dirs('chef/hab').any? || hab_pkg_dirs('core/hab').any? }
    end
  end

  if new_resource.manage_binlinks
    chef_client_updater_enterprise_binlinks 'default' do
      habitat_package new_resource.habitat_package
      action :create
    end
  end
end
