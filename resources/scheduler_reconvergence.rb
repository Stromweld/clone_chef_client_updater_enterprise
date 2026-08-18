# frozen_string_literal: true
#
# Cookbook:: chef_client_updater_enterprise
# Resource:: scheduler_reconvergence
#
# Copyright:: 2026, Corey Hemminger
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

unified_mode true

resource_name :chef_client_updater_enterprise_scheduler_reconvergence
provides :chef_client_updater_enterprise_scheduler_reconvergence

use 'partials'

default_action :reconverge

action_class do
  include ChefClientUpdaterEnterprise::Helpers

  # chef_client_cron/launchd/systemd_timer/scheduled_task's chef_binary_path default varies by
  # Chef Infra Client version: newer releases (e.g. what chef-ice itself ships) default it to a
  # lazy, hab-aware `chef_client_hab_binary_path` block.
  #
  # Idempotent: a resource whose chef_binary_path already equals resolved_binary_path is left
  # untouched entirely — neither the property nor its action(s) are re-run — so a steady-state
  # converge (this resource fired but nothing actually changed) reports zero updated resources,
  # same as every other resource in this cookbook.
  def reconverge_scheduler_resources(resource_collection, resolved_binary_path)
    scheduler_types = %i(chef_client_scheduled_task chef_client_cron chef_client_launchd chef_client_systemd_timer)
    found = resource_collection.all_resources.select { |r| scheduler_types.include?(r.resource_name) }

    if found.empty?
      Chef::Log.debug('chef_client_updater_enterprise: no chef-client scheduler resources found to reconverge.')
      return
    end

    found.each do |resource|
      next unless resource.respond_to?(:chef_binary_path)
      next if resource.chef_binary_path == resolved_binary_path

      Chef::Log.info("chef_client_updater_enterprise: reconverging #{resource} for the newly installed binary at #{resolved_binary_path}.")
      resource.chef_binary_path(resolved_binary_path)
      resource.action.each { |a| resource.run_action(a) }
      new_resource.updated_by_last_action(true)
    end
  end
end

action :reconverge do
  resolved_binary_path = chef_client_hab_binary_path(new_resource.habitat_package, new_resource.version)

  if resolved_binary_path.nil?
    Chef::Log.warn(
      'chef_client_updater_enterprise: chef_client_updater_enterprise_scheduler_reconvergence ran but no ' \
      "installed #{new_resource.habitat_package} Habitat package was found to resolve a chef_binary_path from."
    )
    return
  end

  return unless ::File.exist?(resolved_binary_path)

  resource_collection = run_context.root_run_context.resource_collection
  reconverge_scheduler_resources(resource_collection, resolved_binary_path)
end
