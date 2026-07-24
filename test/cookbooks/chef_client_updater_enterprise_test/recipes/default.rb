# frozen_string_literal: true
#
# Cookbook:: chef_client_updater_enterprise_test
# Recipe:: default
#
# Demonstrates canonical usage of all four chef_client_updater_enterprise resources.

# Step 1: Install chef-ice via native OS packages using mixlib-install.
# manage_binlinks: true will automatically create hab binlinks after install.
chef_client_updater_enterprise_install 'install chef-ice' do
  # license_key is read automatically from CHEF_LICENSE_KEY env var.
  # Explicitly pass it here if needed:
  license_key node['chef_client_updater_enterprise']['license_key']
end

# Step 2: Explicit binlinks step — ensures the chef-client binlink exists
# (/usr/bin on Linux, /usr/local/bin on macOS, C:\hab\bin on Windows).
# (Also called automatically by install when manage_binlinks: true)
chef_client_updater_enterprise_binlinks 'create hab binlinks'

# Step 3: Cleanup old Habitat versions, retaining the 2 most recent.
chef_client_updater_enterprise_cleanup 'trim old hab versions' do
  keep_versions 2
end

# Step 4: Remove legacy omnibus Chef installation if it exists on disk.
# Guard on both legacy directories before attempting removal.
chef_client_updater_enterprise_remove_omnibus 'purge legacy omnibus' do
  only_if { ::Dir.exist?('/opt/chef') || ::Dir.exist?('C:\opscode\chef') }
end
