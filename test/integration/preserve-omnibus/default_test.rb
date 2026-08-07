# frozen_string_literal: true
#
# InSpec Integration Test:: preserve-omnibus
#
# Verifies chef-ice was installed and binlinked while the legacy omnibus install
# was left intact. `preserve_omnibus` defaults to true, and this recipe never
# declares chef_client_updater_enterprise_remove_omnibus, so /opt/chef (Linux)
# and C:\opscode\chef (Windows) must both survive the converge.

title 'preserve-omnibus verification'

# The recipe installs `latest` (the `version` property's default), so the version
# that lands changes whenever a newer chef-ice is promoted to stable. Discover
# what actually installed rather than hardcoding a number that hard-fails the day
# that happens. An explicit input still wins, for a deliberately pinned run.
pinned = input('expected_chef_ice_version', value: nil)
pinned = nil unless pinned.is_a?(String) && !pinned.empty?

installed_versions =
  if os.windows?
    powershell('Get-ChildItem -Name C:\hab\pkgs\chef\chef-infra-client').stdout
  else
    command('ls -1 /hab/pkgs/chef/chef-infra-client').stdout
  end.split("\n").map(&:strip).grep(/\A\d+(\.\d+)*\z/)

expected_version = pinned || installed_versions.max_by { |v| Gem::Version.new(v) }

describe 'installed chef-infra-client Habitat versions' do
  subject { installed_versions }
  it { should_not be_empty }
end

describe command('chef-client --version') do
  its('exit_status') { should eq 0 }
  its('stdout') { should match(/Chef Infra Client/) }
  its('stdout') { should include(expected_version) } if expected_version
end

if os.linux?
  describe file('/usr/bin/chef-client') do
    it { should exist }
    it { should be_symlink }
    it { should be_executable }
    its('link_path') { should include('/hab/pkgs/chef/chef-infra-client/') }
    its('link_path') { should include(expected_version) } if expected_version
  end

  # The whole point of this suite: the omnibus install must still be there.
  describe file('/opt/chef') do
    it { should exist }
    it { should be_directory }
  end
end

if os.windows?
  describe file('C:/hab/bin/chef-client.bat') do
    it { should exist }
    its('content') { should include(expected_version) } if expected_version
  end

  # Windows equivalent of the /opt/chef assertion above. This is what proves the
  # MSI's CHEF_PRESERVE_OMNIBUS=1 property actually reached migrate-ice; without
  # it this suite verified nothing about preservation on Windows at all.
  describe file('C:/opscode/chef') do
    it { should exist }
    it { should be_directory }
  end
end
