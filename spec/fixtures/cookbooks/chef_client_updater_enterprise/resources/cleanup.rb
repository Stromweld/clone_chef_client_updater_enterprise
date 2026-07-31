# frozen_string_literal: true
#
# Cookbook:: chef_client_updater_enterprise
# Resource:: cleanup
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

resource_name :chef_client_updater_enterprise_cleanup
provides :chef_client_updater_enterprise_cleanup

use 'partials'

property :keep_versions, Integer,
         default: 1,
         description: 'Number of most recently installed Habitat versions to retain.'

default_action :cleanup

action_class do
  include ChefClientUpdaterEnterprise::Helpers

  # Returns installed Habitat idents as 'origin/name/version/release' strings,
  # sorted oldest-first. Uses filesystem glob — no hab CLI dependency.
  def installed_idents
    root = hab_pkg_root(new_resource.habitat_package)
    dirs = hab_pkg_dirs(new_resource.habitat_package)
    return [] if dirs.empty?

    dirs.map do |dir|
      # dir = /hab/pkgs/chef/chef-infra-client/VERSION/RELEASE
      # Strip root prefix to get version/release
      rel = dir.delete_prefix("#{root}/")
      parts = rel.split('/')
      next unless parts.length >= 2

      "#{new_resource.habitat_package}/#{parts.first}/#{parts[1]}"
    end.compact
  end
end

action :cleanup do
  idents = installed_idents

  if idents.length <= new_resource.keep_versions
    Chef::Log.debug(
      "chef_client_updater_enterprise_cleanup: #{idents.length} version(s) installed, " \
      "keeping #{new_resource.keep_versions}. Nothing to remove."
    )
    return
  end

  # Keep the last N (most recent), remove the rest (oldest first)
  to_remove = idents[0..-(new_resource.keep_versions + 1)]

  # Never remove the Habitat package backing the currently running Chef process
  current_ident = running_hab_ident
  if current_ident && to_remove.include?(current_ident)
    to_remove.delete(current_ident)
    Chef::Log.warn(
      "chef_client_updater_enterprise_cleanup: Excluding currently running ident #{current_ident} from removal."
    )
  end

  to_remove.each do |ident|
    _origin, _name, version, release = ident.split('/', 4)

    unless version && release
      Chef::Log.warn(
        "chef_client_updater_enterprise_cleanup: Skipping malformed Habitat ident #{ident.inspect}"
      )
      next
    end

    habitat_package new_resource.habitat_package do
      version version
      action :remove
    end
  end
end
