# frozen_string_literal: true
# Policyfile.rb - Describe how you want Chef Infra Client to build your system.
#
# For more information on the Policyfile feature, visit
# https://docs.chef.io/policyfile/

name 'chef_client_updater_enterprise'

default_source :supermarket

run_list 'chef_client_updater_enterprise_test::default'

cookbook 'chef_client_updater_enterprise', path: '.'
cookbook 'chef_client_updater_enterprise_test', path: 'test/cookbooks/chef_client_updater_enterprise_test'

named_run_list :preserve_omnibus, 'recipe[chef_client_updater_enterprise_test::preserve_omnibus]'
named_run_list :remove_omnibus,   'recipe[chef_client_updater_enterprise_test::remove_omnibus]'
named_run_list :multi_version,    'recipe[chef_client_updater_enterprise_test::multi_version]'
