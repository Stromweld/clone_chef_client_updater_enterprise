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

  def validate_license!
    if new_resource.license_key.nil? || new_resource.license_key.to_s.strip.empty?
      raise Chef::Exceptions::ConfigurationError,
            'chef_client_updater_enterprise_install: license_key is required. ' \
            "Set the CHEF_LICENSE_KEY environment variable or pass `license_key 'YOUR_KEY'` " \
            'to the resource. A valid license key is required to download chef-ice packages.'
    end
  end

  # Resolves the artifact's download URL, sha256 and concrete version via Chef's
  # Commercial Download API. Returns a Hash with 'url', 'sha256' and 'version'.
  def artifact_info
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

  # chef_client_cron/launchd/systemd_timer/scheduled_task's chef_binary_path default varies by
  # Chef Infra Client version: newer releases (e.g. what chef-ice itself ships) default it to a
  # lazy, hab-aware `chef_client_hab_binary_path` block.
  def reconverge_scheduler_resources(resource_collection, resolved_binary_path)
    scheduler_types = %i(chef_client_scheduled_task chef_client_cron chef_client_launchd chef_client_systemd_timer)
    found = resource_collection.all_resources.select { |r| scheduler_types.include?(r.resource_name) }

    if found.empty?
      Chef::Log.debug('chef_client_updater_enterprise: no chef-client scheduler resources found to reconverge.')
      return
    end

    found.each do |resource|
      Chef::Log.info("chef_client_updater_enterprise: reconverging #{resource} for the newly installed binary at #{resolved_binary_path}.")
      resource.chef_binary_path(resolved_binary_path) if resource.respond_to?(:chef_binary_path)
      resource.action.each { |a| resource.run_action(a) }
    end
  end

  def reconverge_installed_scheduler_resources(new_resource)
    resolved_binary_path = chef_client_hab_binary_path(new_resource.habitat_package, new_resource.version)
    update_scheduler_enabled = new_resource.update_scheduler_resources
    resource_collection = run_context.root_run_context.resource_collection

    if update_scheduler_enabled && resolved_binary_path.nil?
      Chef::Log.warn(
        'chef_client_updater_enterprise: update_scheduler_resources is true but no installed ' \
        "#{new_resource.habitat_package} Habitat package was found to resolve a chef_binary_path from."
      )
    end

    return unless update_scheduler_enabled && resolved_binary_path && ::File.exist?(resolved_binary_path)

    reconverge_scheduler_resources(resource_collection, resolved_binary_path)
  end
end

action :install do
  unless new_resource.version == 'latest'
    installed = current_installed_version(new_resource.product_name, new_resource.habitat_package)
    if installed == new_resource.version
      Chef::Log.debug("chef_client_updater_enterprise_install: #{new_resource.product_name} #{new_resource.version} already installed, skipping.")
      reconverge_installed_scheduler_resources(new_resource)
      return
    end
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
    # Commercial Download API path
    validate_license!

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

  # NOTE: `version` must be set explicitly here. Without it, dnf/yum/apt providers
  # treat ANY currently-installed version of `product_name` as satisfying an
  # unconstrained install request and silently no-op, even when `source` points at
  # a newer package artifact on disk (e.g. chef-ice 19.3.14 installed, 19.3.15
  # downloaded — the package resource would report "already installed").
  installed_version = current_native_version(new_resource.product_name)
  pkg_action = installed_version.nil? ? :install : :upgrade
  rhel_family = platform_family?('rhel', 'amazon', 'fedora', 'suse')
  debian_family = platform_family?('debian')

  if rhel_family
    # The habitat-based chef-ice packaging ships its actual payload under
    # per-version paths (/hab/pkgs/chef/chef-infra-client/<version>/...) that
    # never collide across releases, plus a handful of small *non-versioned*
    # convenience files shared by every release (e.g.
    # /hab/migration/bin/migrate-ice, /hab/migration/bin/CHANGELOG.md).
    #
    # A dnf/yum :upgrade transaction (or an :install with
    # --setopt=installonlypkgs, which still runs file-conflict checks across
    # every "installed" NEVRA) erases the ENTIRE previous version's directory
    # tree, including its versioned hab path, as part of installing the new
    # one. If the chef-client process executing this very converge is itself
    # running out of that old version's hab tree, its own dnf helper script
    # gets deleted mid-transaction and the converge crashes with ENOENT.
    # Meanwhile the non-versioned shared files above are legitimately owned
    # by every chef-ice release, so straightforward side-by-side installs
    # collide on those specific paths.
    #
    # Bypassing dnf/yum entirely for chef-ice and going straight to `rpm`
    # (via Chef's built-in rpm_package resource — still a first-class Chef
    # package resource, not a raw shell-out) solves the multi-version
    # preservation problem:
    #   * A plain `rpm -i` never removes a different, already-installed NEVRA
    #     of the same package name — it just adds a new rpm db entry, so the
    #     previous version's hab directory is left untouched automatically.
    #   * rpm itself never processes `Obsoletes:` (that's purely a dnf/yum
    #     depsolver behavior), so the legacy omnibus `chef` package is never
    #     at risk of being auto-removed via that mechanism.
    #   * `--replacefiles` force-overwrites just the handful of shared,
    #     non-versioned convenience files instead of erroring on the file
    #     conflict; "latest install wins" for those fixed paths is the
    #     desired behavior since they aren't part of the versioned hab tree.
    #
    # `--noscripts` is essential: chef-ice's own RPM %post scriptlet
    # unconditionally runs `/hab/migration/bin/migrate-ice apply airgap` on
    # every single install, with NO `--preserve-omnibus` flag and no hook to
    # inject one (it only reads a debug-logging env var). That scriptlet is
    # what actually deletes /opt/chef — dnf/yum obsoletes handling was never
    # the real culprit. Suppressing the package's own scriptlets and running
    # migrate-ice ourselves via the `execute` resource below (which DOES pass
    # `--preserve-omnibus` from the `preserve_omnibus` property) is the only
    # way to control that behavior. The tarball payload itself is still
    # extracted normally by rpm — only the scriptlet-driven auto-invocation
    # of migrate-ice is skipped.
    rpm_package new_resource.product_name do
      source pkg_path
      version pkg_version if pkg_version
      # `--nodigest` is required on top of `--replacefiles --noscripts`:
      # chef-ice's published RPMs are missing a modern per-file payload digest.
      # Whether missing-digest packages are rejected depends entirely on the
      # installed rpm binary's own default `_pkgverify_level` macro, Fedora 44's
      # bundled rpm 6.0.2 defaults `_pkgverify_level` to `digest` and hard-fails
      # with `package ... does not verify: no digest` otherwise. `--nodigest`
      # disables only this specific payload-digest check.
      options '--replacefiles --noscripts --nodigest'
      action :install
    end
  elsif debian_family
    # chef-ice's .deb packaging carries the exact same problem as the RPM:
    # its `postinst` maintainer script unconditionally invokes
    # `/hab/migration/bin/migrate-ice apply airgap ...` on every single
    # install/upgrade, with no flag or hook to inject --preserve-omnibus.
    # Unlike rpm, dpkg has no `--noscripts` equivalent — `dpkg -i` always
    # unpacks AND configures (i.e. runs postinst) in a single atomic
    # operation, so there is no single flag to suppress just the scriptlet.
    #
    # Instead we drive dpkg's own two-phase install lifecycle directly:
    #   1. `dpkg --unpack` extracts the payload (including
    #      /hab/migration/bin/migrate-ice and the migration tarball under
    #      /hab/migration/bundle/) and runs `preinst`, but explicitly stops
    #      short of running `postinst` — the package is left in dpkg's
    #      "unpacked" state, not yet "installed".
    #   2. Swap the just-unpacked migrate-ice binary for a no-op stub so
    #      that when `dpkg --configure` subsequently runs postinst, its
    #      `eval $MIGRATE_CMD` succeeds trivially instead of performing the
    #      real (uncontrolled) migration.
    #   3. `dpkg --configure` completes the postinst lifecycle against the
    #      stub, moving the package to "install ok installed" in dpkg's own
    #      database — dpkg itself sees a perfectly normal, successful
    #      install/upgrade.
    #   4. Restore the real migrate-ice binary. The platform-agnostic
    #      `execute 'migrate-ice apply airgap'` resource below then invokes
    #      it ourselves, passing --preserve-omnibus from the
    #      preserve_omnibus property.
    #
    # Unlike rpm, no --replacefiles-style flag is needed here: dpkg treats
    # this as a normal same-package upgrade (a single package "slot" per
    # name), so it freely overwrites its own previously-owned shared files
    # without any conflict — the RPM conflict only arose because two
    # *separate* NEVRA entries for the same package name were tracked
    # simultaneously, a concept dpkg's package database doesn't have (or
    # need) at all.
    #
    # A second, more destructive problem exists purely on the upgrade path
    # (confirmed live): chef-ice's `postrm` hardcodes the CURRENTLY
    # installed version number and, on removal, uninstalls that specific
    # hab package; if that leaves nothing but `core/hab` behind, it runs
    # `rm -rf /hab` unconditionally. Per dpkg's own documented maintainer
    # script ordering, upgrading an already-installed package invokes the
    # OLD package's `postrm upgrade <new-version>` as part of the SAME
    # `--unpack` step (old-prerm, new-preinst, [unpack new files],
    # old-postrm) — entirely before dpkg --configure ever runs, so
    # stubbing migrate-ice ahead of --configure (step 2 below) is too late:
    # by then the old postrm has already deleted the ENTIRE /hab tree,
    # including the brand new version's just-unpacked migration payload.
    # Neutralizing the old package's postrm immediately before --unpack
    # (only relevant when a prior version is actually installed) closes
    # this gap. dpkg overwrites this same info file with the NEW package's
    # own postrm during unpack, so nothing needs to be restored afterward.
    migrate_ice_bin = '/hab/migration/bin/migrate-ice'
    migrate_ice_backup = '/hab/migration/bin/migrate-ice.chef-updater-backup'
    old_postrm = "/var/lib/dpkg/info/#{new_resource.product_name}.postrm"
    # dpkg has no native "already at this exact version" idempotency check the
    # way rpm_package/windows_package provide — without this guard, the two
    # `execute` resources below would unconditionally re-run `dpkg --unpack`/
    # `--configure` on EVERY converge whenever `version` is 'latest' (the
    # top-level version guard at the top of this action only short-circuits
    # for an explicitly pinned, already-installed version).
    dpkg_already_current = pkg_version && current_native_version(new_resource.product_name) == pkg_version

    # Self-heal: a converge that died between stubbing migrate-ice and restoring
    # it (an unhandled error elsewhere in the run, a reboot, a SIGKILL) leaves the
    # real binary parked at migrate_ice_backup. Put it back BEFORE `dpkg --unpack`
    # runs — restoring afterwards would clobber the newly-unpacked release's
    # migrate-ice with the previous release's copy. Deliberately NOT guarded by
    # `dpkg_already_current`: a stranded backup has to be reclaimed regardless of
    # whether this converge goes on to install anything.
    ruby_block "restore migrate-ice stranded by an earlier converge (#{pkg_path})" do
      block do
        ::FileUtils.mv(migrate_ice_backup, migrate_ice_bin, force: true)
      end
      only_if { ::File.exist?(migrate_ice_backup) }
    end

    ruby_block "neutralize old #{new_resource.product_name} postrm before upgrade (#{pkg_path})" do
      block do
        ::File.write(old_postrm, "#!/bin/sh\nexit 0\n")
        ::FileUtils.chmod(0o755, old_postrm)
      end
      only_if { ::File.exist?(old_postrm) }
      not_if { dpkg_already_current }
    end

    execute "dpkg --unpack #{pkg_path}" do
      command "dpkg --unpack #{pkg_path}"
      not_if { dpkg_already_current }
    end

    # Steps 2-4 (stub migrate-ice, `dpkg --configure`, restore migrate-ice) are
    # deliberately ONE `ruby_block` with a `begin/ensure` rather than three
    # separately declared Chef resources. Chef has no cross-resource `ensure`:
    # when `dpkg --configure` fails, the run aborts and any separately-declared
    # "restore" resource never converges, leaving /hab/migration/bin/migrate-ice
    # as a permanent `#!/bin/sh exit 0` stub. Every subsequent converge would
    # then run `execute[migrate-ice apply airgap]` against that stub, which exits
    # 0 without extracting anything — chef-ice would appear to install
    # successfully forever while /hab/pkgs stayed empty. Keeping all three phases
    # in a single block guarantees the real binary is put back even when dpkg
    # raises, and the exception still propagates and fails the converge.
    ruby_block "dpkg --configure #{new_resource.product_name} with migrate-ice stubbed (#{pkg_path})" do
      block do
        ::FileUtils.mv(migrate_ice_bin, migrate_ice_backup, force: true) if ::File.exist?(migrate_ice_bin)
        ::File.write(migrate_ice_bin, "#!/bin/sh\nexit 0\n")
        ::FileUtils.chmod(0o755, migrate_ice_bin)

        begin
          shell_out!("dpkg --configure #{new_resource.product_name}")
        ensure
          ::FileUtils.mv(migrate_ice_backup, migrate_ice_bin, force: true) if ::File.exist?(migrate_ice_backup)
        end
      end
      not_if { dpkg_already_current }
    end
  elsif windows?
    # Unlike rpm/deb, chef-ice's Windows MSI has no `--noscripts`-equivalent
    # suppression mechanism available from outside — its own bundled
    # RunPostInstallFresh/RunPostInstallMigrate custom actions (a PostInstall.ps1
    # script embedded in the MSI) unconditionally invoke migrate-ice as a deferred
    # step of the msiexec transaction itself, with no supported way to skip or
    # replace them short of authoring an MSI transform. Confirmed via direct
    # inspection of the MSI (Property/CustomAction/InstallExecuteSequence tables,
    # and the embedded PostInstall.ps1 admin-extracted from the package):
    #
    # - ProductCode AND UpgradeCode both differ across chef-ice versions, so
    #   Windows Installer's own RemoveExistingProducts major-upgrade behavior
    #   never triggers between chef-ice releases — side-by-side installs of
    #   different versions are already safe natively, with no rpm/dnf-style
    #   "obsoletes" collision to work around.
    # - chef-ice releases built on/after ~2026-04-23 expose a `CHEF_PRESERVE_OMNIBUS`
    #   MSI property (settable via `options` on the msiexec command line) that the
    #   embedded PostInstall.ps1 forwards straight to `migrate-ice ... --preserve-omnibus`.
    #   Releases built before that (e.g. 19.2.12) have no such property at all — their
    #   PostInstall.ps1 always migrates destructively, and there is no known way to
    #   make those specific older MSI releases preserve the omnibus install.
    # - There is no MSI-property equivalent for the license key; PostInstall.ps1 reads
    #   CHEF_LICENSE_KEY only from the Machine-scoped environment (a live registry
    #   read, so setting it immediately before the package resource runs is reliable
    #   even though the Windows Installer service process itself may have started
    #   long before this converge).
    # `windows_package`'s own idempotency (a DisplayName/version registry lookup)
    # already makes the `package` resource below correctly report "up to date"
    # when this exact version is already installed. But the `windows_env`
    # create/delete pair that brackets it has NO idempotency check of its own —
    # `:create` unconditionally (re)writes the Machine env var and `:delete`
    # unconditionally removes it, so without a guard this pair reports 2
    # "updated" resources on every single converge forever, permanently
    # breaking idempotency even though the actual MSI install is correctly a
    # no-op. Skip the whole env-set/install/env-cleanup sequence once this
    # exact version is already installed.
    # Freshly-created Windows accounts (e.g. CI's `net user /add` local test
    # user, or any account that has never interactively logged on) can
    # inherit a PATH containing literal, unexpanded `%SystemRoot%`-style
    # tokens from the default user profile template instead of resolved
    # paths — or, over WinRM, a PATH that omits the Windows system
    # directories entirely. Mixlib::ShellOut on Windows does a literal
    # PATH-directory search with no shell-style `%` expansion, so an entry
    # like `%SystemRoot%\system32` never resolves to `C:\Windows\system32`,
    # and a PATH missing that directory outright fails the same way: the
    # `package` resource's `msiexec` invocation below dies with `'msiexec'
    # is not recognized as an internal or external command` even though
    # msiexec.exe is right there on disk. Expand any `%VAR%` tokens AND
    # guarantee the core system directories are present before that resource
    # runs. Expansion alone is not sufficient — it can only fix entries that
    # are actually there.
    repair_windows_path!

    msi_already_current = pkg_version && installed_version == pkg_version

    windows_env 'CHEF_LICENSE_KEY for chef-ice MSI install' do
      key_name 'CHEF_LICENSE_KEY'
      value new_resource.license_key
      sensitive true
      action :create
      not_if { msi_already_current }
    end

    package new_resource.product_name do
      source pkg_path
      version pkg_version if pkg_version
      installer_type :msi
      options 'CHEF_PRESERVE_OMNIBUS=1' if new_resource.preserve_omnibus
      action :install
      # The embedded PostInstall.ps1 custom action runs migrate-ice
      # synchronously as part of the msiexec transaction, which can easily
      # exceed windows_package's 600s (10 min) default timeout — observed
      # taking ~7-13 minutes live. msiexec itself keeps running to
      # completion regardless (Chef's shell_out just stops waiting and
      # raises), so a short timeout here only produces a false failure.
      timeout 1800
      notifies :run, 'ruby_block[reconverge installed scheduler resources]', :delayed
    end

    windows_env 'CHEF_LICENSE_KEY for chef-ice MSI install (cleanup)' do
      key_name 'CHEF_LICENSE_KEY'
      action :delete
      not_if { msi_already_current }
    end
  else
    package new_resource.product_name do
      source pkg_path
      version pkg_version if pkg_version
      action pkg_action
      notifies :run, 'ruby_block[reconverge installed scheduler resources]', :delayed
    end
  end

  # Run migrate-ice ourselves after package install to populate the /hab/pkgs
  # tree, now that the RPM's own %post scriptlet is suppressed (--noscripts
  # above). We pick the most-recently-extracted tarball by mtime rather than
  # just globbing "the first match" — with scriptlets suppressed, nothing
  # ever cleans up older versions' tarballs out of /hab/migration/bundle, so
  # multiple can accumulate there once several chef-ice versions have been
  # installed side by side. The one from *this* rpm transaction is always
  # the newest on disk.
  #
  # `--fresh-install` is passed CONDITIONALLY, based on whether `chef-client` currently
  # resolves via $PATH (see `chef_client_on_path?` in libraries/helpers.rb). This mirrors
  # migrate-ice's OWN internal detection exactly:
  #
  # - When chef-client IS on $PATH (true for every native OS package install of omnibus
  #   Chef — /usr/bin, /opt/chef/bin symlinked in, etc. — so this is the common case on
  #   real VMs/EC2), migrate-ice's non-fresh-install path runs a normal, correctly-behaved
  #   migration: it detects the existing version, extracts the bundle, populates
  #   /hab/pkgs, and fully respects --preserve-omnibus (confirmed live: with
  #   --preserve-omnibus true and /opt/chef NOT a mount point it logs "/opt/chef is not
  #   mounted. Skipping --fstab flag handling." and leaves /opt/chef untouched). When
  #   /opt/chef IS its own mount point, this path additionally performs --fstab handling,
  #   which must be suppressed — see the --fstab paragraph below.
  # - When chef-client is NOT on $PATH (normal for minimal Dokken/CI container images that
  #   invoke the bootstrap chef-client by full path rather than via $PATH), the
  #   non-fresh-install path's own "is chef-client installed?" check fails and it silently
  #   no-ops (exit 0, nothing extracted, /hab/pkgs never populated) — so `--fresh-install`
  #   is required there instead, to skip that check entirely and just extract the bundle
  #   unconditionally.
  #
  # `--fstab <apply|fail|ignore>` (migrate-ice's own default: `apply`) is passed explicitly on
  # the migration path from the `fstab_handling` property, which itself defaults to `ignore`
  # whenever `preserve_omnibus` is true. `apply` means "take the block device currently mounted
  # at /opt/chef and remount it at /hab", which is actively wrong when we are preserving the
  # omnibus install — and it doesn't degrade gracefully, it hard-fails the whole migration
  # (confirmed live):
  #
  #     [INFO] /opt/chef is mounted on device <dev>. Proceeding with migration.
  #     Failure while processing flag `fstab`, Error: error during mount migration:
  #       failed to mount <dev> to /hab: exit status 32.
  #     chef-client migration failed. ... Initiating rollback...
  #
  # migrate-ice then rolls back, so nothing is installed and the `execute` exits non-zero.
  # This is NOT a rare edge case: every kitchen-dokken container has /opt/chef bind-mounted
  # in from the `chef/chef` data container, so ANY converge that reaches the migration path
  # there fails 100% of the time (this is what broke the multi-version suite on every Linux
  # platform — the FIRST install takes the --fresh-install path, which never touches fstab,
  # but it binlinks chef-client onto $PATH, so the SECOND install in the same converge takes
  # the migration path and dies). It is equally reachable on real customer systems that keep
  # /opt/chef on a dedicated filesystem.
  #
  # The flag is only appended on the migration path: the --fresh-install path does not process
  # fstab at all (it isn't in that path's validated-flag set), so passing it there would be
  # dead weight.
  #
  # --process-config ignore skips the running-process check so kitchen converge
  # does not get blocked by the in-flight chef-client process.
  license = new_resource.license_key
  execute 'migrate-ice apply airgap' do
    command lazy {
      bundle = ::Dir.glob('/hab/migration/bundle/chef-ice-*.tar.gz').max_by { |f| ::File.mtime(f) }
      preserve_flag = new_resource.preserve_omnibus ? ' --preserve-omnibus true' : ''
      fresh_install = !chef_client_on_path?
      fresh_flag = fresh_install ? ' --fresh-install' : ''
      fstab_flag = fresh_install ? '' : " --fstab #{new_resource.fstab_handling}"
      "/hab/migration/bin/migrate-ice apply airgap #{bundle} --process-config ignore " \
        "--license-key #{license}#{preserve_flag}#{fresh_flag}#{fstab_flag}"
    }
    environment lazy { { 'CHEF_LICENSE_KEY' => license.to_s } }
    sensitive true
    only_if { ::File.exist?('/hab/migration/bin/migrate-ice') }
    only_if { ::Dir.glob('/hab/migration/bundle/chef-ice-*.tar.gz').any? }
    retries 5
    retry_delay 10
    not_if { pkg_version && hab_pkg_dirs(new_resource.habitat_package).any? { |d| d.split('/')[-2] == pkg_version } }
    notifies :run, 'ruby_block[reconverge installed scheduler resources]', :delayed
  end

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

  # Repoint any chef_client_scheduled_task/chef_client_cron/chef_client_launchd/
  # chef_client_systemd_timer resource in the run's resource collection at the
  # chef-ice version this converge just installed, so the next SCHEDULED run uses
  # the new client instead of whatever binary the schedule was originally written
  # against.
  ruby_block 'reconverge installed scheduler resources' do
    block { reconverge_installed_scheduler_resources(new_resource) }
    action :nothing
  end

  if new_resource.manage_binlinks
    chef_client_updater_enterprise_binlinks 'default' do
      habitat_package new_resource.habitat_package
      action :create
    end
  end
end
