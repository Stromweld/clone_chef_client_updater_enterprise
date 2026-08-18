# frozen_string_literal: true

require 'spec_helper'

# Unit coverage for chef_client_updater_enterprise_scheduler_reconvergence in isolation
# (extracted from resources/install.rb; see AGENTS.md "Scheduler Reconvergence").
# Follows the same low-level stubbing pattern as install_spec.rb: fake the filesystem
# primitives current_installed_version/chef_client_hab_binary_path read, not the helper
# methods themselves.
describe 'chef_client_updater_enterprise_scheduler_reconvergence' do
  let(:hab_pkg) { 'chef/chef-infra-client' }
  let(:pinned_version) { '19.3.15' }
  let(:root) { "/hab/pkgs/#{hab_pkg}" }
  let(:release_dir) { "#{root}/#{pinned_version}/20260601120000" }
  let(:resolved_binary_path) { "#{release_dir}/bin/chef-client" }

  def stub_installed_pinned_version
    allow(::File).to receive(:executable?).and_return(false)
    allow(::File).to receive(:directory?).and_call_original
    allow(::File).to receive(:directory?).with(root).and_return(true)
    allow(::File).to receive(:directory?).with(release_dir).and_return(true)
    allow(::Dir).to receive(:glob).with("#{root}/*/*").and_return([release_dir])
    allow(::File).to receive(:exist?).and_call_original
    allow(::File).to receive(:exist?).with(resolved_binary_path).and_return(true)
  end

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

  context 'when the pinned version is installed' do
    let(:chef_run) do
      stub_installed_pinned_version
      pinned = pinned_version
      pkg = hab_pkg

      converge_resource do
        chef_client_cron 'chef-client'
        chef_client_systemd_timer 'chef-client'

        chef_client_updater_enterprise_scheduler_reconvergence 'default' do
          habitat_package pkg
          version pinned
        end
      end
    end

    it 'sets chef_binary_path on chef_client_cron to the resolved Habitat path' do
      resource = scheduler_resource(chef_run, :chef_client_cron, 'chef-client')
      expect(resource.chef_binary_path).to eq(resolved_binary_path)
    end

    it 'sets chef_binary_path on chef_client_systemd_timer to the resolved Habitat path' do
      resource = scheduler_resource(chef_run, :chef_client_systemd_timer, 'chef-client')
      expect(resource.chef_binary_path).to eq(resolved_binary_path)
    end
  end

  context 'when no scheduler resources are declared' do
    it 'does not error' do
      stub_installed_pinned_version
      pinned = pinned_version
      pkg = hab_pkg

      expect do
        converge_resource do
          chef_client_updater_enterprise_scheduler_reconvergence 'default' do
            habitat_package pkg
            version pinned
          end
        end
      end.to_not raise_error
    end
  end

  context 'when the requested package/version is not installed' do
    it 'logs a warning and does not touch declared scheduler resources' do
      stub_not_installed
      pkg = hab_pkg

      chef_run = converge_resource do
        chef_client_cron 'chef-client'

        chef_client_updater_enterprise_scheduler_reconvergence 'default' do
          habitat_package pkg
          version 'latest'
        end
      end

      resource = scheduler_resource(chef_run, :chef_client_cron, 'chef-client')
      expect(resource.chef_binary_path).to eq('')
    end
  end

  context 'when a scheduler resource already points at the resolved binary path' do
    it 'is idempotent: does not re-run the already-correct resource and reports no update' do
      stub_installed_pinned_version
      pinned = pinned_version
      pkg = hab_pkg
      path = resolved_binary_path

      chef_run = converge_resource do
        chef_client_cron 'chef-client' do
          chef_binary_path path
        end

        chef_client_updater_enterprise_scheduler_reconvergence 'default' do
          habitat_package pkg
          version pinned
        end
      end

      resource = scheduler_resource(chef_run, :chef_client_cron, 'chef-client')
      expect(resource.chef_binary_path).to eq(resolved_binary_path)

      reconvergence_resource = chef_run.resource_collection.all_resources.find do |r|
        r.resource_name == :chef_client_updater_enterprise_scheduler_reconvergence && r.name == 'default'
      end
      expect(reconvergence_resource.updated_by_last_action?).to be(false)
    end
  end

  # Regression coverage for the Windows binlink shim path: chef_client_hab_binary_path
  # resolves to the C:\hab\bin\chef-client.bat shim (not a versioned Habitat path) only
  # when the shim's *contents* already name this converge's resolved package ident.
  # windows_binlink_targets? does that verification inside the helper, before this
  # resource's own chef_binary_path == resolved_binary_path comparison ever runs, so the
  # idempotency check here is comparing against an already version-verified value on
  # Windows too.
  context 'on Windows' do
    let(:windows_root) { "C:/hab/pkgs/#{hab_pkg}" }
    let(:windows_release_dir) { "#{windows_root}/#{pinned_version}/20260601120000" }
    let(:shim_path) { 'C:\hab\bin\chef-client.bat' }

    def stub_windows_installed(shim_contents:)
      allow(::File).to receive(:executable?).and_return(false)
      allow(::File).to receive(:directory?).and_call_original
      allow(::File).to receive(:directory?).with(windows_root).and_return(true)
      allow(::File).to receive(:directory?).with(windows_release_dir).and_return(true)
      allow(::Dir).to receive(:glob).with("#{windows_root}/*/*").and_return([windows_release_dir])
      allow(::File).to receive(:exist?).and_call_original
      allow(::File).to receive(:exist?).with(shim_path).and_return(true)
      allow(::File).to receive(:exist?).with(::File.join(windows_release_dir, 'bin', 'chef-client.bat')).and_return(true)
      allow(::File).to receive(:read).and_call_original
      allow(::File).to receive(:read).with(shim_path).and_return(shim_contents)
    end

    it 'is idempotent when the binlink shim already names the resolved version' do
      stub_windows_installed(shim_contents: "hab\\pkgs\\chef\\chef-infra-client\\#{pinned_version}\\20260601120000\\bin\\chef-client.exe")
      pinned = pinned_version
      pkg = hab_pkg
      path = shim_path

      chef_run = converge_resource(platform: 'windows', version: '2022') do
        chef_client_scheduled_task 'chef-client' do
          chef_binary_path path
        end

        chef_client_updater_enterprise_scheduler_reconvergence 'default' do
          habitat_package pkg
          version pinned
        end
      end

      resource = scheduler_resource(chef_run, :chef_client_scheduled_task, 'chef-client')
      expect(resource.chef_binary_path).to eq(shim_path)

      reconvergence_resource = chef_run.resource_collection.all_resources.find do |r|
        r.resource_name == :chef_client_updater_enterprise_scheduler_reconvergence && r.name == 'default'
      end
      expect(reconvergence_resource.updated_by_last_action?).to be(false)
    end

    it 'falls back to the versioned Habitat path and re-runs when the shim is stale' do
      stub_windows_installed(shim_contents: 'hab\pkgs\chef\chef-infra-client\19.2.12\20260101000000\bin\chef-client.exe')
      pinned = pinned_version
      pkg = hab_pkg
      path = shim_path

      chef_run = converge_resource(platform: 'windows', version: '2022') do
        chef_client_scheduled_task 'chef-client' do
          chef_binary_path path
        end

        chef_client_updater_enterprise_scheduler_reconvergence 'default' do
          habitat_package pkg
          version pinned
        end
      end

      resource = scheduler_resource(chef_run, :chef_client_scheduled_task, 'chef-client')
      expect(resource.chef_binary_path).to eq(::File.join(windows_release_dir, 'bin', 'chef-client.bat'))

      reconvergence_resource = chef_run.resource_collection.all_resources.find do |r|
        r.resource_name == :chef_client_updater_enterprise_scheduler_reconvergence && r.name == 'default'
      end
      expect(reconvergence_resource.updated_by_last_action?).to be(true)
    end
  end
end
