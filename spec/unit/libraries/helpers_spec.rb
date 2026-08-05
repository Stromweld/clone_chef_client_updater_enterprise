# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../libraries/helpers'

# Minimal double exposing the platform-introspection DSL methods Helpers relies on
# (windows?/platform?/platform_family?) without requiring a full Chef run context.
class HelpersTestHost
  include ChefClientUpdaterEnterprise::Helpers

  attr_accessor :fake_windows, :fake_platform, :fake_platform_family, :fake_node

  def initialize
    @fake_windows = false
    @fake_platform = nil
    @fake_platform_family = []
    @fake_node = {}
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

  def node
    @fake_node
  end
end

describe ChefClientUpdaterEnterprise::Helpers do
  subject(:host) { HelpersTestHost.new }

  describe '#mixlib_install_platform_info' do
    def set_platform(host, platform:, platform_version:, platform_family: [])
      host.fake_node = { 'platform' => platform, 'platform_version' => platform_version }
      host.fake_platform = platform
      host.fake_platform_family = platform_family
    end

    it 'maps redhat to el + major version' do
      set_platform(host, platform: 'redhat', platform_version: '9.4', platform_family: %w(rhel fedora))
      expect(host.mixlib_install_platform_info).to eq(%w(el 9))
    end

    it 'maps centos to el + major version' do
      set_platform(host, platform: 'centos', platform_version: '7.9', platform_family: %w(rhel fedora))
      expect(host.mixlib_install_platform_info).to eq(%w(el 7))
    end

    it 'maps almalinux to el + major version' do
      set_platform(host, platform: 'almalinux', platform_version: '9.8', platform_family: %w(rhel fedora))
      expect(host.mixlib_install_platform_info).to eq(%w(el 9))
    end

    it 'maps oracle to el + major version' do
      set_platform(host, platform: 'oracle', platform_version: '9.8', platform_family: %w(rhel fedora))
      expect(host.mixlib_install_platform_info).to eq(%w(el 9))
    end

    it 'keeps rocky as its own platform key + major version (not folded into el)' do
      set_platform(host, platform: 'rocky', platform_version: '9.5', platform_family: %w(rhel fedora))
      expect(host.mixlib_install_platform_info).to eq(%w(rocky 9))
    end

    it 'keeps fedora as its own platform key + major version (not folded into el) — ' \
       'omnitruck-service recognizes "fedora" as a distinct, valid platform key' do
      set_platform(host, platform: 'fedora', platform_version: '44', platform_family: %w(rhel fedora))
      expect(host.mixlib_install_platform_info).to eq(%w(fedora 44))
    end

    it 'keeps amazon linux 2022/2023 as amazon + the full platform_version string' do
      set_platform(host, platform: 'amazon', platform_version: '2023', platform_family: %w(rhel fedora amazon))
      expect(host.mixlib_install_platform_info).to eq(%w(amazon 2023))
    end

    it 'maps amazon linux 2 to el/7' do
      set_platform(host, platform: 'amazon', platform_version: '2', platform_family: %w(rhel fedora amazon))
      expect(host.mixlib_install_platform_info).to eq(%w(el 7))
    end

    it 'maps generic SUSE (not opensuseleap) to sles + major version' do
      set_platform(host, platform: 'suse', platform_version: '15.5', platform_family: %w(suse))
      expect(host.mixlib_install_platform_info).to eq(%w(sles 15))
    end

    it 'keeps opensuseleap as its own platform key + major version' do
      set_platform(host, platform: 'opensuseleap', platform_version: '15.5', platform_family: %w(suse))
      expect(host.mixlib_install_platform_info).to eq(%w(opensuseleap 15))
    end

    it 'keeps debian as its own platform key + major version' do
      set_platform(host, platform: 'debian', platform_version: '12.7', platform_family: %w(debian))
      expect(host.mixlib_install_platform_info).to eq(%w(debian 12))
    end

    it 'passes ubuntu through with the full platform_version string' do
      set_platform(host, platform: 'ubuntu', platform_version: '24.04', platform_family: %w(debian))
      expect(host.mixlib_install_platform_info).to eq(%w(ubuntu 24.04))
    end
  end

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

  describe '#chef_client_hab_binary_path' do
    it 'returns nil when no version of the package is installed' do
      allow(host).to receive(:hab_pkg_dirs).with('chef/chef-infra-client').and_return([])
      expect(host.chef_client_hab_binary_path('chef/chef-infra-client')).to be_nil
    end

    it 'resolves to the newest installed version/release directory\'s bin/chef-client on Linux' do
      allow(host).to receive(:hab_pkg_dirs).with('chef/chef-infra-client').and_return(
        ['/hab/pkgs/chef/chef-infra-client/19.2.12/20260101090000',
         '/hab/pkgs/chef/chef-infra-client/19.3.15/20260601120000']
      )
      expect(host.chef_client_hab_binary_path('chef/chef-infra-client')).to eq(
        '/hab/pkgs/chef/chef-infra-client/19.3.15/20260601120000/bin/chef-client'
      )
    end

    it 'resolves to a .bat filename on Windows' do
      host.fake_windows = true
      allow(host).to receive(:hab_pkg_dirs).with('chef/chef-infra-client').and_return(
        ['C:/hab/pkgs/chef/chef-infra-client/19.3.15/20260601120000']
      )
      expect(host.chef_client_hab_binary_path('chef/chef-infra-client')).to eq(
        'C:/hab/pkgs/chef/chef-infra-client/19.3.15/20260601120000/bin/chef-client.bat'
      )
    end

    it 'resolves to the pinned older version\'s directory when multiple versions are installed ' \
       'and an explicit version is given, even though a newer one exists on disk' do
      allow(host).to receive(:hab_pkg_dirs).with('chef/chef-infra-client').and_return(
        ['/hab/pkgs/chef/chef-infra-client/19.2.12/20260101090000',
         '/hab/pkgs/chef/chef-infra-client/19.3.15/20260601120000']
      )
      expect(host.chef_client_hab_binary_path('chef/chef-infra-client', '19.2.12')).to eq(
        '/hab/pkgs/chef/chef-infra-client/19.2.12/20260101090000/bin/chef-client'
      )
    end

    it 'falls back to the newest installed version when version is \'latest\'' do
      allow(host).to receive(:hab_pkg_dirs).with('chef/chef-infra-client').and_return(
        ['/hab/pkgs/chef/chef-infra-client/19.2.12/20260101090000',
         '/hab/pkgs/chef/chef-infra-client/19.3.15/20260601120000']
      )
      expect(host.chef_client_hab_binary_path('chef/chef-infra-client', 'latest')).to eq(
        '/hab/pkgs/chef/chef-infra-client/19.3.15/20260601120000/bin/chef-client'
      )
    end

    it 'returns nil when the pinned version is not installed' do
      allow(host).to receive(:hab_pkg_dirs).with('chef/chef-infra-client').and_return(
        ['/hab/pkgs/chef/chef-infra-client/19.3.15/20260601120000']
      )
      expect(host.chef_client_hab_binary_path('chef/chef-infra-client', '19.2.12')).to be_nil
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

  # Regression coverage for the Windows "'msiexec' is not recognized as an
  # internal or external command" failure (see resources/install.rb's windows?
  # branch): accounts that have never interactively logged on — CI's
  # `net user /add` test user driven over WinRM being the canonical case — can
  # expose a PATH containing literal `%SystemRoot%` tokens, or one missing the
  # Windows system directories entirely. Mixlib::ShellOut does a literal
  # PATH-directory search with no `%` expansion, so both break every bare-name
  # OS executable, msiexec included.
  describe '#repair_windows_path!' do
    let(:system_dirs) do
      [
        'C:\Windows\System32',
        'C:\Windows',
        'C:\Windows\System32\Wbem',
        'C:\Windows\System32\WindowsPowerShell\v1.0',
      ]
    end

    around do |example|
      original_path = ENV.fetch('PATH', nil)
      original_system_root = ENV.fetch('SystemRoot', nil)
      ENV['SystemRoot'] = 'C:\Windows'
      example.run
    ensure
      ENV['PATH'] = original_path
      if original_system_root.nil?
        ENV.delete('SystemRoot')
      else
        ENV['SystemRoot'] = original_system_root
      end
    end

    before { host.fake_windows = true }

    it 'expands literal %VAR% tokens' do
      ENV['PATH'] = 'C:\Users\test\bin;%SystemRoot%\System32'
      host.repair_windows_path!

      expect(ENV.fetch('PATH')).to start_with('C:\Users\test\bin;C:\Windows\System32')
      expect(ENV.fetch('PATH')).not_to include('%')
    end

    it 'appends the system directories when PATH omits them entirely' do
      ENV['PATH'] = 'C:\Users\test\bin'
      host.repair_windows_path!

      expect(ENV.fetch('PATH').split(';')).to eq(['C:\Users\test\bin'] + system_dirs)
    end

    it 'is a no-op when the system directories are already present in any casing' do
      already = 'c:\windows\system32;C:\Windows;C:\Windows\System32\Wbem;' \
                'C:\Windows\System32\WindowsPowerShell\v1.0'
      ENV['PATH'] = already
      host.repair_windows_path!

      expect(ENV.fetch('PATH')).to eq(already)
    end

    it 'never emits an empty PATH entry when PATH starts out empty' do
      ENV['PATH'] = ''
      host.repair_windows_path!

      expect(ENV.fetch('PATH').split(';')).to eq(system_dirs)
    end

    it 'leaves PATH untouched on non-Windows platforms' do
      host.fake_windows = false
      ENV['PATH'] = '/usr/bin:/bin'
      host.repair_windows_path!

      expect(ENV.fetch('PATH')).to eq('/usr/bin:/bin')
    end
  end
end
