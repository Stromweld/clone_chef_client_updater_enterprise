# frozen_string_literal: true

require 'spec_helper'

describe 'chef_client_updater_enterprise_remove_omnibus' do
  def stub_not_running_under_omnibus
    allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
      .to receive(:running_under_omnibus?).and_return(false)
  end

  def stub_hab_pkg_present
    allow_any_instance_of(ChefClientUpdaterEnterprise::Helpers)
      .to receive(:hab_pkg_dirs).and_return(['/hab/pkgs/chef/chef-infra-client/19.3.15/20260519225722'])
  end

  context 'on a Debian-family platform' do
    let(:chef_run) do
      stub_not_running_under_omnibus
      stub_hab_pkg_present
      allow(Dir).to receive(:exist?).and_call_original
      allow(Dir).to receive(:exist?).with('/opt/chef').and_return(false)

      converge_resource(platform: 'ubuntu', version: '22.04') do
        chef_client_updater_enterprise_remove_omnibus 'purge legacy omnibus'
      end
    end

    # A plain `package`/`apt_package action :remove` (i.e. `apt-get remove`)
    # refuses outright with exit 100 ("Unmet dependencies") once chef-ice has
    # been force-unpacked alongside a `Conflicts:`-declaring legacy package —
    # see AGENTS.md and the comment in remove_omnibus.rb. `dpkg_package` with
    # `options '--force-depends'` bypasses apt's dependency resolver instead,
    # mirroring the force-install override install.rb already applies on the
    # install side, while staying a first-class Chef resource (own dpkg-query
    # idempotency, why-run support) rather than a hand-rolled `execute`.
    it 'removes the legacy package via dpkg_package with --force-depends' do
      expect(chef_run).to remove_dpkg_package('chef').with(options: ['--force-depends'])
    end

    it 'does not declare a plain package/apt_package removal resource' do
      expect(chef_run).to_not remove_package('chef')
    end
  end

  context 'on an RHEL-family platform' do
    let(:chef_run) do
      stub_not_running_under_omnibus
      stub_hab_pkg_present
      allow(Dir).to receive(:exist?).and_call_original
      allow(Dir).to receive(:exist?).with('/opt/chef').and_return(false)

      converge_resource(platform: 'redhat', version: '9') do
        chef_client_updater_enterprise_remove_omnibus 'purge legacy omnibus'
      end
    end

    # RHEL is unaffected by the Debian `Conflicts:` apt-resolver failure (see
    # AGENTS.md — no CI job exercises rpm_package on a chef-workstation-bootstrapped
    # host yet), so it still goes through the plain `package` resource.
    it 'still uses the plain package resource, not dpkg_package' do
      expect(chef_run).to remove_package('chef')
    end
  end
end
