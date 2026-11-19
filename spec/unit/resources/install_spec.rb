# frozen_string_literal: true

require 'spec_helper'

# Regression coverage for the previously-fixed chef_binary_path flip-flop bug (see AGENTS.md
# "Scheduler Reconvergence"). That fix was later intentionally REVERTED for a stricter gating
# requirement: reconvergence must fire ONLY when a new install/upgrade actually happened THIS
# converge AND update_scheduler_resources is true — not merely "update_scheduler_resources is
# true", which is what the old already-installed early-return branch did by calling the
# reconverge logic directly and unconditionally on every no-op converge. The wiring is now
# entirely notification-driven (every install/upgrade resource `notifies :reconverge, ...,
# :delayed`), so the early-return path declares nothing and notifies nothing — see
# resources/install.rb's `action :install`. This DOES reopen the narrow scenario the old fix
# addressed: if a scheduler resource (chef_client_cron/systemd_timer/etc.) is declared with a
# non-lazy, hardcoded chef_binary_path default by an old bootstrap Chef gem, and chef-ice is
# ALREADY installed at the pinned version on the very first converge that resource is compiled
# in, nothing will ever correct that stale default, because no install happens on any subsequent
# converge either (the version stays pinned). That tradeoff was accepted explicitly in favor of
# precise gating; see AGENTS.md for the full writeup.
#
# Stubbing follows the same low-level pattern as spec/unit/resources/cleanup_spec.rb
# (fake the filesystem primitives current_installed_version/chef_client_hab_binary_path
# themselves read, not those helper methods) — the helper methods are mixed
# directly into the resource's generated provider subclass via
# `include ChefClientUpdaterEnterprise::Helpers`, which sits ABOVE Chef::Provider
# in the ancestry chain, so `allow_any_instance_of(Chef::Provider)` on the helper
# methods themselves is silently never invoked; only stubbing the primitives
# they call actually takes effect.
describe 'chef_client_updater_enterprise_install' do
  let(:hab_pkg) { 'chef/chef-infra-client' }
  let(:pinned_version) { '19.4.61' }
  let(:root) { "/hab/pkgs/#{hab_pkg}" }
  let(:release_dir) { "#{root}/#{pinned_version}/20260601120000" }
  let(:resolved_binary_path) { "#{release_dir}/bin/chef-client" }

  # Simulates chef-ice already installed at exactly `pinned_version`:
  #   - hab_binary => nil (no `hab` on $PATH), so current_hab_ident/current_hab_version
  #     both short-circuit to nil, forcing current_installed_version to fall back to
  #     its filesystem-glob path.
  #   - hab_pkg_dirs(hab_pkg) resolves to a single release dir at pinned_version, which
  #     both current_installed_version's fallback and chef_client_hab_binary_path read.
  def stub_installed_pinned_version
    allow(::File).to receive(:executable?).and_return(false)
    allow(::File).to receive(:directory?).and_call_original
    allow(::File).to receive(:directory?).with(root).and_return(true)
    allow(::File).to receive(:directory?).with(release_dir).and_return(true)
    allow(::Dir).to receive(:glob).with("#{root}/*/*").and_return([release_dir])
    allow(::File).to receive(:file?).and_call_original
    allow(::File).to receive(:file?).with("#{release_dir}/IDENT").and_return(true)
    allow(::File).to receive(:exist?).and_call_original
    allow(::File).to receive(:exist?).with(resolved_binary_path).and_return(true)
  end

  # Inverse of stub_installed_pinned_version: simulates chef-ice NOT installed, so
  # action :install never takes its "already at the pinned version" early return.
  # Without this, current_installed_version reads the REAL host: `hab pkg list
  # chef/chef-infra-client` on a machine that happens to have pinned_version
  # installed (the CI runner does) short-circuits the action before any resource is
  # declared, and every expectation about the download resource fails on nil.
  def stub_not_installed
    allow(::File).to receive(:executable?).and_return(false)
    allow(::File).to receive(:directory?).and_call_original
    allow(::File).to receive(:directory?).with(root).and_return(false)
    allow(::Dir).to receive(:glob).and_call_original
    allow(::Dir).to receive(:glob).with("#{root}/*/*").and_return([])
  end

  def scheduler_resource(chef_run, type, name)
    chef_run.resource_collection.all_resources.find { |r| r.resource_name == type && r.name == name }
  end

  context 'chef-ice is already installed at the pinned version (no-op converge)' do
    let(:chef_run) do
      stub_installed_pinned_version
      pinned = pinned_version

      converge_resource do
        chef_client_cron 'chef-client'
        chef_client_systemd_timer 'chef-client'

        chef_client_updater_enterprise_install 'chef-ice' do
          version pinned
        end
      end
    end

    it 'does NOT reconverge chef_binary_path on chef_client_cron since nothing was (re)installed' do
      resource = scheduler_resource(chef_run, :chef_client_cron, 'chef-client')
      expect(resource.chef_binary_path).to_not eq(resolved_binary_path)
    end

    it 'does NOT reconverge chef_binary_path on chef_client_systemd_timer since nothing was (re)installed' do
      resource = scheduler_resource(chef_run, :chef_client_systemd_timer, 'chef-client')
      expect(resource.chef_binary_path).to_not eq(resolved_binary_path)
    end

    it 'deletes a /tmp/chef_env left by an earlier failed run' do
      env = chef_run.find_resource(:file, 'remove stale /tmp/chef_env')
      expect([env.path, env.action, env.sensitive]).to eq(['/tmp/chef_env', [:delete], true])
    end

    it 'does not attempt to (re)install the package' do
      expect(chef_run).to_not install_rpm_package('chef-ice')
      expect(chef_run).to_not install_package('chef-ice')
    end

    it 'never declares the scheduler_reconvergence resource on the early-return path' do
      resource = chef_run.find_resource(:chef_client_updater_enterprise_scheduler_reconvergence, 'default')
      expect(resource).to be_nil
    end
  end

  # The version lookup (native package database or `hab pkg path`) can report
  # the pinned version while its release directory has no IDENT, e.g. after a
  # failed migration. That must not take the early return: the install path and
  # its IDENT verification have to run.
  context 'the pinned version is reported installed but its release has no IDENT' do
    let(:chef_run) do
      allow(::File).to receive(:executable?).and_return(false)
      allow(::File).to receive(:directory?).and_call_original
      allow(::File).to receive(:directory?).with(root).and_return(true)
      allow(::File).to receive(:directory?).with(release_dir).and_return(true)
      allow(::Dir).to receive(:glob).and_call_original
      allow(::Dir).to receive(:glob).with("#{root}/*/*").and_return([release_dir])
      allow(::File).to receive(:file?).and_call_original
      allow(::File).to receive(:file?).with("#{release_dir}/IDENT").and_return(false)
      native = instance_double(Mixlib::ShellOut, run_command: nil, exitstatus: 0, stdout: pinned_version)
      allow(Mixlib::ShellOut).to receive(:new).and_call_original
      allow(Mixlib::ShellOut).to receive(:new).with(/chef-ice/, anything).and_return(native)
      pinned = pinned_version

      converge_resource do
        chef_client_updater_enterprise_install 'chef-ice' do
          version pinned
          download_url "https://example.com/chef-ice-#{pinned}-1.x86_64.rpm"
        end
      end
    end

    it 'does not take the early return and declares the release verification' do
      expect(chef_run.find_resource(:ruby_block, "verify #{hab_pkg} #{pinned_version} release")).to_not be_nil
      expect(chef_run.find_resource(:chef_client_updater_enterprise_scheduler_reconvergence, 'default')).to_not be_nil
    end
  end

  # Regression coverage for CDN propagation delay: the Commercial Download API
  # advertises a release the moment it is published, but the artifact can take
  # minutes to reach the caller's nearest CDN edge (most visibly for the Windows
  # MSI). Until it does, that edge returns 403/404 or a short error body with a 200.
  #
  # remote_file's own `checksum` property does NOT verify a download — it only
  # compares an already-present local file to decide whether to skip fetching — so
  # without an explicit verify block a CDN error page would be handed straight to
  # rpm/dpkg/msiexec. The download_url branch is used here because it reaches the
  # same remote_file declaration without needing to stub the API.
  context 'downloading the package artifact' do
    let(:checksum) { 'fe004919ddbf171947c6a59d9bd5d516a61ff30e64cf6e4ddd95521b90cc80af' }
    let(:chef_run) do
      stub_not_installed
      expected = checksum

      converge_resource(platform: 'ubuntu', version: '24.04') do
        chef_client_updater_enterprise_install 'chef-ice' do
          version '19.4.61'
          download_url 'https://chefdownload-commercial.chef.io/files/stable/chef-ice/19.4.61/' \
                       'linux/x86_64/deb/chef-ice-19.4.61-1_amd64.deb'
          checksum expected
          manage_binlinks false
          update_scheduler_resources false
        end
      end
    end

    let(:download) do
      chef_run.resource_collection.all_resources.find { |r| r.resource_name == :remote_file }
    end

    # The package type is derived from the artifact URL, not guessed from the
    # node's platform, so the staged filename always matches the file fetched.
    # This converges on Ubuntu while downloading an .msi on purpose: a
    # platform-derived guess would stage it as .deb and hand dpkg a file it
    # cannot read.
    it 'derives the staged package extension from the download URL, not the platform' do
      stub_not_installed

      run = converge_resource(platform: 'ubuntu', version: '24.04') do
        chef_client_updater_enterprise_install 'chef-ice' do
          version '19.4.61'
          download_url 'https://example.invalid/files/chef-ice-19.4.61-1.x86_64.msi?license_id=free-abc'
          manage_binlinks false
          update_scheduler_resources false
        end
      end
      remote = run.resource_collection.all_resources.find { |r| r.resource_name == :remote_file }

      expect(remote.path).to end_with('.msi')
    end

    it 'raises an actionable error when the download URL has no package extension' do
      stub_not_installed

      expect do
        converge_resource(platform: 'ubuntu', version: '24.04') do
          chef_client_updater_enterprise_install 'chef-ice' do
            version '19.4.61'
            download_url 'https://example.invalid/stable/chef-ice/download?p=ubuntu'
            manage_binlinks false
            update_scheduler_resources false
          end
        end
      end.to raise_error(/could not determine a package type/)
    end

    # The failure message is built from the URL and would otherwise carry the
    # license_id query parameter into the Chef log.
    it 'does not leak the download URL query string in that error' do
      stub_not_installed

      expect do
        converge_resource(platform: 'ubuntu', version: '24.04') do
          chef_client_updater_enterprise_install 'chef-ice' do
            version '19.4.61'
            download_url 'https://example.invalid/download?license_id=free-deadbeef'
            manage_binlinks false
            update_scheduler_resources false
          end
        end
      end.to raise_error(/could not determine a package type/) { |e|
        expect(e.message).not_to include('free-deadbeef')
      }
    end

    it 'retries the download so a not-yet-propagated CDN edge is survivable' do
      expect(download.retries).to eq(5)
      expect(download.retry_delay).to eq(30)
    end

    it 'honors download_retries/download_retry_delay overrides' do
      stub_not_installed

      run = converge_resource(platform: 'ubuntu', version: '24.04') do
        chef_client_updater_enterprise_install 'chef-ice' do
          version '19.4.61'
          download_url 'https://example.invalid/chef-ice-19.4.61-1_amd64.deb'
          checksum 'fe004919ddbf171947c6a59d9bd5d516a61ff30e64cf6e4ddd95521b90cc80af'
          download_retries 10
          download_retry_delay 90
          manage_binlinks false
          update_scheduler_resources false
        end
      end
      remote = run.resource_collection.all_resources.find { |r| r.resource_name == :remote_file }

      expect(remote.retries).to eq(10)
      expect(remote.retry_delay).to eq(90)
    end

    it 'verifies the staged download against the expected sha256' do
      expect(download.verifications.length).to eq(1)

      verification = download.verifications.first
      Tempfile.create('chef-ice-artifact') do |f|
        f.write('a truncated CDN error page, not a package')
        f.flush
        expect(verification.verify(f.path)).to be(false)
      end
    end

    it 'passes verification when the staged download matches' do
      verification = download.verifications.first

      Tempfile.create('chef-ice-artifact') do |f|
        f.write('real package bytes')
        f.flush
        allow(Chef::Digester).to receive(:checksum_for_file).with(f.path).and_return(checksum)
        expect(verification.verify(f.path)).to be(true)
      end
    end
  end

  # The fixed installers run migrate-ice from their own post-install scripts and
  # read settings from /tmp/chef_env (rpm/deb/dmg) or MSI properties. Each platform
  # gets one plain package resource; the old stub/--noscripts workarounds are gone.
  context 'platform install resources and installer settings' do
    let(:reconverge) { 'chef_client_updater_enterprise_scheduler_reconvergence[default]' }
    let(:env_file) { '/tmp/chef_env' }

    before do
      allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
        .to receive(:current_native_version).and_return(nil)
      allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
        .to receive(:running_under_omnibus?).and_return(false)
      # macOS reads /opt/hab/pkgs, which may exist on the host running the specs.
      allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
        .to receive(:hab_pkg_dirs).and_return([])
      stub_not_installed
    end

    def linux_install(platform, version, url, **props)
      converge_resource(platform: platform, version: version) do
        chef_client_updater_enterprise_install 'chef-ice' do
          version '19.4.61'
          license_key 'abc123'
          download_url url
          checksum 'a' * 64
          props.each { |k, v| send(k, v) }
        end
      end
    end

    def deb_run(**props)
      linux_install('ubuntu', '24.04', 'https://example.invalid/chef-ice-19.4.61-1_amd64.deb', **props)
    end

    # find_resource also matches on path, which 'remove stale /tmp/chef_env' shares.
    def env_file_resource(run)
      run.resource_collection.all_resources.find { |r| r.to_s == "file[#{env_file}]" }
    end

    def notified?(res, target, action, timing)
      list = timing == :before ? res.before_notifications : res.delayed_notifications
      list.any? { |n| n.resource.to_s == target && n.action == action }
    end

    it 'installs the .deb with dpkg_package and no forced dpkg options' do
      pkg = deb_run.find_resource(:dpkg_package, 'chef-ice')
      expect(pkg.source).to end_with('chef-ice-19.4.61.deb')
      expect(pkg.options).to be_nil
    end

    it 'installs the .rpm with rpm_package and no --noscripts/--replacefiles/--nodigest' do
      run = linux_install('almalinux', '9', 'https://example.invalid/chef-ice-19.4.61-1.x86_64.rpm')
      expect(run.find_resource(:rpm_package, 'chef-ice').options).to be_nil
    end

    it 'installs the macOS .dmg with dmg_package as a pkg from the versioned volume' do
      run = converge_resource(platform: 'mac_os_x', version: '12') do
        chef_client_updater_enterprise_install 'chef-ice' do
          version '19.4.61'
          license_key 'abc123'
          download_url 'https://example.invalid/chef-ice-19.4.61-1_arm64.dmg'
          checksum 'a' * 64
        end
      end
      pkg = run.find_resource(:dmg_package, 'chef-ice-19.4.61')
      expect(pkg.type).to eq('pkg')
      expect(pkg.volumes_dir).to eq('Chef Infra Client 19.4.61')
      expect(notified?(pkg, "file[#{env_file}]", :create, :before)).to be true
      expect(env_file_resource(run).content).to_not include('CHEF_FSTAB')
    end

    it 'requires an explicit version for download_url on macOS' do
      expect do
        converge_resource(platform: 'mac_os_x', version: '12') do
          chef_client_updater_enterprise_install 'chef-ice' do
            download_url 'https://example.invalid/chef-ice-19.4.61-1_arm64.dmg'
          end
        end
      end.to raise_error(Chef::Exceptions::ValidationFailed, /explicit version/)
    end

    it 'no longer runs migrate-ice itself' do
      # find_resource evaluates lazy properties of every execute it scans; match by name only.
      names = deb_run.resource_collection.all_resources.map(&:to_s)
      expect(names).to_not include('execute[migrate-ice apply airgap]')
    end

    it 'writes /tmp/chef_env root-owned, 0600 and sensitive, only via a :before notification' do
      run = deb_run
      env = env_file_resource(run)
      pkg = run.find_resource(:dpkg_package, 'chef-ice')
      expect(env.action).to eq([:nothing])
      expect(env.owner).to eq('root')
      expect(env.group).to eq(0)
      expect(env.mode).to eq('0600')
      expect(env.sensitive).to be true
      expect(notified?(pkg, "file[#{env_file}]", :create, :before)).to be true
      expect(notified?(pkg, "file[#{env_file}]", :delete, :delayed)).to be true
    end

    it 'deletes a stale /tmp/chef_env after the package step, never on failure' do
      run = deb_run
      names = run.resource_collection.all_resources.map(&:to_s)
      stale = names.index('file[remove stale /tmp/chef_env]')
      expect(stale).to be > names.index('dpkg_package[chef-ice]')
      expect(stale).to be > names.index('ruby_block[verify chef/chef-infra-client 19.4.61 release]')
      env = run.find_resource(:file, 'remove stale /tmp/chef_env')
      expect([env.path, env.action, env.sensitive]).to eq(['/tmp/chef_env', [:delete], true])
      verify = run.find_resource(:ruby_block, 'verify chef/chef-infra-client 19.4.61 release')
      expect(::File).to_not receive(:delete)
      expect { verify.block.call }.to raise_error(RuntimeError, /release with an IDENT file/)
    end

    context 'DEB reinstall when dpkg records the version but no release exists' do
      let(:deb_nobl) { deb_run(manage_binlinks: false) }
      let(:reinstall) { deb_nobl.find_resource(:execute, 'reinstall chef-ice 19.4.61') }

      def guard_passes?(res)
        res.only_if.all?(&:continue?)
      end

      it 'reinstalls the same .deb with dpkg -i and re-sends the settings' do
        expect(reinstall.command).to eq(['dpkg', '-i', deb_nobl.find_resource(:dpkg_package, 'chef-ice').source])
        expect(reinstall.environment).to eq('DEBIAN_FRONTEND' => 'noninteractive')
        expect(notified?(reinstall, "file[#{env_file}]", :create, :before)).to be true
        expect(notified?(reinstall, "file[#{env_file}]", :delete, :delayed)).to be true
        expect(notified?(reinstall, reconverge, :reconverge, :delayed)).to be true
      end

      it 'runs when dpkg records the target version and the release is missing' do
        allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
          .to receive(:native_version_installed?).with('chef-ice', '19.4.61').and_return(true)
        expect(guard_passes?(reinstall)).to be true
      end

      it 'does not run right after dpkg_package installed the package' do
        allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
          .to receive(:native_version_installed?).and_return(true)
        deb_nobl.find_resource(:dpkg_package, 'chef-ice').updated_by_last_action(true)
        expect(guard_passes?(reinstall)).to be false
      end

      it 'does not run when dpkg does not record the target version' do
        allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
          .to receive(:native_version_installed?).with('chef-ice', '19.4.61').and_return(false)
        expect(guard_passes?(reinstall)).to be false
      end

      it 'does not run when the release is already present' do
        res = reinstall
        allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
          .to receive(:native_version_installed?).and_return(true)
        allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
          .to receive(:hab_pkg_dirs).and_return(['/hab/pkgs/chef/chef-infra-client/19.4.61/20260601120000'])
        expect(guard_passes?(res)).to be false
      end
    end

    context 'RPM reinstall when rpm records the version but no release exists' do
      let(:rpm_run) { linux_install('almalinux', '9', 'https://example.invalid/chef-ice-19.4.61-1.x86_64.rpm', manage_binlinks: false) }
      let(:reinstall) { rpm_run.find_resource(:execute, 'reinstall chef-ice 19.4.61') }

      def guard_passes?(res)
        res.only_if.all?(&:continue?)
      end

      it 'reinstalls the same file with rpm -U --replacepkgs and re-sends the settings' do
        expect(reinstall.command).to eq(['rpm', '-U', '--replacepkgs', rpm_run.find_resource(:rpm_package, 'chef-ice').source])
        expect(notified?(reinstall, "file[#{env_file}]", :create, :before)).to be true
        expect(notified?(reinstall, "file[#{env_file}]", :delete, :delayed)).to be true
        expect(notified?(reinstall, reconverge, :reconverge, :delayed)).to be true
      end

      it 'runs when rpm records the target version and the release is missing' do
        allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
          .to receive(:native_version_installed?).with('chef-ice', '19.4.61').and_return(true)
        expect(guard_passes?(reinstall)).to be true
      end

      it 'does not run when rpm does not record the target version' do
        allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
          .to receive(:native_version_installed?).with('chef-ice', '19.4.61').and_return(false)
        expect(guard_passes?(reinstall)).to be false
      end

      it 'does not run when the release is already present' do
        res = reinstall
        allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
          .to receive(:native_version_installed?).and_return(true)
        allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
          .to receive(:hab_pkg_dirs).and_return(['/hab/pkgs/chef/chef-infra-client/19.4.61/20260601120000'])
        expect(guard_passes?(res)).to be false
      end

      it 'does not run when rpm_package itself just installed' do
        allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
          .to receive(:native_version_installed?).and_return(true)
        rpm_run.find_resource(:rpm_package, 'chef-ice').updated_by_last_action(true)
        expect(guard_passes?(reinstall)).to be false
      end
    end

    it 'skips release verification when the release is already present' do
      verify = deb_run.find_resource(:ruby_block, 'verify chef/chef-infra-client 19.4.61 release')
      allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
        .to receive(:hab_pkg_dirs).and_return(['/hab/pkgs/chef/chef-infra-client/19.4.61/20260601120000'])
      expect(verify.not_if.any?(&:continue?)).to be false
    end

    it 'passes the default settings: binlinking on, omnibus preserved, fstab ignore' do
      content = env_file_resource(deb_run).content
      expect(content).to include("CHEF_SKIP_BINLINKING=false\n", "CHEF_PRESERVE_OMNIBUS=true\n",
                                 "CHEF_FSTAB=ignore\n", "CHEF_LICENSE_KEY=abc123\n")
    end

    it 'always tells the installer to keep old releases for cleanup' do
      expect(env_file_resource(deb_run).content).to include("CHEF_SKIP_OLD_RELEASE_REMOVAL=true\n")
    end

    it 'skips binlinking and declares no binlinks resource when manage_binlinks is false' do
      run = deb_run(manage_binlinks: false)
      expect(env_file_resource(run).content).to include("CHEF_SKIP_BINLINKING=true\n")
      expect(run.find_resource(:chef_client_updater_enterprise_binlinks, 'default')).to be_nil
    end

    it 'declares the binlinks resource when manage_binlinks is true' do
      expect(deb_run.find_resource(:chef_client_updater_enterprise_binlinks, 'default')).to_not be_nil
    end

    it 'forces omnibus preservation while chef-client itself runs from the omnibus install' do
      allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
        .to receive(:running_under_omnibus?).and_return(true)
      content = env_file_resource(deb_run(preserve_omnibus: false)).content
      expect(content).to include("CHEF_PRESERVE_OMNIBUS=true\n")
    end

    it 'honors preserve_omnibus false when not running from omnibus' do
      content = env_file_resource(deb_run(preserve_omnibus: false)).content
      expect(content).to include("CHEF_PRESERVE_OMNIBUS=false\n", "CHEF_FSTAB=apply\n")
    end

    it 'notifies scheduler reconvergence from the package resource' do
      pkg = deb_run.find_resource(:dpkg_package, 'chef-ice')
      expect(notified?(pkg, reconverge, :reconverge, :delayed)).to be true
    end

    it 'refuses chef-ice releases up to 19.4.50' do
      expect do
        converge_resource(platform: 'ubuntu', version: '24.04') do
          chef_client_updater_enterprise_install 'chef-ice' do
            version '19.4.50'
            download_url 'https://example.invalid/chef-ice-19.4.50-1_amd64.deb'
          end
        end
      end.to raise_error(Chef::Exceptions::ValidationFailed, /not supported/)
    end

    it "allows download_url with version 'latest' (version unknown, gate skipped)" do
      run = converge_resource(platform: 'ubuntu', version: '24.04') do
        chef_client_updater_enterprise_install 'chef-ice' do
          download_url 'https://example.invalid/chef-ice-latest_amd64.deb'
        end
      end
      expect(run.find_resource(:dpkg_package, 'chef-ice')).to_not be_nil
    end
  end

  # `version` is compared against the literal string 'latest' in resources/install.rb,
  # resources/binlinks.rb and Helpers#chef_client_hab_binary_path. Before the shared
  # property gained a coerce, install.rb's case-sensitive `== 'latest'` disagreed with
  # binlinks.rb's case-insensitive check, so `version 'Latest'` was simultaneously
  # treated as an explicitly pinned version named "Latest" and as "newest installed".
  context 'property normalization and validation' do
    def install_resource(chef_run)
      chef_run.resource_collection.all_resources.find do |r|
        r.resource_name == :chef_client_updater_enterprise_install
      end
    end

    def converge_with(&block)
      stub_not_installed
      converge_resource(platform: 'ubuntu', version: '24.04', &block)
    end

    it "normalizes any casing of 'latest' to the lowercase form both resources compare against" do
      run = converge_with do
        chef_client_updater_enterprise_install 'chef-ice' do
          version 'LaTeSt'
          download_url 'https://example.invalid/chef-ice.deb'
          manage_binlinks false
          update_scheduler_resources false
        end
      end

      expect(install_resource(run).version).to eq('latest')
    end

    it 'leaves an explicitly pinned version untouched' do
      run = converge_with do
        chef_client_updater_enterprise_install 'chef-ice' do
          version '19.4.61'
          download_url 'https://example.invalid/chef-ice.deb'
          manage_binlinks false
          update_scheduler_resources false
        end
      end

      expect(install_resource(run).version).to eq('19.4.61')
    end

    it 'accepts channel as a String and coerces it to the Symbol the API helper expects' do
      run = converge_with do
        chef_client_updater_enterprise_install 'chef-ice' do
          channel 'Stable'
          download_url 'https://example.invalid/chef-ice.deb'
          manage_binlinks false
          update_scheduler_resources false
        end
      end

      expect(install_resource(run).channel).to eq(:stable)
    end

    it 'rejects an unknown channel' do
      expect do
        converge_with do
          chef_client_updater_enterprise_install 'chef-ice' do
            channel 'nightly'
            download_url 'https://example.invalid/chef-ice.deb'
          end
        end
      end.to raise_error(Chef::Exceptions::ValidationFailed, /channel/)
    end

    it 'rejects a negative download_retries rather than silently disabling retries' do
      expect do
        converge_with do
          chef_client_updater_enterprise_install 'chef-ice' do
            download_url 'https://example.invalid/chef-ice.deb'
            download_retries(-1)
          end
        end
      end.to raise_error(Chef::Exceptions::ValidationFailed, /download_retries/)
    end

    it 'rejects a negative download_retry_delay' do
      expect do
        converge_with do
          chef_client_updater_enterprise_install 'chef-ice' do
            download_url 'https://example.invalid/chef-ice.deb'
            download_retry_delay(-30)
          end
        end
      end.to raise_error(Chef::Exceptions::ValidationFailed, /download_retry_delay/)
    end

    # license_key is credential material, and download_* / preserve_omnibus /
    # fstab_handling describe HOW to reach the desired state rather than what the
    # desired state is, so none of them belong in the resource's reported state.
    it 'keeps how-to-get-there properties out of the reported desired state' do
      run = converge_with do
        chef_client_updater_enterprise_install 'chef-ice' do
          download_url 'https://example.invalid/chef-ice.deb'
          manage_binlinks false
          update_scheduler_resources false
        end
      end
      state_properties = install_resource(run).class.state_properties.map(&:name)

      expect(state_properties).to include(:product_name, :version, :channel, :habitat_package)
      expect(state_properties).to_not include(
        :license_key, :download_dir, :download_url, :checksum, :download_retries,
        :download_retry_delay, :manage_binlinks, :update_scheduler_resources,
        :preserve_omnibus, :fstab_handling
      )
    end
  end

  # The MSI runs migrate-ice inside the msiexec transaction, so the windows_package
  # resource itself must carry the reconvergence notification.
  context 'scheduler reconvergence notification wiring' do
    before do
      allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
        .to receive(:current_native_version).and_return(nil)
      allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
        .to receive(:hab_pkg_dirs).and_return([])
      allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
        .to receive(:repair_windows_path!).and_return(nil)
    end

    it 'notifies reconvergence from the Windows package resource' do
      run = converge_resource(platform: 'windows', version: '2022') do
        chef_client_updater_enterprise_install 'chef-ice' do
          license_key 'abc'
          download_url 'https://example.invalid/chef-ice-19.4.61-1.x86_64.msi'
          checksum 'a' * 64
        end
      end

      pkg = run.find_resource(:windows_package, 'chef-ice')
      notification = pkg.delayed_notifications.find do |n|
        n.resource.to_s == 'chef_client_updater_enterprise_scheduler_reconvergence[default]'
      end

      expect(notification).to_not be_nil
      expect(notification.action).to eq(:reconverge)
    end
  end

  # chef-ice MSIs older than 19.3.15 carry no SetTARGETDIR custom action, so
  # Windows Installer resolves TARGETDIR from ROOTDRIVE (the fixed drive with
  # the most free space). Every path helper in this cookbook assumes C:\hab, and
  # the MSI's own PostInstall.ps1 shells out to a hardcoded
  # C:\hab\migration\bin\migrate-ice.exe, so an install anywhere else fails with
  # a bare msiexec 1603.
  context 'Windows msiexec options' do
    before do
      allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
        .to receive(:current_native_version).and_return(nil)
      allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
        .to receive(:hab_pkg_dirs).and_return([])
      allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
        .to receive(:repair_windows_path!).and_return(nil)
    end

    def windows_install(**props)
      converge_resource(platform: 'windows', version: '2022') do
        chef_client_updater_enterprise_install 'chef-ice' do
          license_key 'abc'
          download_url 'https://example.invalid/chef-ice-19.4.61-1.x86_64.msi'
          checksum 'a' * 64
          props.each { |k, v| send(k, v) }
        end
      end
    end

    it 'declares no /tmp/chef_env cleanup on Windows' do
      names = windows_install.resource_collection.all_resources.map(&:to_s)
      expect(names.grep(/chef_env/)).to be_empty
    end

    it 'always pins TARGETDIR to the Windows volume' do
      pkg = windows_install.find_resource(:windows_package, 'chef-ice')

      expect(pkg.options).to include('TARGETDIR=C:\\')
    end

    it 'adds CHEF_PRESERVE_OMNIBUS only when preserve_omnibus is set' do
      expect(windows_install(preserve_omnibus: true).find_resource(:windows_package, 'chef-ice').options)
        .to include('CHEF_PRESERVE_OMNIBUS=1')
      expect(windows_install(preserve_omnibus: false).find_resource(:windows_package, 'chef-ice').options)
        .to_not include('CHEF_PRESERVE_OMNIBUS=1')
    end

    it 'adds CHEF_SKIP_BINLINKING only when manage_binlinks is false' do
      expect(windows_install(manage_binlinks: false).find_resource(:windows_package, 'chef-ice').options)
        .to include('CHEF_SKIP_BINLINKING=1')
      expect(windows_install.find_resource(:windows_package, 'chef-ice').options)
        .to_not include('CHEF_SKIP_BINLINKING')
    end

    it 'always passes CHEF_SKIP_OLD_RELEASE_REMOVAL=1' do
      expect(windows_install.find_resource(:windows_package, 'chef-ice').options)
        .to include('CHEF_SKIP_OLD_RELEASE_REMOVAL=1')
    end

    context 'MSI reinstall when the product is registered but no release exists' do
      let(:win_run) { windows_install(version: '19.4.61', manage_binlinks: false) }
      let(:reinstall) { win_run.find_resource(:execute, 'reinstall chef-ice 19.4.61') }
      let(:stage) { win_run.find_resource(:remote_file, 'stage chef-ice 19.4.61 MSI for repair') }

      before do
        allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
          .to receive(:windows_msi_package_name).and_return(nil)
      end
      let(:license_env) { 'windows_env[CHEF_LICENSE_KEY for chef-ice MSI install]' }

      def guard_passes?(res)
        res.only_if.all?(&:continue?)
      end

      def notified?(res, target, action, timing)
        list = timing == :before ? res.before_notifications : res.delayed_notifications
        list.any? { |n| n.resource.to_s == target && n.action == action }
      end

      it 'reinstalls the same MSI with REINSTALL=ALL and the install properties, never /fa' do
        cmd = reinstall.command
        expect(cmd).to start_with('msiexec.exe /i "')
        expect(cmd).to include('REINSTALL=ALL REINSTALLMODE=vamus')
        expect(cmd).to include('TARGETDIR=C:\\', 'CHEF_SKIP_OLD_RELEASE_REMOVAL=1', 'CHEF_SKIP_BINLINKING=1')
        expect(cmd).to include('/qn /norestart /l*v "')
        expect(cmd).to_not include('/fa')
        expect(cmd[%r{/i "([^"]+)"}, 1]).to_not include('/')
        expect([reinstall.returns, reinstall.timeout]).to eq([[0, 3010], 1800])
      end

      it 'omits CHEF_SKIP_BINLINKING when manage_binlinks is true' do
        res = windows_install(version: '19.4.61').resource_collection.all_resources.find { |r| r.to_s == 'execute[reinstall chef-ice 19.4.61]' }
        expect(res.command).to_not include('CHEF_SKIP_BINLINKING')
      end

      it 'brackets the run with the license key and notifies reconvergence' do
        expect(notified?(reinstall, license_env, :create, :before)).to be true
        expect(notified?(reinstall, license_env, :delete, :delayed)).to be true
        expect(notified?(reinstall, 'chef_client_updater_enterprise_scheduler_reconvergence[default]', :reconverge, :delayed)).to be true
      end

      it 'runs when the MSI records the target version and the release is missing' do
        allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
          .to receive(:native_version_installed?).with('chef-ice', '19.4.61').and_return(true)
        expect(guard_passes?(reinstall)).to be true
      end

      it 'does not run right after windows_package installed the MSI' do
        allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
          .to receive(:native_version_installed?).and_return(true)
        win_run.find_resource(:windows_package, 'chef-ice').updated_by_last_action(true)
        expect(guard_passes?(reinstall)).to be false
      end

      it 'does not run when the MSI does not record the target version' do
        allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
          .to receive(:native_version_installed?).with('chef-ice', '19.4.61').and_return(false)
        expect(guard_passes?(reinstall)).to be false
      end

      it 'repairs from the downloaded MSI when no package name is recorded' do
        expect(reinstall.command[%r{/i "([^"]+)"}, 1]).to end_with('\\chef-ice-19.4.61.msi')
        allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
          .to receive(:native_version_installed?).and_return(true)
        expect(guard_passes?(stage)).to be false
      end

      it 'stages the MSI under the recorded package name and repairs from it' do
        allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
          .to receive(:windows_msi_package_name).with('chef-ice', '19.4.61').and_return('chef-ice-19.4.61-1_x64.msi')
        allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
          .to receive(:native_version_installed?).and_return(true)
        expect(reinstall.command[%r{/i "([^"]+)"}, 1]).to end_with('\\chef-ice-19.4.61-1_x64.msi')
        expect(stage.path).to end_with('/chef-ice-19.4.61-1_x64.msi')
        expect(stage.source.first).to start_with('file:///').and end_with('/chef-ice-19.4.61.msi')
        expect(guard_passes?(stage)).to be true
      end

      it 'does not stage when the recorded name differs only in case' do
        allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
          .to receive(:windows_msi_package_name).and_return('CHEF-ICE-19.4.61.MSI')
        allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
          .to receive(:native_version_installed?).and_return(true)
        expect(guard_passes?(stage)).to be false
        expect(reinstall.command[%r{/i "([^"]+)"}, 1]).to end_with('\\chef-ice-19.4.61.msi')
      end

      it 'does not stage when no repair is needed' do
        allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
          .to receive(:windows_msi_package_name).and_return('chef-ice-19.4.61-1_x64.msi')
        allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
          .to receive(:native_version_installed?).and_return(false)
        expect(guard_passes?(stage)).to be false
      end

      it 'does not run when the release is already present' do
        res = reinstall
        allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
          .to receive(:native_version_installed?).and_return(true)
        allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
          .to receive(:hab_pkg_dirs).and_return(['C:/hab/pkgs/chef/chef-infra-client/19.4.61/20260601120000'])
        expect(guard_passes?(res)).to be false
      end
    end
  end

  # windows_env has no idempotency of its own — :create unconditionally rewrites
  # the value and :delete unconditionally removes it — so the license-key pair
  # bracketing the MSI install must be action :nothing and driven purely by
  # notifications from the package resource. The :before notification delegates
  # the "will this actually install?" decision to windows_package's own MSI
  # ProductCode/version check rather than a second, independently-derived guard.
  context 'Windows license key env var wiring' do
    before do
      allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
        .to receive(:current_native_version).and_return(nil)
      allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
        .to receive(:hab_pkg_dirs).and_return([])
      allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
        .to receive(:repair_windows_path!).and_return(nil)
    end

    let(:run) do
      converge_resource(platform: 'windows', version: '2022') do
        chef_client_updater_enterprise_install 'chef-ice' do
          license_key 'abc'
          download_url 'https://example.invalid/chef-ice-19.4.61-1.x86_64.msi'
          checksum 'a' * 64
        end
      end
    end

    let(:pkg) { run.find_resource(:windows_package, 'chef-ice') }

    it 'declares the env resource with action :nothing' do
      expect(run.find_resource(:windows_env, 'CHEF_LICENSE_KEY for chef-ice MSI install').action)
        .to eq([:nothing])
    end

    it 'creates the env var via a :before notification from the package' do
      notification = pkg.before_notifications.find do |n|
        n.resource.to_s == 'windows_env[CHEF_LICENSE_KEY for chef-ice MSI install]'
      end

      expect(notification).to_not be_nil
      expect(notification.action).to eq(:create)
    end

    it 'deletes the env var via a :delayed notification from the package' do
      notification = pkg.delayed_notifications.find do |n|
        n.resource.to_s == 'windows_env[CHEF_LICENSE_KEY for chef-ice MSI install]' &&
          n.action == :delete
      end

      expect(notification).to_not be_nil
    end

    it 'marks the license key env resource sensitive' do
      env = run.find_resource(:windows_env, 'CHEF_LICENSE_KEY for chef-ice MSI install')

      expect(env.sensitive).to be true
    end

    # download_url needs no key; windows_env rejects a nil value at compile time.
    context 'without a license key' do
      let(:run) do
        converge_resource(platform: 'windows', version: '2022') do
          chef_client_updater_enterprise_install 'chef-ice' do
            license_key nil
            download_url 'https://example.invalid/chef-ice-19.4.61-1.x86_64.msi'
            checksum 'a' * 64
          end
        end
      end

      it 'installs the MSI without staging or notifying the env var' do
        expect(pkg).to_not be_nil
        expect(run.find_resource(:windows_env, 'CHEF_LICENSE_KEY for chef-ice MSI install')).to be_nil
        notified = (pkg.before_notifications + pkg.delayed_notifications).map { |n| n.resource.to_s }
        expect(notified).to_not include('windows_env[CHEF_LICENSE_KEY for chef-ice MSI install]')
      end
    end
  end
end
