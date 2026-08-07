# frozen_string_literal: true
#
# Cookbook:: chef_client_updater_enterprise_test
# Recipe:: scheduler_fix
#
# Exercises chef_client_updater_enterprise_install's scheduler resource
# reconvergence: it fires on EVERY successful install/upgrade (not just the
# initial omnibus migration). Declares the platform's chef-client scheduler
# resource(s) with NO explicit chef_binary_path — its own built-in lazy
# default is re-evaluated fresh every time it's read. Deliberately declared
# BEFORE chef_client_updater_enterprise_install in this recipe to prove that
# declaration order doesn't matter: the resource is found via the resource
# collection (fully compiled before convergence begins) and its action is
# re-run once chef-ice is installed/binlinked, so chef_binary_path resolves
# to the new Habitat-based binary on its second evaluation — with no changes
# needed to chef_binary_path itself.

if platform_family?('rhel', 'amazon', 'suse', 'fedora', 'debian')
  chef_client_cron 'chef-client'

  chef_client_systemd_timer 'chef-client'
elsif platform?('mac_os_x')
  chef_client_launchd 'chef-client'
elsif windows?
  # `start_time` and `start_date` MUST both be pinned. chef_client_scheduled_task
  # leaves them nil by default, and Chef::Provider::WindowsTask#set_start_day_and_time
  # then fills them in with Time.now on every converge. Its own
  # start_time_updated?/start_day_updated? comparisons therefore see a difference
  # as soon as the clock crosses a minute (or midnight) boundary, so windows_task
  # reports "task updated" forever and the suite can never pass an idempotency check.
  chef_client_scheduled_task 'chef-client' do
    start_time '00:00'
    start_date '01/01/2026'
  end
end

chef_client_updater_enterprise_install 'install chef-ice' do
  license_key node['chef_client_updater_enterprise']['license_key']
end
