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
end
