# frozen_string_literal: true
#
# InSpec Integration Test:: remove-omnibus
#
# Verifies chef-ice was installed, binlinked, and omnibus Chef was removed.

title 'remove-omnibus verification'

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
    its('link_path') { should include('hab/pkgs') }
  end

  describe file('/opt/chef') do
    it { should_not exist }
  end

  describe package('chef') do
    it { should_not be_installed }
  end
end

if os.windows?
  describe file('C:/opscode/chef') do
    it { should_not exist }
  end

  # Matches the display name Get-Package sees in Programs and Features, not
  # legacy_omnibus_package ('chef') — see resources/remove_omnibus.rb.
  describe package('Chef Infra Client*') do
    it { should_not be_installed }
  end
end
