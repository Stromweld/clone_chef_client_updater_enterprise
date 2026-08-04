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

property :license_key, String,
         sensitive: true,
         description: 'Chef license key (CHEF_LICENSE_KEY). Required for chef-ice downloads.',
         default: lazy { ENV.fetch('CHEF_LICENSE_KEY', nil) }

property :product_name, String,
         description: 'Mixlib-install product name and native OS package name.',
         default: 'chef-ice'

property :channel, Symbol,
         equal_to: %i(stable current),
         description: 'Download channel.',
         default: :stable

property :download_dir, String,
         default: lazy { Chef::Config[:file_cache_path] },
         description: 'Directory to stage downloaded packages before install.'

property :download_url, String,
         description: 'Direct package URL bypassing mixlib-install. Use for airgapped environments or local file servers.'

property :checksum, String,
         description: 'SHA256 checksum for the direct download_url package.'

property :manage_binlinks, [true, false],
         default: true,
         description: 'Automatically run the binlinks resource after a successful install.'

property :update_scheduler_resources, [true, false],
         default: true,
         description: 'Reconverges any chef_client_cron/chef_client_launchd/chef_client_systemd_timer/' \
                      'chef_client_scheduled_task resources found in the resource collection whenever the ' \
                      'binlinked package version changes — the initial omnibus-to-chef-ice migration AND ' \
                      'every later chef-ice version upgrade. Re-running each resource\'s own previously ' \
                      'declared action(s) causes its chef_binary_path property (a Chef lazy default) to ' \
                      're-evaluate against the now-current binlink, so the next scheduled run picks up the ' \
                      'newly installed chef-client. This works regardless of whether those resources are ' \
                      'declared before or after this one, since Chef fully compiles the resource collection ' \
                      'before convergence begins. Requires manage_binlinks true (or an externally managed, ' \
                      'current binlink). Set false only if an external mechanism already keeps those ' \
                      'resources\' chef_binary_path current.'

property :preserve_omnibus, [true, false],
         default: true,
         description: 'Pass --preserve-omnibus true to migrate-ice to keep the existing omnibus Chef installation.'

default_action :install

action_class do
  include ChefClientUpdaterEnterprise::Helpers

  # Ensure mixlib-install gem is loaded at compile time.
  def install_mixlib_install_gem
    gem_cache_path = ::File.join(Chef::Config[:file_cache_path], 'mixlib-install.gem')

    cookbook_file gem_cache_path do
      source 'mixlib-install.gem'
      cookbook 'chef_client_updater_enterprise'
      action :nothing
    end.run_action(:create)

    chef_gem 'mixlib-install' do
      source gem_cache_path
      clear_sources true
      compile_time true
      action :install
    end
  end

  def validate_license!
    if new_resource.license_key.nil? || new_resource.license_key.to_s.strip.empty?
      raise Chef::Exceptions::ConfigurationError,
            'chef_client_updater_enterprise_install: license_key is required. ' \
            "Set the CHEF_LICENSE_KEY environment variable or pass `license_key 'YOUR_KEY'` " \
            'to the resource. A valid license key is required to download chef-ice packages.'
    end
  end

  def artifact_info
    require 'mixlib/install'

    product_version = new_resource.version == 'latest' ? :latest : new_resource.version
    mixlib_platform, mixlib_platform_version = mixlib_install_platform_info
    options = {
      product_name: new_resource.product_name,
      product_version: product_version,
      channel: new_resource.channel,
      license_id: new_resource.license_key,
      platform: mixlib_platform,
      platform_version: mixlib_platform_version,
      architecture: node['kernel']['machine'] == 'arm64' ? 'aarch64' : node['kernel']['machine'],
      # Published artifacts are not built for every exact platform_version (e.g.
      # a new Ubuntu/RHEL point release); fall back to the closest older
      # compatible artifact rather than raising ArtifactsNotFound.
      platform_version_compatibility_mode: true,
    }

    result = Mixlib::Install.new(options).artifact_info

    return result unless result.is_a?(Array)
    raise "No matching artifact for #{mixlib_platform}/#{mixlib_platform_version}" if result.empty?

    result.first
  end

  def package_extension(_url)
    if windows?
      'msi'
    elsif platform_family?('rhel', 'amazon', 'suse', 'fedora')
      'rpm'
    elsif platform_family?('debian')
      'deb'
    elsif platform_family?('mac_os_x')
      'dmg'
    else
      raise "Unsupported platform family '#{node['platform_family']}' for chef-ice package install"
    end
  end

  def direct_artifact_url?(url)
    path = URI.parse(url).path
    %w(.rpm .deb .msi .dmg .pkg).any? { |ext| path.end_with?(ext) }
  rescue URI::InvalidURIError
    false
  end

  # chef_client_cron/launchd/systemd_timer/scheduled_task's chef_binary_path default varies by
  # Chef Infra Client version: newer releases (e.g. what chef-ice itself ships) default it to a
  # lazy, hab-aware `chef_client_hab_binary_path` block; the chef-client actually bootstrapping
  # this converge (whatever Test Kitchen/production installs as a starting point, e.g. the stable
  # channel's 18.11.11) instead defaults it to a plain, non-lazy, hardcoded legacy path (confirmed
  # via direct inspection of that gem's chef_client_scheduled_task.rb — no `lazy {}` at all).
  # Resetting or re-reading either kind of default can never produce the right value here on an
  # older bootstrap chef-client, and there is no way to know in advance which kind is running. The
  # only version-independent fix is to explicitly set chef_binary_path to the resolved, immutable,
  # fully-versioned Habitat path (ChefClientUpdaterEnterprise::Helpers#chef_client_hab_binary_path
  # — deliberately NOT the mutable /usr/bin/chef-client binlink symlink; see that helper's comment
  # for the root-privilege-escalation risk of pointing a root-run scheduled job at a
  # symlink writable between runs) ourselves before re-running the resource's action, bypassing
  # whatever default it would otherwise compute entirely. Chef fully compiles the resource
  # collection before convergence begins (lib/chef/client.rb), so this works regardless of whether
  # these resources are declared before or after this one in the run_list — but note that
  # run_context inside an action_class is a CHILD RunContext scoped to this action's own
  # declarations; root_run_context.resource_collection is required to reach the full, shared,
  # recipe-level collection.
  # Returns true if reconverging any scheduler resource actually changed something (so the
  # calling ruby_block can correctly report its own updated-or-not status instead of always
  # reporting "updated" just because the block ran) — required for idempotency: this block
  # runs unconditionally on every converge (see "Scheduler Resource Reconvergence" in
  # AGENTS.md), so if it always reported itself as updated, no converge running this
  # cookbook could ever be idempotent, even when nothing on disk actually changed.
  def reconverge_scheduler_resources(resource_collection, resolved_binary_path)
    scheduler_types = %i(chef_client_scheduled_task chef_client_cron chef_client_launchd chef_client_systemd_timer)
    found = resource_collection.all_resources.select { |r| scheduler_types.include?(r.resource_name) }

    if found.empty?
      Chef::Log.debug('chef_client_updater_enterprise: no chef-client scheduler resources found to reconverge.')
      return false
    end

    any_updated = false
    found.each do |resource|
      Chef::Log.info("chef_client_updater_enterprise: reconverging #{resource} for the newly installed binary.")
      resource.chef_binary_path(resolved_binary_path) if resource.respond_to?(:chef_binary_path)
      resource.action.each { |a| resource.run_action(a) }
      any_updated ||= resource.updated_by_last_action?
    end
    any_updated
  end

  # Shared entry point called from BOTH the "already installed, nothing to do"
  # early-out and the tail of a genuine install/upgrade, so reconvergence runs
  # on every single converge — not only the converge that happens to perform
  # an install/upgrade. This is the actual fix for the chef_binary_path
  # flip-flop bug: an earlier version of this action only reached the
  # reconvergence logic below when the package-install branch executed,
  # returning early (skipping reconvergence entirely) on every converge where
  # chef-ice was already at the pinned/current version. Since resolving a
  # stable path here is what overrides the scheduler resource's own built-in
  # default, skipping it left that default's evaluation up to whichever Chef
  # Infra Client gem happened to be bootstrapping THAT specific converge —
  # different platforms/CI runs bootstrap from different gem vintages (some
  # pre-19.x with a hardcoded legacy default, others already chef-ice with a
  # lazy hab-aware default), so which stale/inconsistent value got left in
  # place varied by platform. That is why the flip-flop direction was
  # inconsistent between platforms rather than a simple, single-direction
  # regression.
  #
  # Deliberately called only after the package install/upgrade branch (or the
  # already-installed short-circuit) has already run in the SAME converge:
  # chef_client_hab_binary_path must resolve `hab_pkg_dirs`/binlink state as it
  # exists after this converge's own install+binlink work is finalized, not
  # whatever was on disk before this action started. Resolving it any earlier
  # (e.g. once at the top of the action, before the package/migrate-ice/binlink
  # resources below have actually run) risks resolving a stale, pre-binlink
  # value on the very converge that installs/upgrades chef-ice for the first
  # time. Calling this once, here, after all of that has completed for both
  # code paths is what guarantees a single, canonical, stable resolution per
  # converge.
  def reconverge_installed_scheduler_resources(new_resource)
    # Deliberately NOT chef_client_binlink_path (the mutable /usr/bin/chef-client symlink) — see
    # ChefClientUpdaterEnterprise::Helpers#chef_client_hab_binary_path for why scheduler resources
    # must be pointed at the resolved, immutable, fully-versioned Habitat path instead.
    # Pass new_resource.version so a user pinning to an older, specific version (e.g. to
    # work around a bug in the latest release) doesn't get silently overridden by a newer
    # version that may already be present on disk from an earlier install/run.
    resolved_binary_path = chef_client_hab_binary_path(new_resource.habitat_package, new_resource.version)
    update_scheduler_enabled = new_resource.update_scheduler_resources
    # run_context here is a CHILD RunContext scoped to this action's own nested resource
    # declarations (empty of sibling recipe-level resources even in unified_mode) — only
    # root_run_context.resource_collection reaches the full, shared, recipe-level collection.
    resource_collection = run_context.root_run_context.resource_collection

    if update_scheduler_enabled && resolved_binary_path.nil?
      Chef::Log.warn(
        'chef_client_updater_enterprise: update_scheduler_resources is true but no installed ' \
        "#{new_resource.habitat_package} Habitat package was found to resolve a chef_binary_path from."
      )
    end

    # Runs unconditionally on every converge (not gated behind a notification) specifically so it
    # self-heals on a later no-op converge too, not just the converge that actually
    # installs/upgrades chef-ice. The individual chef_client_cron/systemd_timer/launchd/
    # scheduled_task resources are declared with no explicit chef_binary_path in user recipes, so
    # their own built-in lazy default re-evaluates every single time their action is re-run — on an
    # older bootstrap chef-client (pre-19.x) that default is a hardcoded legacy omnibus path (see
    # comment on reconverge_scheduler_resources above), so if this only ran when notified by an
    # actual chef-ice change, any later unrelated converge would silently flip the scheduler's
    # binary path back to that stale default with nothing left to correct it. Running every converge
    # instead means reconverge_scheduler_resources always re-asserts resolved_binary_path, so the
    # scheduler resource's own idempotency (each resource's underlying template/cron_d/systemd_unit
    # compares rendered content, not "did chef-ice change this run") is what actually determines
    # whether anything reports a diff. resolved_binary_path only changes when a NEW chef-ice version
    # is actually installed (chef_client_hab_binary_path always resolves the latest installed
    # version's directory), so this can never itself cause a false "not idempotent" result on an
    # unrelated converge.
    #
    # Deliberately a plain Ruby call, NOT a `ruby_block` resource: `Chef::Provider::RubyBlock#
    # action_run` unconditionally wraps `new_resource.block.call` in `converge_by`, which marks
    # the ruby_block resource itself "updated" on every single converge regardless of what the
    # block's own return value or internal `updated_by_last_action` calls indicate — confirmed by
    # reading chef-ice's own bundled chef gem's `lib/chef/provider/ruby_block.rb`. That made this
    # step permanently report itself as a change every converge, which broke the CI idempotency
    # check (`2/17 resources updated` on every second converge, forever) even when
    # reconverge_scheduler_resources itself found nothing to change. Since the whole resource is
    # `unified_mode true`, calling this directly as plain Ruby inside the action body runs at
    # exactly the same point in convergence a `ruby_block` would have, without a wrapper resource
    # that can misreport its own idempotency.
    return unless update_scheduler_enabled && resolved_binary_path && ::File.exist?(resolved_binary_path)

    reconverge_scheduler_resources(resource_collection, resolved_binary_path)
  end
end

action :install do
  unless new_resource.version == 'latest'
    installed = current_installed_version(new_resource.product_name, new_resource.habitat_package)
    if installed == new_resource.version
      Chef::Log.debug("chef_client_updater_enterprise_install: #{new_resource.product_name} #{new_resource.version} already installed, skipping.")
      return
    end
  end

  if new_resource.download_url
    # Direct download path — skip mixlib-install entirely
    pkg_url = new_resource.download_url
    pkg_ext = package_extension(pkg_url)
    safe_ver = new_resource.version == 'latest' ? 'custom' : new_resource.version
    pkg_path = ::File.join(new_resource.download_dir, "#{new_resource.product_name}-#{safe_ver}.#{pkg_ext}")
    file_checksum = new_resource.checksum
    # 'latest' has no known version when bypassing mixlib-install; the package
    # resource's own source-file inspection is the only idempotency signal available.
    pkg_version = new_resource.version == 'latest' ? nil : new_resource.version
  else
    # mixlib-install path
    validate_license!
    install_mixlib_install_gem

    artifact = artifact_info
    raise "No artifact found for #{new_resource.product_name} #{new_resource.version}" if artifact.nil?

    pkg_url = artifact.url
    pkg_ext = package_extension(pkg_url)
    pkg_path = ::File.join(new_resource.download_dir, "#{new_resource.product_name}-#{artifact.version}.#{pkg_ext}")
    # Handler/redirect URLs (no file extension in path) return checksums that don't match the response body
    file_checksum = direct_artifact_url?(pkg_url) ? artifact.sha256 : nil
    pkg_version = artifact.version
  end

  remote_file pkg_path do
    source pkg_url
    checksum file_checksum if file_checksum
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
      # `--nodigest` is required on top of `--replacefiles --noscripts`: chef-ice's
      # published RPMs (built once per release, apparently always on an Amazon
      # Linux 2 builder regardless of the target `p=<platform>` query param used to
      # fetch them -- confirmed live: chef-ice-19.3.15's RPM header reports
      # `Release: 1.amzn2` even when downloaded via `p=fedora`/`p=el` mixlib-install
      # requests) are missing a modern per-file payload digest. RPM's own payload
      # verification is a SEPARATE check from the package's GPG signature (which we
      # already deliberately skip via `--noscripts`'s sibling concerns and the
      # `remote_file` resource's own `checksum` property, confirmed matching
      # upstream's sha256 before rpm ever runs). Whether missing-digest packages are
      # rejected depends entirely on the installed rpm binary's own default
      # `_pkgverify_level` macro -- confirmed live: rpm 4.x (AlmaLinux/Rocky/RHEL 8/9,
      # Amazon Linux) silently tolerates it, but Fedora 44's bundled rpm 6.0.2
      # defaults `_pkgverify_level` to `digest` and hard-fails with `package ...
      # does not verify: no digest` otherwise. `--nodigest` disables only this
      # specific payload-digest check (not the SHA256 checksum already verified
      # above, and not signature verification, already skipped via --noscripts)
      # and is a no-op/harmless on rpm versions that don't enforce it.
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

    ruby_block "stub migrate-ice before dpkg configure (#{pkg_path})" do
      block do
        ::FileUtils.mv(migrate_ice_bin, migrate_ice_backup, force: true) if ::File.exist?(migrate_ice_bin)
        ::File.write(migrate_ice_bin, "#!/bin/sh\nexit 0\n")
        ::FileUtils.chmod(0o755, migrate_ice_bin)
      end
      not_if { dpkg_already_current }
    end

    execute "dpkg --configure #{new_resource.product_name} (#{pkg_path})" do
      command "dpkg --configure #{new_resource.product_name}"
      not_if { dpkg_already_current }
    end

    ruby_block "restore real migrate-ice after dpkg configure (#{pkg_path})" do
      block do
        ::FileUtils.mv(migrate_ice_backup, migrate_ice_bin, force: true) if ::File.exist?(migrate_ice_backup)
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
      # Chef's windows_package provider only implements :install (no :upgrade
      # action exists at all — Chef::Exceptions::UnsupportedAction otherwise).
      # This is harmless here: each chef-ice version is a distinct MSI
      # ProductCode/UpgradeCode, so :install always does the right thing
      # whether or not another version is already present (side-by-side,
      # not a true Windows-Installer major-upgrade).
      action :install
      # The embedded PostInstall.ps1 custom action runs migrate-ice
      # synchronously as part of the msiexec transaction, which can easily
      # exceed windows_package's 600s (10 min) default timeout — observed
      # taking ~7-13 minutes live. msiexec itself keeps running to
      # completion regardless (Chef's shell_out just stops waiting and
      # raises), so a short timeout here only produces a false failure.
      timeout 1800
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
  # migrate-ice's OWN internal detection exactly (confirmed via /var/log/chef19migrate.log
  # and direct binary testing on a live EC2 instance):
  #
  # - When chef-client IS on $PATH (true for every native OS package install of omnibus
  #   Chef — /usr/bin, /opt/chef/bin symlinked in, etc. — so this is the common case on
  #   real VMs/EC2), migrate-ice's non-fresh-install path runs a normal, correctly-behaved
  #   migration: it detects the existing version, extracts the bundle, populates
  #   /hab/pkgs, and fully respects --preserve-omnibus (confirmed live: with
  #   --preserve-omnibus true it logs "/opt/chef is not mounted. Skipping --fstab flag
  #   handling." and leaves /opt/chef untouched, rather than the mount-remount failure
  #   this comment previously warned about — that failure mode is real but only triggers
  #   when /opt/chef genuinely IS mounted as its own dedicated block device, a supported
  #   customer configuration; when it isn't, migrate-ice degrades gracefully instead of
  #   erroring).
  # - When chef-client is NOT on $PATH (normal for minimal Dokken/CI container images that
  #   invoke the bootstrap chef-client by full path rather than via $PATH), the
  #   non-fresh-install path's own "is chef-client installed?" check fails and it silently
  #   no-ops (exit 0, nothing extracted, /hab/pkgs never populated) — so `--fresh-install`
  #   is required there instead, to skip that check entirely and just extract the bundle
  #   unconditionally.
  #
  # Getting this wrong is NOT a hard failure either way — both branches exit 0 — which is
  # exactly why this previously went undetected: unconditionally passing `--fresh-install`
  # (the previous behavior) silently no-ops on every EC2/native-VM converge where
  # chef-client is resolvable via $PATH, leaving /hab/pkgs permanently empty and causing
  # `execute[migrate-ice apply airgap]` to (harmlessly but pointlessly) re-run on every
  # single subsequent converge forever, since its own `not_if` guard (checking
  # `hab_pkg_dirs`) can never be satisfied. Confirmed root-caused via SSH onto a live EC2
  # `preserve-omnibus` instance: `/hab/pkgs/chef/chef-infra-client/` did not exist despite
  # rpm/dpkg correctly reporting the chef-ice package installed, and this was NOT
  # reproducible on Dokken (whose minimal images never have chef-client on $PATH).
  #
  # --process-config ignore skips the running-process check so kitchen converge
  # does not get blocked by the in-flight chef-client process.
  license = new_resource.license_key
  execute 'migrate-ice apply airgap' do
    command lazy {
      bundle = ::Dir.glob('/hab/migration/bundle/chef-ice-*.tar.gz').max_by { |f| ::File.mtime(f) }
      preserve_flag = new_resource.preserve_omnibus ? ' --preserve-omnibus true' : ''
      fresh_flag = chef_client_on_path? ? '' : ' --fresh-install'
      "/hab/migration/bin/migrate-ice apply airgap #{bundle} --process-config ignore --license-key #{license}#{preserve_flag}#{fresh_flag}"
    }
    environment lazy { { 'CHEF_LICENSE_KEY' => license.to_s } }
    sensitive true
    only_if { ::File.exist?('/hab/migration/bin/migrate-ice') }
    only_if { ::Dir.glob('/hab/migration/bundle/chef-ice-*.tar.gz').any? }
    retries 5
    retry_delay 10
    # `execute` has no built-in idempotency of its own — without this guard it
    # unconditionally re-runs migrate-ice on every single converge, even when
    # rpm_package/dpkg already correctly reported "up to date" for the same
    # pkg_version. `hab_pkg_dirs` is a plain filesystem glob under /hab/pkgs
    # (not a `hab` binary shell-out) deliberately: at this point in a fresh
    # migration, `/bin/hab` hasn't been linked yet (that happens further below,
    # itself dependent on migrate-ice having already run), so checking via the
    # `hab` binary here would create a chicken-and-egg dependency.
    not_if { pkg_version && hab_pkg_dirs(new_resource.habitat_package).any? { |d| d.split('/')[-2] == pkg_version } }
    notifies :run, 'ruby_block[reconverge installed scheduler resources]', :delayed
  end

  # migrate-ice unpacks a Habitat `hab` package (chef/hab if bundled, else
  # core/hab) under /hab/pkgs, but does not itself place a `hab` binary on any
  # of the fixed paths Chef's built-in habitat_package/habitat_install
  # resources (and this cookbook's own hab_binary helper) look for on
  # Linux/macOS. Without this, downstream resources like
  # chef_client_updater_enterprise_cleanup fail with "'hab' binary not
  # found". Link it in from the Habitat-managed binary migrate-ice already
  # installed rather than triggering habitat_install's fresh internet
  # download, which would be redundant and unwanted in airgapped
  # environments. Windows needs no equivalent bootstrap: hab_binary's
  # Windows branch (libraries/helpers.rb) resolves hab.exe directly from its
  # real, fully-nested package path — a flat symlink/copy under
  # C:\hab\bin\hab.exe breaks hab's own prefix self-detection (confirmed
  # live via a "XXX prefix not found XXX" error on `pkg binlink`).
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

  # Update any chef_client_scheduled_task/chef_client_cron/chef_client_launchd/chef_client_systemd_timer resources
  # declared in the resources collection to point at the newly-installed Habitat binary path to run the new client on it's next run.
  # This will reconverge the scheduler resource that was found with the new binary path.
  ruby_block 'reconverge installed scheduler resources' do
    block { reconverge_installed_scheduler_resources(new_resource) }
    action :nothing
  end

  binlinks_resource = nil
  if new_resource.manage_binlinks
    binlinks_resource = chef_client_updater_enterprise_binlinks 'default' do
      habitat_package new_resource.habitat_package
      action :create
    end
  end
end
