# frozen_string_literal: true
#
# Cookbook:: chef_client_updater_enterprise_test
# Recipe:: multi_version
#
# Tests version-pinned upgrade scenario:
#   1. Install older version with no binlinks
#   2. Install newer version (19.3.15) — upgrade
#   3. Binlink to newest installed version
#   4. Cleanup keeping only 1 version
#
# The "older" starting version differs by platform: chef-ice's Windows MSI
# only gained CHEF_PRESERVE_OMNIBUS support in builds after ~2026-04-23
# (see resources/install.rb's windows? branch for details). 19.2.12 predates
# that fix and would always destructively migrate on Windows, so Windows uses
# 19.3.14 (first version confirmed to support it) as its starting point.
# RHEL/SUSE/Ubuntu keep 19.2.12, already validated against the rpm/deb fixes.
older_chef_ice_version = windows? ? '19.3.14' : '19.2.12'

# Install older version first
chef_client_updater_enterprise_install "install chef-ice #{older_chef_ice_version}" do
  version older_chef_ice_version
  manage_binlinks false
  update_scheduler_resources false
  license_key node['chef_client_updater_enterprise']['license_key']
end

# Install newer version
chef_client_updater_enterprise_install 'install chef-ice 19.3.15' do
  version '19.3.15'
  manage_binlinks false
  update_scheduler_resources false
  license_key node['chef_client_updater_enterprise']['license_key']
end

# Install latest version
chef_client_updater_enterprise_install 'install latest' do
  license_key node['chef_client_updater_enterprise']['license_key']
end

# Binlink to newest installed version (auto-detects 19.3.15)
chef_client_updater_enterprise_binlinks 'binlink chef-ice'

# Cleanup, keep only the most recent version
chef_client_updater_enterprise_cleanup 'keep latest version'
