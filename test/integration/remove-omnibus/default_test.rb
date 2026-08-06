# frozen_string_literal: true
#
# InSpec Integration Test:: remove-omnibus
#
# Verifies chef-ice was installed, binlinked, and omnibus Chef was removed.

title 'remove-omnibus verification'

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

# remove_omnibus refuses to act until a chef-ice Habitat package is confirmed
# present, so an empty /hab/pkgs here means the removal never really ran.
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
    its('link_path') { should include('hab/pkgs') }
    its('link_path') { should include(expected_version) } if expected_version
  end

  # /opt/chef may be a dedicated Docker VOLUME mountpoint (see AGENTS.md
  # "Omnibus Removal") that can never be rmdir'd — the cookbook only empties
  # its contents in that case, it never deletes the mountpoint itself. Assert
  # the directory is either fully absent OR present-but-empty, not merely
  # absent, so this control doesn't structurally fail against a mounted
  # /opt/chef even when removal behaved correctly.
  describe command(
    'test ! -e /opt/chef || ! find /opt/chef -mindepth 1 -maxdepth 1 -print -quit | grep -q .'
  ) do
    its('exit_status') { should eq 0 }
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
