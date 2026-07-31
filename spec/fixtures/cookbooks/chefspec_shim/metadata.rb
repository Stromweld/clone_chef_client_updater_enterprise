# frozen_string_literal: true
#
# Cookbook:: chefspec_shim
# Metadata
#
# Exists only so ChefSpec::SoloRunner has something to converge that pulls
# chef_client_updater_enterprise's resources/*.rb into cookbook_order (see
# spec/spec_helper.rb's `converge_resource`). Never used outside spec/unit.

name 'chefspec_shim'
version '0.1.0'
depends 'chef_client_updater_enterprise'
