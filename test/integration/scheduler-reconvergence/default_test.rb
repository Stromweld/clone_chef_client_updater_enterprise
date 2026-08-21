# frozen_string_literal: true
#
# InSpec Integration Test:: scheduler-reconvergence
#
# Verifies chef_client_updater_enterprise_scheduler_reconvergence declared and run
# STANDALONE (update_scheduler_resources false on the install, with the reconvergence
# resource declared explicitly afterward) reconverges already-declared scheduler
# resources exactly like the automatic wiring exercised by the scheduler-fix suite.
# Assertions mirror test/integration/scheduler-fix/default_test.rb; see that file's
# comments and AGENTS.md "Scheduler Reconvergence" for the reasoning behind the
# Linux/macOS-vs-Windows split.

title 'scheduler-reconvergence verification'

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

  describe file('/etc/systemd/system/chef-client.timer') do
    it { should exist }
  end
end

if os.windows?
  describe command('schtasks /query /tn chef-client /xml') do
    its('exit_status') { should eq 0 }
    its('stdout') { should_not match(%r{opscode[\\/]chef}i) }
    its('stdout') { should match(%r{C:[\\/]hab[\\/]bin[\\/]chef-client\.bat}i) }
  end

  describe file('C:/hab/bin/chef-client.bat') do
    it { should exist }
    its('content') { should match(%r{hab[\\/]pkgs[\\/]chef[\\/]chef-infra-client}i) }
    if expected_version
      its('content') do
        should match(
          %r{hab[\\/]pkgs[\\/]chef[\\/]chef-infra-client[\\/]#{Regexp.escape(expected_version)}[\\/]\d+[\\/]}i
        )
      end
    end
  end

  describe 'scheduled task and binlink shim agree on the chef-client version' do
    subject do
      command('schtasks /query /tn chef-client /xml').stdout.to_s.match?(
        %r{C:[\\/]hab[\\/]bin[\\/]chef-client\.bat}i
      ) && file('C:/hab/bin/chef-client.bat').content.to_s.match?(
        %r{chef-infra-client[\\/]#{Regexp.escape(expected_version.to_s)}[\\/]}i
      )
    end
    it { should be true }
  end if expected_version
end
