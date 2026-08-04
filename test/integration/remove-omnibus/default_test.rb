# frozen_string_literal: true
#
# InSpec Integration Test:: remove-omnibus
#
# Verifies chef-ice was installed, binlinked, and omnibus Chef was removed.

title 'remove-omnibus verification'

describe command('chef-client --version') do
  its('exit_status') { should eq 0 }
  its('stdout') { should match(/Chef Infra Client/) }
end

if os.linux?
  describe file('/usr/bin/chef-client') do
    it { should exist }
    it { should be_symlink }
    its('link_path') { should include('hab/pkgs') }
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
