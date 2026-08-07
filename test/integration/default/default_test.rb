# frozen_string_literal: true
#
# InSpec Integration Test:: default
#
# Verifies canonical usage: chef-ice installed via the Commercial Download API,
# binlinked, then trimmed by cleanup with keep_versions 2.

title 'chef-ice installation verification'

# The recipe installs `latest`, so discover what landed rather than hardcoding.
pinned = input('expected_chef_ice_version', value: nil)
pinned = nil unless pinned.is_a?(String) && !pinned.empty?

installed_versions =
  if os.windows?
    powershell('Get-ChildItem -Name C:\hab\pkgs\chef\chef-infra-client').stdout
  else
    command('ls -1 /hab/pkgs/chef/chef-infra-client').stdout
  end.split("\n").map(&:strip).grep(/\A\d+(\.\d+)*\z/)

expected_version = pinned || installed_versions.max_by { |v| Gem::Version.new(v) }

# chef-client binary must be callable and report the correct product name
describe command('chef-client --version') do
  its('exit_status') { should eq 0 }
  its('stdout') { should match(/Chef Infra Client/) }
  its('stdout') { should include(expected_version) } if expected_version
end

# Coverage for `chef_client_updater_enterprise_cleanup ... keep_versions 2`, which
# this suite declares but previously asserted nothing about. An upper bound catches
# a cleanup that never trimmed; the lower bound catches one that removed everything
# (including the version the running chef-client is executing from).
describe 'chef-infra-client Habitat versions retained by cleanup (keep_versions 2)' do
  subject { installed_versions.length }
  it { should be >= 1 }
  it { should be <= 2 }
end

# Platform-specific binlink checks
# Linux: explicit --dest /usr/bin (well-known, always in PATH)
if os.linux?
  describe file('/usr/bin/chef-client') do
    it { should exist }
    it { should be_symlink }
    it { should be_executable }
    # Without this the control passes against a leftover omnibus symlink, which
    # is exactly the state this cookbook exists to replace.
    its('link_path') { should include('/hab/pkgs/chef/chef-infra-client/') }
    its('link_path') { should include(expected_version) } if expected_version
  end
end

# macOS: explicit --dest /usr/local/bin (SIP protects /usr/bin)
if os.darwin?
  describe file('/usr/local/bin/chef-client') do
    it { should exist }
    it { should be_symlink }
    it { should be_executable }
    its('link_path') { should include('/hab/pkgs/chef/chef-infra-client/') }
  end
end

# Windows: binlinked as a .bat shim in C:\hab\bin (added to PATH via windows_path)
if os.windows?
  describe file('C:\hab\bin\chef-client.bat') do
    it { should exist }
    its('content') { should include(expected_version) } if expected_version
  end
end
