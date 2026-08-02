# frozen_string_literal: true
#
# InSpec Integration Test:: scheduler-fix
#
# Verifies chef_client_updater_enterprise_install's scheduler resource reconvergence
# (fires on every version change, not just the initial omnibus migration) keeps the
# built-in chef_client_cron/chef_client_systemd_timer/chef_client_launchd/
# chef_client_scheduled_task resources' chef_binary_path correct: after chef-ice is
# installed/binlinked, each resource's chef_binary_path is explicitly set to the
# resolved, fully-versioned Habitat path (chef_client_hab_binary_path) and its action
# is re-run, all within the same converge — no second chef-client run or exit-code
# convention required.
#
# The fully-versioned path (not the stable /usr/bin/chef-client binlink symlink) is
# used deliberately: pointing a root-run scheduled job at a mutable, well-known-path
# symlink is a standing local privilege-escalation risk (anyone able to repoint/replace
# the symlink between scheduled runs gets arbitrary root code execution on the next
# invocation, with no chef-client convergence needed). See AGENTS.md's "Scheduler
# Resource Reconvergence" section for the full rationale, including why this doesn't
# reintroduce a staleness risk against chef_client_updater_enterprise_cleanup.

title 'scheduler-fix verification'

expected_version = input('expected_chef_ice_version', value: '19.3.15')

describe command('chef-client --version') do
  its('exit_status') { should eq 0 }
  its('stdout') { should match(/Chef Infra Client/) }
  its('stdout') { should include(expected_version) }
end

if os.linux?
  # e.g. /hab/pkgs/chef/chef-infra-client/19.3.15/20260601120000/bin/chef-client
  versioned_path_regex = %r{/hab/pkgs/chef/chef-infra-client/#{Regexp.escape(expected_version)}/\d+/bin/chef-client}

  describe file('/etc/cron.d/chef-client') do
    it { should exist }
    its('content') { should match(versioned_path_regex) }
    its('content') { should_not match(%r{/opt/chef/}) }
    its('content') { should_not match(%r{/usr/bin/chef-client}) }
  end

  describe file('/etc/systemd/system/chef-client.service') do
    it { should exist }
    its('content') { should match(versioned_path_regex) }
    its('content') { should_not match(%r{/opt/chef/}) }
    its('content') { should_not match(%r{/usr/bin/chef-client}) }
  end
end

if os.windows?
  versioned_path_regex = /C:\\hab\\pkgs\\chef\\chef-infra-client\\#{Regexp.escape(expected_version)}\\[0-9a-f]+\\bin\\chef-client\.bat/i

  describe command('schtasks /query /tn chef-client /xml') do
    its('exit_status') { should eq 0 }
    its('stdout') { should_not match(/opscode\\chef/i) }
    its('stdout') { should match(versioned_path_regex) }
  end
end
