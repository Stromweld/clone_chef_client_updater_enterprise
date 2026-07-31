# frozen_string_literal: true
#
# InSpec Integration Test:: scheduler-fix
#
# Verifies chef_client_updater_enterprise_install's scheduler resource reconvergence
# (fires on every version change, not just the initial omnibus migration) keeps the
# built-in chef_client_cron/chef_client_systemd_timer/chef_client_launchd/
# chef_client_scheduled_task resources' chef_binary_path correct: after chef-ice is
# installed/binlinked, each resource's chef_binary_path is explicitly set to the stable
# binlink path and its action is re-run, all within the same converge — no second
# chef-client run or exit-code convention required. The stable binlink path (not a fully
# resolved versioned path) is used deliberately so future upgrades need only update the
# binlink target, not every scheduler resource again.

title 'scheduler-fix verification'

expected_version = input('expected_chef_ice_version', value: '19.3.15')

describe command('chef-client --version') do
  its('exit_status') { should eq 0 }
  its('stdout') { should match(/Chef Infra Client/) }
  its('stdout') { should include(expected_version) }
end

if os.linux?
  chef_client_binlink = '/usr/bin/chef-client'

  describe file('/etc/cron.d/chef-client') do
    it { should exist }
    its('content') { should match(/#{Regexp.escape(chef_client_binlink)}/) }
    its('content') { should_not match(%r{/opt/chef/}) }
  end

  describe file('/etc/systemd/system/chef-client.service') do
    it { should exist }
    its('content') { should match(/#{Regexp.escape(chef_client_binlink)}/) }
    its('content') { should_not match(%r{/opt/chef/}) }
  end

  # The stable binlink itself (not the cron/systemd file content) must resolve to the
  # newly installed version, since chef_binary_path deliberately points at this stable,
  # version-independent path rather than a fully resolved versioned path.
  describe command("readlink -f #{chef_client_binlink}") do
    its('exit_status') { should eq 0 }
    its('stdout') { should match(/#{Regexp.escape(expected_version)}/) }
  end
end

if os.windows?
  windows_task_xml = command('schtasks /query /tn chef-client /xml').stdout
  stable_shim_regex = /C:\\hab\\bin\\chef-client\.bat/i
  versioned_path_regex = /C:\\hab\\pkgs\\chef\\chef-infra-client\\[\d.]+\\[0-9a-f]+\\bin\\chef-client\.bat/i

  describe command('schtasks /query /tn chef-client /xml') do
    its('exit_status') { should eq 0 }
    its('stdout') { should_not match(/opscode\\chef/i) }
  end

  describe 'chef_client_scheduled_task command path' do
    it 'points at the stable hab binlink or a versioned hab pkgs chef-client.bat, whichever chef_client_scheduled_task configured' do
      expect(windows_task_xml).to match(Regexp.union(stable_shim_regex, versioned_path_regex))
    end
  end

  # If the task points at the stable shim, that file's own content must reference the
  # correct version — the shim path alone doesn't prove it wasn't left stale internally.
  if windows_task_xml.match?(stable_shim_regex)
    describe command('type C:\hab\bin\chef-client.bat') do
      its('exit_status') { should eq 0 }
      its('stdout') { should match(/#{Regexp.escape(expected_version)}/) }
    end
  end
end
