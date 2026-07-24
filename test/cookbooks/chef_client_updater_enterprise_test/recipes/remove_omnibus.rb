# frozen_string_literal: true
#
# Cookbook:: chef_client_updater_enterprise_test
# Recipe:: remove_omnibus
#
# Installs chef-ice, creates binlinks, then removes the legacy omnibus Chef install.

chef_client_updater_enterprise_install 'install chef-ice' do
  license_key node['chef_client_updater_enterprise']['license_key']
end

chef_client_updater_enterprise_remove_omnibus 'purge legacy omnibus'

chef_client_updater_enterprise_binlinks 'restore binlinks after omnibus removal'
