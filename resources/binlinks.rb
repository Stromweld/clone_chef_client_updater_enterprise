# frozen_string_literal: true
#
# Cookbook:: chef_client_updater_enterprise
# Resource:: binlinks
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

resource_name :chef_client_updater_enterprise_binlinks
provides :chef_client_updater_enterprise_binlinks

use 'pkg_names'

property :version, String,
         description: 'Specific chef-ice version to binlink (e.g. 19.0.28). Defaults to newest installed.'

property :force, [true, false],
         default: true,
         description: 'Overwrite an existing symlink or file at the destination path.'

default_action :create

action_class do
  include ChefClientUpdaterEnterprise::Helpers

  def resolved_ident
    dirs = hab_pkg_dirs(new_resource.habitat_package)
    return if dirs.empty?

    if new_resource.version
      target_dir = dirs.select { |d| d.include?("/#{new_resource.version}/") }.last
      raise Chef::Exceptions::ValidationFailed,
            "chef_client_updater_enterprise_binlinks: Requested version '#{new_resource.version}' " \
            "not found in Habitat package store. Installed dirs: #{dirs.join(', ')}" unless target_dir
    else
      target_dir = dirs.last
    end

    root = hab_pkg_root(new_resource.habitat_package)
    rel = target_dir.delete_prefix("#{root}/")
    parts = rel.split('/')
    return unless parts.length >= 2

    "#{new_resource.habitat_package}/#{parts.first}/#{parts[1]}"
  end

  # Directory `hab pkg binlink` is told (via --dest) to create the symlink/shim in.
  # This MUST be passed explicitly to the `hab pkg binlink` command below: Habitat's
  # own default binlink destination is platform-specific and does not match this
  # cookbook's documented binlink locations (notably `/bin` on Linux, not `/usr/bin`).
  # Relying on hab's default would silently binlink to the wrong directory.
  def link_dir
    if windows?
      'C:\hab\bin'
    elsif platform?('mac_os_x')
      '/usr/local/bin'
    else
      '/usr/bin'
    end
  end

  def link_dest
    if windows?
      "#{link_dir}\\chef-client.bat"
    else
      "#{link_dir}/chef-client"
    end
  end

  # True when `dest` is already a symlink pointing into the resolved package's
  # install directory. Used to make the binlink `execute` resource idempotent —
  # `hab pkg binlink --force` itself only replaces a symlink when its target
  # differs, but Chef's `execute` resource has no idempotency detection of its
  # own and would otherwise report "changed" on every converge.
  def binlink_current?(dest, ident)
    return false unless ident
    return false unless ::File.symlink?(dest)

    ::File.readlink(dest).include?("/#{ident}/")
  rescue Errno::ENOENT
    false
  end
end

action :create do
  unless windows?
    dest = link_dest

    # Only remove a pre-existing stale destination when it is a *non-symlink* file
    # (e.g. an old omnibus binary at /usr/bin/chef-client). `hab pkg binlink --force`
    # already replaces a symlink whose target has changed on its own; force-deleting
    # a correct, up-to-date symlink here on every converge is what made this resource
    # non-idempotent.
    ruby_block "remove stale binlink #{dest}" do
      block do
        ::File.unlink(dest)
      end
      only_if do
        next false unless new_resource.force
        next false if ::File.directory?(dest)
        next false if ::File.symlink?(dest)
        next false unless ::File.exist?(dest)

        true
      end
    end

    execute 'hab pkg binlink chef-client' do
      command lazy {
        ident = resolved_ident
        raise Chef::Exceptions::ValidationFailed,
              'chef_client_updater_enterprise_binlinks: No installed Habitat package found.' unless ident

        "#{hab_binary} pkg binlink --force --dest #{link_dir} #{ident} chef-client"
      }
      environment hab_env
      not_if { hab_pkg_dirs(new_resource.habitat_package).empty? }
      not_if { binlink_current?(dest, resolved_ident) }
    end
  end

  if windows?
    directory 'C:\hab\bin' do
      action :create
    end

    execute 'hab pkg binlink chef-client windows' do
      command lazy {
        ident = resolved_ident
        raise Chef::Exceptions::ValidationFailed,
              'chef_client_updater_enterprise_binlinks: No installed Habitat package found.' unless ident

        "#{hab_binary} pkg binlink --force #{ident} chef-client"
      }
      environment hab_env
      not_if { hab_pkg_dirs(new_resource.habitat_package).empty? }
    end

    windows_path 'C:\hab\bin' do
      action :add
    end
  end
end

action :remove do
  Chef::Log.warn(
    'chef_client_updater_enterprise_binlinks :remove — ' \
    'Symlink removal is not implemented. ' \
    'Manually remove the symlink at /usr/bin/chef-client (Linux), ' \
    '/usr/local/bin/chef-client (macOS), or C:\\hab\\bin\\chef-client.bat (Windows).'
  )
end
