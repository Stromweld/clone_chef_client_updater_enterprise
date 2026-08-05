# frozen_string_literal: true
#
# Cookbook:: chef_client_updater_enterprise
# Library:: helpers
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

require 'mixlib/shellout'
require 'rbconfig'

module ChefClientUpdaterEnterprise
  module Helpers
    # Returns true if the hab binary is available on the system.
    def hab_installed?
      !hab_binary.nil?
    end

    # Returns the full path to the hab binary, or nil if not found.
    def hab_binary
      if windows?
        ['chef/hab', 'core/hab'].each do |pkg|
          dir = hab_pkg_dirs(pkg).last
          next unless dir

          candidate = ::File.join(dir, 'bin', 'hab.exe')
          return candidate if ::File.executable?(candidate)
        end
        return
      end

      candidates = ['/hab/bin/hab', '/bin/hab', '/usr/bin/hab', '/usr/local/bin/hab']

      candidates.each do |path|
        return path if ::File.executable?(path)
      end
      nil
    end

    # Environment hash that accepts the Habitat license non-interactively.
    # Prevents hab CLI commands from blocking on an interactive prompt.
    def hab_env
      { 'HAB_LICENSE' => 'accept-no-persist' }
    end

    # Returns the platform-correct base path for a Habitat package.
    # pkg is in 'origin/name' form, e.g. 'chef/chef-infra-client'.
    def hab_pkg_root(pkg)
      if windows?
        "C:/hab/pkgs/#{pkg}"
      elsif platform?('mac_os_x')
        "/opt/hab/pkgs/#{pkg}"
      else
        "/hab/pkgs/#{pkg}"
      end
    end

    # Returns the platform-correct directory `hab pkg binlink` writes chef-client's
    # stable, version-independent binstub/symlink into. Shared by
    # chef_client_updater_enterprise_binlinks (the `--dest` for `hab pkg binlink`) and
    # chef_client_updater_enterprise_install (whose scheduler resource reconvergence relies
    # on this path existing) so all three stay in agreement on this path.
    def chef_client_binlink_dir
      if windows?
        'C:\hab\bin'
      elsif platform?('mac_os_x')
        '/usr/local/bin'
      else
        '/usr/bin'
      end
    end

    # Returns the full stable path to the chef-client binlink: a real symlink on
    # Linux/macOS, a generated `.bat` shim on Windows. This is a convenience path
    # exposed for other resources (chef_client_updater_enterprise_binlinks' `--dest`,
    # end-user recipes/InSpec checks that just want "the current chef-client"), but is
    # NOT what scheduler resources should be pointed at via `chef_binary_path` — see
    # chef_client_hab_binary_path below for why.
    def chef_client_binlink_path
      if windows?
        "#{chef_client_binlink_dir}\\chef-client.bat"
      else
        "#{chef_client_binlink_dir}/chef-client"
      end
    end

    # Returns the full path to the chef-client binary inside a Habitat package.
    def chef_client_hab_binary_path(pkg, version = nil)
      dirs = hab_pkg_dirs(pkg)
      target_dir =
        if version && version != 'latest'
          dirs.select { |d| d.split('/')[-2] == version }.last
        else
          dirs.last
        end
      return unless target_dir

      bin_name = windows? ? 'chef-client.bat' : 'chef-client'
      ::File.join(target_dir, 'bin', bin_name)
    end

    # Returns a sorted array of VERSION/RELEASE subdirectory paths under hab_pkg_root(pkg).
    # Sorted by basename (release timestamps are monotonically increasing).
    # Returns an empty array if the root directory does not exist.
    def hab_pkg_dirs(pkg)
      root = hab_pkg_root(pkg)
      return [] unless ::File.directory?(root)

      ::Dir.glob("#{root}/*/*").select { |d| ::File.directory?(d) }.sort_by { |d| ::File.basename(d) }
    end

    # Returns the most recently installed Habitat ident for the given package,
    # or nil if no version is installed.
    def current_hab_ident(pkg)
      return unless (hab = hab_binary)

      cmd = Mixlib::ShellOut.new("#{hab} pkg list #{pkg}", environment: hab_env)
      cmd.run_command
      return unless cmd.exitstatus.zero?

      lines = cmd.stdout.strip.split("\n").reject(&:empty?)
      lines.last
    end

    # Extracts the version component from a hab ident string (origin/name/version/release).
    # Returns nil if the ident is blank or malformed.
    def current_hab_version(pkg)
      ident = current_hab_ident(pkg)
      return if ident.nil?

      parts = ident.split('/')
      parts[2]
    end

    # Maps Ohai's raw platform/platform_version to the Chef downloads API's platform
    # vocabulary, mirroring mixlib-install's own install.sh platform_detection.sh
    # server-side remapping. This is NOT what Ohai reports: RHEL-family distros
    # other than Rocky/Amazon report as generic 'el' with only the major version;
    # Rocky Linux keeps its own 'rocky' platform name; Amazon Linux 2022/2023 keep
    # 'amazon', older Amazon Linux maps to 'el' 6/7; SUSE Enterprise reports as
    # 'sles'; openSUSE Leap keeps its own name. debian/sles/opensuseleap use major
    # version only, never Ohai's full dotted platform_version.
    def mixlib_install_platform_info
      platform = node['platform']
      platform_version = node['platform_version']
      major_version = platform_version.split('.').first

      case platform
      when 'rocky'
        [platform, major_version]
      when 'amazon'
        case platform_version
        when '2022', '2023'
          [platform, platform_version]
        when '2'
          %w(el 7)
        else
          %w(el 6)
        end
      when 'xenserver'
        [platform, major_version]
      else
        if %w(redhat centos almalinux oracle).include?(platform)
          ['el', major_version]
        elsif platform_family?('suse') && platform != 'opensuseleap'
          ['sles', major_version]
        elsif %w(debian sles opensuseleap fedora).include?(platform)
          [platform, major_version]
        else
          [platform, platform_version]
        end
      end
    end

    # Returns the currently installed native package version, or nil if not installed.
    # Uses platform-appropriate package query tools.
    def current_native_version(pkg_name)
      if platform_family?('debian')
        cmd = Mixlib::ShellOut.new("dpkg-query -W -f='${Version}' #{pkg_name}", timeout: 15)
        cmd.run_command
        return unless cmd.exitstatus.zero?

        ver = cmd.stdout.strip
        ver.empty? ? nil : ver
      elsif platform_family?('rhel', 'fedora', 'amazon', 'suse')
        cmd = Mixlib::ShellOut.new("rpm -q --queryformat '%{VERSION}' #{pkg_name}", timeout: 15)
        cmd.run_command
        return unless cmd.exitstatus.zero?

        ver = cmd.stdout.strip
        (ver.empty? || ver.include?('not installed')) ? nil : ver
      elsif platform?('mac_os_x')
        cmd = Mixlib::ShellOut.new("pkgutil --pkg-info com.chef.#{pkg_name} 2>/dev/null", timeout: 15)
        cmd.run_command
        return unless cmd.exitstatus.zero?

        line = cmd.stdout.lines.find { |l| l.start_with?('version:') }
        line ? line.split(':').last.strip : nil
      elsif windows?
        # chef-ice's MSI registers DisplayName as "Chef Infra (air-gapped) - chef-ice",
        # not the bare product name — match on substring rather than exact equality.
        script = <<~PS1
          $paths = 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*',
                   'HKLM:\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*'
          Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*#{pkg_name}*' } |
            Select-Object -First 1 -ExpandProperty DisplayVersion
        PS1
        cmd = Mixlib::ShellOut.new(
          ['powershell.exe', '-NoProfile', '-Command', script],
          timeout: 15
        )
        cmd.run_command
        return unless cmd.exitstatus.zero?

        ver = cmd.stdout.strip
        ver.empty? ? nil : ver
      end
    end

    # Returns the installed version, preferring Habitat over native packages.
    # Falls back to filesystem glob, then native package query if hab version is not found.
    def current_installed_version(pkg_name, hab_pkg)
      ver = current_hab_version(hab_pkg)
      return ver unless ver.nil?

      dirs = hab_pkg_dirs(hab_pkg)
      unless dirs.empty?
        newest = dirs.last
        # Path structure: .../VERSION/RELEASE — version is the second-to-last component
        parts = newest.split('/')
        fs_ver = parts[-2]
        return fs_ver unless fs_ver.nil? || fs_ver.empty?
      end

      current_native_version(pkg_name)
    end

    # Derives the root of the currently running Chef installation.
    # Uses the loaded chef gem path which is reliable under both omnibus and Habitat.
    # Omnibus: /opt/chef/embedded/lib/ruby/gems/X.Y.Z/gems/chef-VERSION → root /opt/chef
    # Habitat: /hab/pkgs/chef/chef-infra-client/VERSION/RELEASE/lib/ruby/gems/X.Y.Z/gems/chef-VERSION → root /hab/pkgs/chef/chef-infra-client/VERSION/RELEASE
    def running_chef_root
      gem_path = Gem.loaded_specs['chef'].full_gem_path
      normalized = gem_path.gsub('\\', '/')

      if normalized.include?('/hab/pkgs/')
        # Extract up to /hab/pkgs/origin/name/version/release
        before, after = normalized.split('/hab/pkgs/', 2)
        parts = after.split('/')
        "#{before}/hab/pkgs/#{parts[0..3].join('/')}"
      elsif normalized.include?('/embedded/')
        # Omnibus: /opt/chef/embedded/lib/... → /opt/chef
        normalized.split('/embedded/').first
      elsif normalized.downcase.include?('/opscode/chef')
        # Windows omnibus: C:/opscode/chef/embedded/... → C:/opscode/chef
        normalized.split('/embedded/').first
      else
        # Fallback
        ::File.expand_path('../..', RbConfig::CONFIG['bindir'])
      end
    end

    # Returns true if `chef-client` resolves via $PATH
    def chef_client_on_path?
      exe = windows? ? 'chef-client.bat' : 'chef-client'
      path_dirs = ENV['PATH'].to_s.split(::File::PATH_SEPARATOR)
      path_dirs.any? { |dir| ::File.executable?(::File.join(dir, exe)) }
    end

    # Returns true if `path` is itself a filesystem mount point (e.g. a dedicated
    # block device mounted at /opt/chef, which some users use to keep the
    # omnibus install isolated from the root drive image). Compares the device
    # ID of `path` against its parent directory's device ID - they differ only
    # when `path` is where a separate filesystem is mounted. Deleting such a
    # directory outright always raises Errno::EBUSY ("Device or resource
    # busy"), even when empty, so callers must empty its contents instead of
    # removing the directory itself. Not meaningful on Windows.
    def mount_point?(path)
      return false unless ::File.directory?(path)

      ::File.stat(path).dev != ::File.stat(::File.dirname(path)).dev
    end

    # Returns true if the currently executing Chef process is running from a legacy omnibus install.
    def running_under_omnibus?
      root = running_chef_root
      if windows?
        root.casecmp?('c:/opscode/chef') || root.casecmp?('c:\\opscode\\chef') ||
          root.downcase.start_with?('c:/opscode/chef/', 'c:\\opscode\\chef\\')
      else
        root.start_with?('/opt/chef')
      end
    end

    # Returns true if the currently executing Chef process is running from a Habitat package.
    def running_under_hab?
      running_chef_root.include?('/hab/pkgs/')
    end

    # Returns the full Habitat ident (origin/name/version/release) of the currently running
    # Chef process, or nil if not running under Habitat.
    def running_hab_ident
      root = running_chef_root.gsub('\\', '/')
      return unless root.include?('/hab/pkgs/')

      parts = root.split('/hab/pkgs/').last.split('/')
      return unless parts.length >= 4

      parts[0..3].join('/')
    end
  end
end
