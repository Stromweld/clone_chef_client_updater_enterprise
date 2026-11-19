# frozen_string_literal: true
#
# Cookbook:: chef_client_updater_enterprise_test
# Recipe:: multi_version
#
# Tests version-pinned upgrade scenario:
#   1. Install a pinned version, no binlinks, no scheduler reconvergence
#   2. Install whatever the channel currently resolves to as latest
#   3. Binlink to the newest version present on disk
#   4. Cleanup, keeping only that newest version
#
# TODO: only one chef-ice release newer than 19.4.50 (the cookbook's floor)
# exists today: 19.4.56 on 'current'. Steps 1 and 2 therefore resolve to the same
# version and this suite does not yet exercise two coexisting versions. Pin step 1
# to an older qualifying release once a second one ships.
#
# NOTE: step 2 makes the end state depend on the channel, so it is NOT pinned in
# the verifier. test/integration/multi-version/default_test.rb queries the
# Commercial Download API's /versions/latest endpoint for whatever `latest`
# resolves to at verify time. Do not reintroduce a hardcoded
# `expected_chef_ice_version` input for this suite.
pinned_chef_ice_version = '19.4.56'

chef_client_updater_enterprise_install "install chef-ice #{pinned_chef_ice_version}" do
  version pinned_chef_ice_version
  manage_binlinks false
  update_scheduler_resources false
  license_key node['chef_client_updater_enterprise']['license_key']
  channel node['chef_client_updater_enterprise']['channel']
end

chef_client_updater_enterprise_install 'install latest' do
  license_key node['chef_client_updater_enterprise']['license_key']
  channel node['chef_client_updater_enterprise']['channel']
end

# Binlink to the newest version installed above
chef_client_updater_enterprise_binlinks 'binlink chef-ice'

# Cleanup, keep only the most recent version
chef_client_updater_enterprise_cleanup 'keep latest version'
