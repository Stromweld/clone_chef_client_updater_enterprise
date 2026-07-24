# frozen_string_literal: true
#
# Cookbook:: chef_client_updater_enterprise
# Resource:: install
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

resource_name :chef_client_updater_enterprise_install
provides :chef_client_updater_enterprise_install

use 'license'
use 'version_channel'
use 'pkg_names'

property :download_dir, String,
         default: lazy { Chef::Config[:file_cache_path] },
         description: 'Directory to stage downloaded packages before install.'
property :download_url, String,
         description: 'Direct package URL bypassing mixlib-install. Use for airgapped environments or local file servers.'

property :checksum, String,
         description: 'SHA256 checksum for the direct download_url package.'

property :manage_binlinks, [true, false],
         default: true,
         description: 'Automatically run the binlinks resource after a successful install.'

property :handoff, [true, false],
         default: true,
         description: 'Re-exec chef-client via binlink after install when the package changes. ' \
                      'Requires manage_binlinks true (or externally managed binlinks). ' \
                      'Set false if the scheduler already points at the binlink path.'

property :preserve_omnibus, [true, false],
         default: true,
         description: 'Pass --preserve-omnibus true to migrate-ice to keep the existing omnibus Chef installation.'

default_action :install

action_class do
  include ChefClientUpdaterEnterprise::Helpers

  # Ensure mixlib-install gem is loaded at compile time.
  def install_mixlib_install_gem
    gem_cache_path = ::File.join(Chef::Config[:file_cache_path], 'mixlib-install.gem')

    cookbook_file gem_cache_path do
      source 'mixlib-install.gem'
      cookbook 'chef_client_updater_enterprise'
      action :nothing
    end.run_action(:create)

    chef_gem 'mixlib-install' do
      source gem_cache_path
      clear_sources true
      compile_time true
      action :install
    end
  end

  def validate_license!
    if new_resource.license_key.nil? || new_resource.license_key.to_s.strip.empty?
      raise Chef::Exceptions::ConfigurationError,
            'chef_client_updater_enterprise_install: license_key is required. ' \
            "Set the CHEF_LICENSE_KEY environment variable or pass `license_key 'YOUR_KEY'` " \
            'to the resource. A valid license key is required to download chef-ice packages.'
    end
  end

  def artifact_info
    require 'mixlib/install'

    product_version = new_resource.version == 'latest' ? :latest : new_resource.version

    options = {
      product_name: new_resource.product_name,
      product_version: product_version,
      channel: new_resource.channel,
      license_id: new_resource.license_key,
      platform_detection_options: {
        platform: node['platform'],
        platform_version: node['platform_version'],
        machine: node['kernel']['machine'] == 'arm64' ? 'aarch64' : node['kernel']['machine'],
      },
    }

    result = Mixlib::Install.new(options).artifact_info

    return result unless result.is_a?(Array)

    arch = node['kernel']['machine']
    target_platform = windows? ? 'windows' : 'linux'
    matched = result.select { |a| a.platform == target_platform && a.architecture == arch }
    matched = result.select { |a| a.platform == target_platform } if matched.empty?

    candidates = result.map { |a| "#{a.platform}/#{a.architecture}/#{a.version}" }.join(', ')
    raise "No matching artifact for #{target_platform}/#{arch}; candidates: #{candidates}" if matched.empty?

    matched.first
  end

  def package_extension(_url)
    if windows?
      'msi'
    elsif platform_family?('rhel', 'amazon', 'suse', 'fedora')
      'rpm'
    elsif platform_family?('debian')
      'deb'
    elsif platform_family?('mac_os_x')
      'dmg'
    else
      raise "Unsupported platform family '#{node['platform_family']}' for chef-ice package install"
    end
  end

  def direct_artifact_url?(url)
    path = URI.parse(url).path
    %w(.rpm .deb .msi .dmg .pkg).any? { |ext| path.end_with?(ext) }
  rescue URI::InvalidURIError
    false
  end
end

action :install do
  unless new_resource.version == 'latest'
    installed = current_installed_version(new_resource.product_name, new_resource.habitat_package)
    if installed == new_resource.version
      Chef::Log.debug("chef_client_updater_enterprise_install: #{new_resource.product_name} #{new_resource.version} already installed, skipping.")
      return
    end
  end

  if new_resource.download_url
    # Direct download path — skip mixlib-install entirely
    pkg_url = new_resource.download_url
    pkg_ext = package_extension(pkg_url)
    safe_ver = new_resource.version == 'latest' ? 'custom' : new_resource.version
    pkg_path = ::File.join(new_resource.download_dir, "#{new_resource.product_name}-#{safe_ver}.#{pkg_ext}")
    file_checksum = new_resource.checksum
    # 'latest' has no known version when bypassing mixlib-install; the package
    # resource's own source-file inspection is the only idempotency signal available.
    pkg_version = new_resource.version == 'latest' ? nil : new_resource.version
  else
    # mixlib-install path
    validate_license!
    install_mixlib_install_gem

    artifact = artifact_info
    raise "No artifact found for #{new_resource.product_name} #{new_resource.version}" if artifact.nil?

    pkg_url = artifact.url
    pkg_ext = package_extension(pkg_url)
    pkg_path = ::File.join(new_resource.download_dir, "#{new_resource.product_name}-#{artifact.version}.#{pkg_ext}")
    # Handler/redirect URLs (no file extension in path) return checksums that don't match the response body
    file_checksum = direct_artifact_url?(pkg_url) ? artifact.sha256 : nil
    pkg_version = artifact.version
  end

  remote_file pkg_path do
    source pkg_url
    checksum file_checksum if file_checksum
    sensitive true
    action :create
  end

  # NOTE: `version` must be set explicitly here. Without it, dnf/yum/apt providers
  # treat ANY currently-installed version of `product_name` as satisfying an
  # unconstrained install request and silently no-op, even when `source` points at
  # a newer package artifact on disk (e.g. chef-ice 19.3.14 installed, 19.3.15
  # downloaded — the package resource would report "already installed").
  package new_resource.product_name do
    source pkg_path
    version pkg_version if pkg_version
    installer_type :msi if windows?
    options '--setopt=obsoletes=0' if platform_family?('rhel', 'amazon', 'fedora')
  end

  # Run migrate-ice after package install to populate /hab/pkgs tree.
  # --process-config ignore skips the running-process check so kitchen converge
  # does not get blocked by the in-flight chef-client process.
  license = new_resource.license_key
  execute 'migrate-ice apply airgap' do
    command lazy {
      bundle = ::Dir.glob('/hab/migration/bundle/chef-ice-*.tar.gz').first
      preserve_flag = new_resource.preserve_omnibus ? ' --preserve-omnibus true' : ''
      "/hab/migration/bin/migrate-ice apply airgap #{bundle} --process-config ignore --license-key #{license}#{preserve_flag}"
    }
    environment lazy { { 'CHEF_LICENSE_KEY' => license.to_s } }
    sensitive true
    only_if { ::File.exist?('/hab/migration/bin/migrate-ice') }
    only_if { ::Dir.glob('/hab/migration/bundle/chef-ice-*.tar.gz').any? }
  end

  if new_resource.manage_binlinks
    chef_client_updater_enterprise_binlinks 'default' do
      habitat_package new_resource.habitat_package
      action :create
      notifies :run, 'ruby_block[handoff to new chef-ice binary]', :immediately
    end
  end

  # Capture all locals outside the block — no Chef DSL calls inside plain Ruby closures.
  handoff_bin = if windows?
                  'C:\\hab\\bin\\chef-client.bat'
                elsif platform?('mac_os_x')
                  '/usr/local/bin/chef-client'
                else
                  '/usr/bin/chef-client'
                end
  handoff_enabled = new_resource.handoff
  on_windows = windows?

  if new_resource.handoff && !new_resource.manage_binlinks
    Chef::Log.warn(
      'chef_client_updater_enterprise: handoff is true but manage_binlinks is false. ' \
      "Handoff assumes #{handoff_bin} is externally managed and current."
    )
  end

  ruby_block 'handoff to new chef-ice binary' do
    block do
      Chef::Log.warn('chef_client_updater_enterprise: Re-executing chef-client under newly installed binary...')
      if on_windows
        Chef::Application.exit!(213)
      else
        Kernel.exec(handoff_bin, *ARGV)
      end
    end
    only_if do
      handoff_enabled &&
        (on_windows || ::File.executable?(handoff_bin)) &&
        RbConfig.ruby.match?(%r{/(opt/chef|opt/opscode|opscode/chef)/})
    end
    action :nothing
  end
end
