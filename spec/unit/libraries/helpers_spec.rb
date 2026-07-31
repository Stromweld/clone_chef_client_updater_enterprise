# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../libraries/helpers'

# Minimal double exposing the platform-introspection DSL methods Helpers relies on
# (windows?/platform?/platform_family?) without requiring a full Chef run context.
class HelpersTestHost
  include ChefClientUpdaterEnterprise::Helpers

  attr_accessor :fake_windows, :fake_platform, :fake_platform_family

  def initialize
    @fake_windows = false
    @fake_platform = nil
    @fake_platform_family = []
  end

  def windows?
    @fake_windows
  end

  def platform?(*names)
    names.include?(@fake_platform)
  end

  def platform_family?(*families)
    (families & @fake_platform_family).any?
  end
end

describe ChefClientUpdaterEnterprise::Helpers do
  subject(:host) { HelpersTestHost.new }

  describe '#hab_pkg_root' do
    it 'returns the Windows path when windows?' do
      host.fake_windows = true
      expect(host.hab_pkg_root('chef/chef-infra-client')).to eq('C:/hab/pkgs/chef/chef-infra-client')
    end

    it 'returns the macOS path when platform is mac_os_x' do
      host.fake_platform = 'mac_os_x'
      expect(host.hab_pkg_root('chef/chef-infra-client')).to eq('/opt/hab/pkgs/chef/chef-infra-client')
    end

    it 'returns the Linux path otherwise' do
      expect(host.hab_pkg_root('chef/chef-infra-client')).to eq('/hab/pkgs/chef/chef-infra-client')
    end
  end

  describe '#chef_client_binlink_dir and #chef_client_binlink_path' do
    it 'uses C:\\hab\\bin and a .bat shim on Windows' do
      host.fake_windows = true
      expect(host.chef_client_binlink_dir).to eq('C:\hab\bin')
      expect(host.chef_client_binlink_path).to eq('C:\hab\bin\chef-client.bat')
    end

    it 'uses /usr/local/bin on macOS' do
      host.fake_platform = 'mac_os_x'
      expect(host.chef_client_binlink_dir).to eq('/usr/local/bin')
      expect(host.chef_client_binlink_path).to eq('/usr/local/bin/chef-client')
    end

    it 'uses /usr/bin on Linux' do
      expect(host.chef_client_binlink_dir).to eq('/usr/bin')
      expect(host.chef_client_binlink_path).to eq('/usr/bin/chef-client')
    end
  end

  describe '#hab_pkg_dirs' do
    it 'returns an empty array when the package root does not exist' do
      allow(::File).to receive(:directory?).with('/hab/pkgs/chef/chef-infra-client').and_return(false)
      expect(host.hab_pkg_dirs('chef/chef-infra-client')).to eq([])
    end

    it 'sorts installed version/release directories oldest-first by basename' do
      root = '/hab/pkgs/chef/chef-infra-client'
      allow(::File).to receive(:directory?).and_call_original
      allow(::File).to receive(:directory?).with(root).and_return(true)
      unsorted = ["#{root}/19.3.15/20260601120000", "#{root}/19.2.12/20260101090000"]
      allow(::Dir).to receive(:glob).with("#{root}/*/*").and_return(unsorted)
      allow(::File).to receive(:directory?).with(unsorted[0]).and_return(true)
      allow(::File).to receive(:directory?).with(unsorted[1]).and_return(true)

      expect(host.hab_pkg_dirs('chef/chef-infra-client')).to eq(
        ["#{root}/19.2.12/20260101090000", "#{root}/19.3.15/20260601120000"]
      )
    end
  end

  describe '#current_installed_version' do
    it 'prefers the Habitat version when hab reports one' do
      allow(host).to receive(:current_hab_version).with('chef/chef-infra-client').and_return('19.3.15')
      expect(host.current_installed_version('chef-ice', 'chef/chef-infra-client')).to eq('19.3.15')
    end

    it 'falls back to the filesystem glob when hab itself is unavailable' do
      allow(host).to receive(:current_hab_version).with('chef/chef-infra-client').and_return(nil)
      allow(host).to receive(:hab_pkg_dirs).with('chef/chef-infra-client')
                                            .and_return(['/hab/pkgs/chef/chef-infra-client/19.3.15/20260601120000'])
      expect(host.current_installed_version('chef-ice', 'chef/chef-infra-client')).to eq('19.3.15')
    end

    it 'falls back to the native package query when neither hab nor the filesystem has an answer' do
      allow(host).to receive(:current_hab_version).with('chef/chef-infra-client').and_return(nil)
      allow(host).to receive(:hab_pkg_dirs).with('chef/chef-infra-client').and_return([])
      allow(host).to receive(:current_native_version).with('chef-ice').and_return('19.1.0')
      expect(host.current_installed_version('chef-ice', 'chef/chef-infra-client')).to eq('19.1.0')
    end
  end

  describe '#running_under_omnibus? / #running_under_hab? / #running_hab_ident' do
    it 'recognizes a Linux omnibus install' do
      allow(host).to receive(:running_chef_root).and_return('/opt/chef')
      expect(host.running_under_omnibus?).to be true
      expect(host.running_under_hab?).to be false
      expect(host.running_hab_ident).to be_nil
    end

    it 'recognizes a Windows omnibus install regardless of slash direction' do
      host.fake_windows = true
      allow(host).to receive(:running_chef_root).and_return('C:\opscode\chef')
      expect(host.running_under_omnibus?).to be true
    end

    it 'recognizes a Habitat install and extracts the running ident' do
      allow(host).to receive(:running_chef_root)
        .and_return('/hab/pkgs/chef/chef-infra-client/19.3.15/20260601120000')
      expect(host.running_under_hab?).to be true
      expect(host.running_under_omnibus?).to be false
      expect(host.running_hab_ident).to eq('chef/chef-infra-client/19.3.15/20260601120000')
    end
  end
end
