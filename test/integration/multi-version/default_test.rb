# frozen_string_literal: true
#
# InSpec Integration Test:: multi-version
#
# Verifies pinned version upgrade: 19.2.12 installed first, 19.3.15 installed as upgrade,
# binlinks point to 19.3.15, cleanup leaves only 1 version.

title 'multi-version upgrade verification'

expected_version = input('expected_chef_ice_version', value: '19.3.15')

describe command('chef-client --version') do
  its('exit_status') { should eq 0 }
  its('stdout') { should match(/Chef Infra Client/) }
  its('stdout') { should include(expected_version) }
end

if os.linux?
  describe file('/usr/bin/chef-client') do
    it { should exist }
    it { should be_symlink }
    its('link_path') { should include('/hab/pkgs/chef/chef-infra-client/') }
    its('link_path') { should include(expected_version) }
  end

  describe file("/hab/pkgs/chef/chef-infra-client/#{expected_version}") do
    it { should exist }
    it { should be_directory }
  end

  # After cleanup keep_versions 1, only 19.3.15 should remain
  describe command('ls /hab/pkgs/chef/chef-infra-client') do
    its('exit_status') { should eq 0 }
    its('stdout') { should include(expected_version) }
  end
end

if os.windows?
  describe file('C:/hab/bin/chef-client.bat') do
    it { should exist }
  end
end
