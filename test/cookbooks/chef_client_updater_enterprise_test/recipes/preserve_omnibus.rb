# frozen_string_literal: true
#
# Cookbook:: chef_client_updater_enterprise_test
# Recipe:: preserve_omnibus
#
# Installs chef-ice with binlinks but does NOT remove the omnibus Chef install.

chef_client_updater_enterprise_install 'install chef-ice' do
  license_key node['chef_client_updater_enterprise']['license_key']
end
