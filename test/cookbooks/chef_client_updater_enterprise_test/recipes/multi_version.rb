# frozen_string_literal: true
#
# Cookbook:: chef_client_updater_enterprise_test
# Recipe:: multi_version
#
# Tests version-pinned upgrade scenario:
#   1. Install older version (19.2.12) with no binlinks
#   2. Install newer version (19.3.15) — upgrade
#   3. Binlink to newest installed version
#   4. Cleanup keeping only 1 version

# Install older version first
chef_client_updater_enterprise_install 'install chef-ice 19.2.12' do
  version '19.2.12'
  manage_binlinks false
  handoff false
  license_key node['chef_client_updater_enterprise']['license_key']
end

# Install newer version
chef_client_updater_enterprise_install 'install chef-ice 19.3.15' do
  version '19.3.15'
  manage_binlinks false
  handoff false
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
