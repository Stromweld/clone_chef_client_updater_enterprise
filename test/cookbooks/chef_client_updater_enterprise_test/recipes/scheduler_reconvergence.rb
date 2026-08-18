# frozen_string_literal: true
#
# Cookbook:: chef_client_updater_enterprise_test
# Recipe:: scheduler_reconvergence
#
# Exercises chef_client_updater_enterprise_scheduler_reconvergence declared and run
# DIRECTLY and standalone — the usage documented in
# documentation/resources/scheduler_reconvergence.md's "Examples" section — rather
# than via chef_client_updater_enterprise_install's automatic notification wiring
# (see the scheduler_fix recipe/suite for that path).
#
# update_scheduler_resources is explicitly disabled on the install below so this
# converge exercises ONLY the explicit resource declaration below it, proving the
# resource can be declared and re-run independently of :install as the
# documentation promises.
#
# Same scheduler resource declarations as scheduler_fix.rb, and for the same
# reasons: declared with no explicit chef_binary_path so its own lazy default is
# re-evaluated when reconverge_scheduler_resources re-runs its action, and
# Windows' start_time/start_date are pinned so windows_task's own
# start_time_updated?/start_day_updated? checks don't report "task updated" on
# every converge purely from Time.now drifting across a minute/midnight boundary.

if platform_family?('rhel', 'amazon', 'suse', 'fedora', 'debian')
  chef_client_cron 'chef-client'

  chef_client_systemd_timer 'chef-client'
elsif platform?('mac_os_x')
  chef_client_launchd 'chef-client'
elsif windows?
  chef_client_scheduled_task 'chef-client' do
    start_time '00:00'
    start_date '01/01/2026'
  end
end

chef_client_updater_enterprise_install 'install chef-ice' do
  license_key node['chef_client_updater_enterprise']['license_key']
  update_scheduler_resources false
end

chef_client_updater_enterprise_scheduler_reconvergence 'default'
