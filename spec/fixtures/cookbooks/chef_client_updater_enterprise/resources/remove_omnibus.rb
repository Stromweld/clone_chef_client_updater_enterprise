# frozen_string_literal: true
#
# Cookbook:: chef_client_updater_enterprise
# Resource:: remove_omnibus
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

resource_name :chef_client_updater_enterprise_remove_omnibus
provides :chef_client_updater_enterprise_remove_omnibus

use 'partials'

property :legacy_omnibus_package, String,
         description: 'Legacy omnibus package name to purge.',
         default: 'chef'

property :remove_directories, [true, false],
         default: true,
         description: 'Remove legacy omnibus installation directories after package uninstall.'

default_action :remove

action_class do
  include ChefClientUpdaterEnterprise::Helpers

  # windows_package/RegistryUninstallEntry only matches an exact DisplayName, and the
  # legacy version installed varies per-box, so discover it via Get-Package's wildcard
  # support first rather than hardcoding a version string.
  def legacy_omnibus_display_name
    name = shell_out(
      'powershell.exe', '-NoProfile', '-NonInteractive', '-Command',
      "(Get-Package -Name 'Chef Infra Client*' -ErrorAction SilentlyContinue | " \
      "Where-Object { $_.Name -notlike '*chef-ice*' -and $_.Name -notlike '*air-gapped*' } | " \
      'Select-Object -First 1 -ExpandProperty Name)'
    ).stdout.to_s.strip
    name.empty? ? nil : name
  end
end

action :remove do
  if running_under_omnibus?
    Chef::Log.warn(
      'chef_client_updater_enterprise_remove_omnibus: Currently running under legacy omnibus Chef. ' \
      'Deferring omnibus removal to a subsequent converge under chef-ice.'
    )
    return
  end

  unless hab_pkg_dirs(new_resource.habitat_package).any?
    Chef::Log.warn(
      'chef_client_updater_enterprise_remove_omnibus: chef-ice Habitat package not yet installed. ' \
      'Deferring removal until chef-ice is present.'
    )
    return
  end

  if windows?
    display_name = legacy_omnibus_display_name

    if display_name
      windows_package display_name do
        action :remove
      end
    else
      Chef::Log.info(
        'chef_client_updater_enterprise_remove_omnibus: no legacy omnibus Chef Infra Client ' \
        'package found to remove.'
      )
    end
  elsif linux?
    package new_resource.legacy_omnibus_package do
      action :remove
      ignore_failure true
    end
  elsif platform?('mac_os_x')
    # Forget pkg receipts on macOS so future installs don't collide
    execute 'pkgutil --forget com.chef.chef' do
      only_if { shell_out('pkgutil --pkg-info com.chef.chef').exitstatus.zero? }
    end
  end

  return unless new_resource.remove_directories

  omnibus_dir = windows? ? 'C:\\opscode\\chef' : '/opt/chef'

  directory omnibus_dir do
    recursive true
    action :delete
    only_if { ::Dir.exist?(omnibus_dir) }
  end
end
