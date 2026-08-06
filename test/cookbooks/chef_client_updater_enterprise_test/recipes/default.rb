# frozen_string_literal: true
#
# Cookbook:: chef_client_updater_enterprise_test
# Recipe:: default
#
# Demonstrates canonical usage of the install, binlinks and cleanup resources.
#
# chef_client_updater_enterprise_remove_omnibus is deliberately NOT exercised here — it
# defers its deletion whenever the converging chef-client is itself running out of the
# legacy omnibus install, so it can never finish in a single converge and would force
# every `default` converge to need a second chef-client pass. The `remove_omnibus` named
# run list and its own Kitchen suite (which carries the `post_converge` hook that
# provides that second pass) own that coverage.

# Step 1: Install chef-ice via native OS packages using the Commercial Download API.
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
