# frozen_string_literal: true
#
# InSpec Integration Test:: scheduler-fix
#
# Verifies chef_client_updater_enterprise_install's scheduler resource reconvergence:
# after chef-ice is installed/binlinked, each already-declared
# chef_client_cron/chef_client_systemd_timer/chef_client_launchd/
# chef_client_scheduled_task resource has its chef_binary_path explicitly set to the
# resolved, fully-versioned Habitat path (Helpers#chef_client_hab_binary_path) and its
# action re-run, all within the same converge — no second chef-client run required.
#
# The fully-versioned path (not the stable /usr/bin/chef-client binlink symlink) is used
# deliberately: pointing a root-run scheduled job at a mutable, well-known-path symlink
# is a standing local privilege-escalation risk. See AGENTS.md "Scheduler Reconvergence".

title 'scheduler-fix verification'

# The recipe installs `latest`, so resolve the version from the target instead of
# hardcoding one. An explicit input still wins, for a deliberately pinned run.
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
  # e.g. /hab/pkgs/chef/chef-infra-client/19.3.15/20260601120000/bin/chef-client
  versioned_path_regex =
    %r{/hab/pkgs/chef/chef-infra-client/#{Regexp.escape(expected_version.to_s)}/\d+/bin/chef-client}

  describe file('/etc/cron.d/chef-client') do
    it { should exist }
    its('content') { should match(versioned_path_regex) } if expected_version
    its('content') { should_not match(%r{/opt/chef/}) }
    its('content') { should_not match(%r{/usr/bin/chef-client}) }
  end

  describe file('/etc/systemd/system/chef-client.service') do
    it { should exist }
    its('content') { should match(versioned_path_regex) } if expected_version
    its('content') { should_not match(%r{/opt/chef/}) }
    its('content') { should_not match(%r{/usr/bin/chef-client}) }
  end

  # chef_client_systemd_timer declares a .timer alongside the .service; without
  # the timer the service is never actually scheduled, so assert it landed too.
  describe file('/etc/systemd/system/chef-client.timer') do
    it { should exist }
  end
end

if os.windows?
  versioned_path_regex =
    /C:\\hab\\pkgs\\chef\\chef-infra-client\\#{Regexp.escape(expected_version.to_s)}\\\d+\\bin\\chef-client\.bat/i

  describe command('schtasks /query /tn chef-client /xml') do
    its('exit_status') { should eq 0 }
    its('stdout') { should_not match(/opscode\\chef/i) }
    its('stdout') { should match(versioned_path_regex) } if expected_version
  end
end
