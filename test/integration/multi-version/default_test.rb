# frozen_string_literal: true
#
# InSpec Integration Test:: multi-version
#
# Verifies pinned version upgrade: 19.2.12 installed first, 19.3.15 installed as upgrade,
# binlinks point to 19.3.15, cleanup leaves only 1 version.

title 'multi-version upgrade verification'

describe command('chef-client --version') do
  its('exit_status') { should eq 0 }
  its('stdout') { should match(/Chef Infra Client/) }
end

if os.linux?
  # The third install in this suite's recipe is unpinned ('latest'), so the
  # actually-retained version drifts as Habitat's depot publishes newer
  # chef-infra-client releases — do not hardcode it. Discover it dynamically
  # and additionally assert exactly ONE version directory remains (not just
  # that a plausible-looking one exists), so an incomplete cleanup leaving
  # multiple versions behind can't slip past this control.
  retained_dirs = command('ls -1 /hab/pkgs/chef/chef-infra-client').stdout.split("\n").reject(&:empty?)
  retained_version = retained_dirs.max_by { |v| Gem::Version.new(v) }

  describe retained_dirs do
    it { should_not be_empty }
  end

  describe 'retained chef-infra-client version count' do
    subject { retained_dirs.length }
    it { should eq 1 }
  end

  describe file('/usr/bin/chef-client') do
    it { should exist }
    it { should be_symlink }
    its('link_path') { should include('/hab/pkgs/chef/chef-infra-client/') }
    its('link_path') { should include(retained_version) } if retained_version
  end

  describe file("/hab/pkgs/chef/chef-infra-client/#{retained_version}") do
    it { should exist }
    it { should be_directory }
  end if retained_version

  describe file("/hab/pkgs/chef/chef-infra-client/#{older_version}") do
    it { should_not exist }
  end
end

if os.windows?
  describe file('C:/hab/bin/chef-client.bat') do
    it { should exist }
  end
end
