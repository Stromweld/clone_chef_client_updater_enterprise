# frozen_string_literal: true
#
# InSpec Integration Test:: preserve-omnibus
#
# Verifies chef-ice was installed and binlinked, and chef config is preserved.
# /opt/chef removal is controlled by migrate-ice, not this cookbook's remove_omnibus resource

title 'preserve-omnibus verification'

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
    it { should be_executable }
    its('link_path') { should include(expected_version) }
  end

  # Kitchen writes client.rb to /etc/chef during bootstrap — this is what "preserve" means for a running node
  describe file('/etc/chef') do
    it { should exist }
  end
end

if os.windows?
  describe file('C:/hab/bin/chef-client.bat') do
    it { should exist }
  end
end
