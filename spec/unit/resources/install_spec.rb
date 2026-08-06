# frozen_string_literal: true

require 'spec_helper'

# Regression coverage for the chef_binary_path flip-flop bug (see AGENTS.md
# "Scheduler Resource Reconvergence"): action :install's "already at pinned
# version" branch used to `return` before reconverging scheduler resources,
# so a no-op converge left chef_client_cron/systemd_timer/etc.'s own
# chef_binary_path default (which varies by bootstrapping Chef gem vintage)
# unoverridden. reconverge_installed_scheduler_resources must run on BOTH the
# already-installed short-circuit and a genuine install/upgrade.
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
  let(:pinned_version) { '19.3.15' }
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
    allow(::File).to receive(:exist?).and_call_original
    allow(::File).to receive(:exist?).with(resolved_binary_path).and_return(true)
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

    it 'still sets chef_binary_path on chef_client_cron even though nothing was (re)installed' do
      resource = scheduler_resource(chef_run, :chef_client_cron, 'chef-client')
      expect(resource.chef_binary_path).to eq(resolved_binary_path)
    end

    it 'still sets chef_binary_path on chef_client_systemd_timer even though nothing was (re)installed' do
      resource = scheduler_resource(chef_run, :chef_client_systemd_timer, 'chef-client')
      expect(resource.chef_binary_path).to eq(resolved_binary_path)
    end

    it 'does not attempt to (re)install the package' do
      expect(chef_run).to_not install_rpm_package('chef-ice')
      expect(chef_run).to_not install_package('chef-ice')
    end
  end

  context 'the same pinned-and-installed state reconverges a second time' do
    # Regression-specific: the bug only manifested because the OLD action
    # returned early. A single converge already exercises the "already
    # installed" branch above; this second, independent converge proves the
    # resolved path stays stable across repeated no-op runs rather than
    # reverting to whatever the scheduler resource's own built-in default
    # would otherwise compute.
    let(:first_run) do
      stub_installed_pinned_version
      pinned = pinned_version

      converge_resource do
        chef_client_cron 'chef-client'

        chef_client_updater_enterprise_install 'chef-ice' do
          version pinned
        end
      end
    end

    let(:second_run) do
      stub_installed_pinned_version
      pinned = pinned_version

      converge_resource do
        chef_client_cron 'chef-client'

        chef_client_updater_enterprise_install 'chef-ice' do
          version pinned
        end
      end
    end

    it 'resolves the identical chef_binary_path on every subsequent no-op converge' do
      first_path = scheduler_resource(first_run, :chef_client_cron, 'chef-client').chef_binary_path
      second_path = scheduler_resource(second_run, :chef_client_cron, 'chef-client').chef_binary_path

      expect(first_path).to eq(resolved_binary_path)
      expect(second_path).to eq(resolved_binary_path)
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
      allow(::File).to receive(:executable?).and_return(false)
      allow(::File).to receive(:directory?).and_call_original
      allow(::File).to receive(:directory?).with(root).and_return(false)
      allow(::Dir).to receive(:glob).and_call_original
      allow(::Dir).to receive(:glob).with("#{root}/*/*").and_return([])
      expected = checksum

      converge_resource(platform: 'ubuntu', version: '24.04') do
        chef_client_updater_enterprise_install 'chef-ice' do
          version '19.3.15'
          download_url 'https://chefdownload-commercial.chef.io/files/stable/chef-ice/19.3.15/' \
                       'linux/x86_64/deb/chef-ice-19.3.15-1_amd64.deb'
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
      run = converge_resource(platform: 'ubuntu', version: '24.04') do
        chef_client_updater_enterprise_install 'chef-ice' do
          version '19.3.15'
          download_url 'https://example.invalid/files/chef-ice-19.3.15-1.x86_64.msi?license_id=free-abc'
          manage_binlinks false
          update_scheduler_resources false
        end
      end
      remote = run.resource_collection.all_resources.find { |r| r.resource_name == :remote_file }

      expect(remote.path).to end_with('.msi')
    end

    it 'raises an actionable error when the download URL has no package extension' do
      expect do
        converge_resource(platform: 'ubuntu', version: '24.04') do
          chef_client_updater_enterprise_install 'chef-ice' do
            version '19.3.15'
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
      expect do
        converge_resource(platform: 'ubuntu', version: '24.04') do
          chef_client_updater_enterprise_install 'chef-ice' do
            version '19.3.15'
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
      run = converge_resource(platform: 'ubuntu', version: '24.04') do
        chef_client_updater_enterprise_install 'chef-ice' do
          version '19.3.15'
          download_url 'https://example.invalid/chef-ice-19.3.15-1_amd64.deb'
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
      allow(::File).to receive(:executable?).and_return(false)
      allow(::File).to receive(:directory?).and_call_original
      allow(::File).to receive(:directory?).with(root).and_return(false)
      allow(::Dir).to receive(:glob).and_call_original
      allow(::Dir).to receive(:glob).with("#{root}/*/*").and_return([])
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
          version '19.3.15'
          download_url 'https://example.invalid/chef-ice.deb'
          manage_binlinks false
          update_scheduler_resources false
        end
      end

      expect(install_resource(run).version).to eq('19.3.15')
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

  # execute[migrate-ice apply airgap] is guarded by only_if on
  # /hab/migration/bin/migrate-ice, a Linux-only path, so it never runs on
  # Windows — the MSI's own embedded PostInstall.ps1 invokes migrate-ice inside
  # the msiexec transaction instead. Without the windows_package resource
  # carrying the reconvergence notification itself, a chef_client_scheduled_task
  # would never be repointed at the newly installed client on Windows.
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
          download_url 'https://example.invalid/chef-ice-19.3.15-1.x86_64.msi'
          checksum 'a' * 64
        end
      end

      pkg = run.find_resource(:package, 'chef-ice')
      notification = pkg.delayed_notifications.find do |n|
        n.resource.to_s == 'ruby_block[reconverge installed scheduler resources]'
      end

      expect(notification).to_not be_nil
      expect(notification.action).to eq(:run)
    end
  end
end
