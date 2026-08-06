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
require 'json'
require 'uri'
require 'socket'
require 'timeout'

module ChefClientUpdaterEnterprise
  module Helpers
    # Base URL of Chef's Commercial Download API (https://docs.chef.io/download/commercial/).
    COMMERCIAL_DOWNLOAD_HOST = 'https://chefdownload-commercial.chef.io'

    # Ohai platform names that omnitruck-service does NOT recognize, mapped to the
    # closest name it does. See #download_api_platform_info for why this is the
    # only remapping the cookbook needs.
    DOWNLOAD_API_PLATFORM_ALIASES = {
      'almalinux' => 'el',
      'oracle' => 'el',
      'oracleserver' => 'el',
      'scientific' => 'el',
      'xenserver' => 'el',
      'opensuse' => 'sles',
    }.freeze

    # only ones this cookbook knows how to install. Used both to derive the local
    # staging filename from a download URL and to decide whether a URL is a direct
    # artifact link (as opposed to the API's `/download` handler URL).
    PACKAGE_EXTENSIONS = %w(rpm deb msi dmg pkg).freeze

    # Transient failures worth retrying when talking to the Download API.
    COMMERCIAL_RETRYABLE_ERRORS = [
      Errno::ECONNREFUSED,
      Errno::ECONNRESET,
      Errno::EHOSTUNREACH,
      Errno::ETIMEDOUT,
      SocketError,
      Timeout::Error,
    ].freeze

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
    # on this path existing) so both stay in agreement on this path.
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

    # Maps Ohai's platform/platform_version to the values sent as the Commercial
    # Download API's `p` and `pv` parameters.
    #
    # The API does NOT accept arbitrary platform names. omnitruck-service derives the
    # package format from `p` via a fixed lookup table
    # (`clients/omnitruck/package_manager_mapping.go`), and a name missing from that
    # table is rejected outright:
    #
    #   HTTP 400 {"message":"Unable to derive package manager for platform 'almalinux'"}
    #
    # Verified live against chefdownload-commercial.chef.io. Rejected: `almalinux`,
    # `oracle`, `oracleserver`, `scientific`, `xenserver`, `opensuse`. Accepted as-is:
    # `el`, `redhat`, `centos`, `rocky`, `fedora`, `amazon`, `suse`, `sles`,
    # `opensuseleap`, `debian`, `ubuntu`, `linuxmint`, `windows`. So the ONLY work
    # needed here is aliasing the handful of names the API rejects — everything else
    # passes through unchanged. `almalinux` and `oracle` are not hypothetical: they
    # are Kitchen-tested platforms, and without this the install fails with a 400.
    #
    # Passing `pm` explicitly does not avoid this. That skips the derivation step but
    # leaves the unrecognized name in the database lookup, which then fails with
    # `{"message":"Product information not found."}` instead. Verified live.
    #
    # `pv` is sent because the API documents it, but the metadata endpoint DISCARDS
    # it: `DynamoServices#ProductMetadata` sets `params.PlatformVersion = ""` before
    # the lookup, and does not include it in its validation flags. Verified live —
    # `pv` omitted, `9`, `9.4`, `7`, `99` and `garbage` all return the identical
    # artifact for `p=el`. Do not reintroduce version-derivation logic here (major
    # version truncation, `amazon 2` -> `el 7`, etc.); it cannot affect the response.
    # chef-ice publishes exactly one artifact per platform-family/architecture, so
    # there is no platform-version compatibility fallback to reimplement either.
    def download_api_platform_info
      platform = node['platform']
      [DOWNLOAD_API_PLATFORM_ALIASES.fetch(platform, platform), node['platform_version']]
    end

    # Queries Chef's Commercial Download API `metadata` endpoint and returns a
    # { 'url' =>, 'sha256' =>, 'version' => } Hash for the requested artifact.
    #
    # This replaces the mixlib-install gem. The gem was only ever used for these
    # three values, and installing it required vendoring a binary .gem into the
    # cookbook plus a compile-time `chef_gem` — the latter being what made every
    # Test Kitchen suite non-idempotent on its first run under a freshly installed
    # chef-ice (see AGENTS.md "Package Metadata Comes From the Commercial Download
    # API, Not mixlib-install").
    #
    # `direct: true` makes the API return the `/files/...` URL, whose path ends in
    # the real .rpm/.deb/.msi filename, instead of the `/download` handler URL.
    # That matters beyond cosmetics: resources/install.rb only enforces the
    # advertised sha256 on `remote_file` for URLs with a package extension, so the
    # handler URL silently downloaded without checksum verification.
    #
    # `platform_version` is passed through as the API's `pv`, but the API resolves
    # the closest compatible artifact server-side (chef-ice publishes one artifact
    # per architecture/package format, so `pv` is effectively ignored for it) —
    # there is no client-side compatibility-mode fallback to reimplement.
    def commercial_artifact_metadata(product:, version:, channel:, license_key:,
                                     platform:, platform_version:, architecture:)
      query = {
        'p' => platform,
        'pv' => platform_version,
        'm' => architecture,
        'v' => version,
        'license_id' => license_key,
        'direct' => 'true',
      }

      path = "/#{channel}/#{product}/metadata?#{URI.encode_www_form(query)}"
      body = commercial_api_get(path, license_key)

      begin
        data = JSON.parse(body)
      rescue JSON::ParserError => e
        raise 'Chef Commercial Download API returned an unparseable response for ' \
              "#{product} #{version}: #{scrub_license_key(e.message, license_key)}"
      end

      raise "Chef Commercial Download API returned a non-object response for #{product} #{version}" unless data.is_a?(Hash)

      missing = %w(url sha256 version).select { |k| data[k].to_s.empty? }
      unless missing.empty?
        raise "Chef Commercial Download API response for #{product} #{version} is missing " \
              "#{missing.join(', ')}: #{scrub_license_key(body.to_s, license_key)}"
      end

      data
    end

    # Performs a GET against the Commercial Download API, retrying transient
    # network failures. Uses Chef::HTTP::Simple so the request honors the same
    # proxy configuration (Chef::Config[:http_proxy] et al) as remote_file.
    #
    # The license key is embedded in the query string, so EVERY error path scrubs
    # it before the message can reach a log or an exception backtrace.
    def commercial_api_get(path, license_key, retries: 3, retry_delay: 3)
      require 'chef/http/simple'
      require 'net/http'

      attempt = 0
      begin
        attempt += 1
        Chef::HTTP::Simple.new(COMMERCIAL_DOWNLOAD_HOST).get(path)
      rescue *COMMERCIAL_RETRYABLE_ERRORS => e
        if attempt < retries
          sleep(retry_delay)
          retry
        end
        raise "Chef Commercial Download API request failed after #{attempt} attempts: " \
              "#{scrub_license_key(e.message, license_key)}"
      rescue Net::HTTPClientException, Net::HTTPFatalError => e
        response = e.respond_to?(:response) ? e.response : nil
        code = response ? response.code.to_s : ''
        body = response ? response.body.to_s : ''

        # 5xx is worth another attempt; 4xx (bad license, unknown version) never is.
        if code.start_with?('5') && attempt < retries
          sleep(retry_delay)
          retry
        end

        hint = case code
               when '403' then ' (check that license_key is valid and entitled to this product)'
               when '400', '404' then ' (check product_name, version, channel and platform)'
               else ''
               end
        raise "Chef Commercial Download API returned HTTP #{code}#{hint}: " \
              "#{scrub_license_key(body.empty? ? e.message : body, license_key)}"
      end
    end

    # Removes a license key from a string so it never lands in a log or exception.
    def scrub_license_key(text, license_key)
      return text.to_s if license_key.nil? || license_key.to_s.empty?

      text.to_s.gsub(license_key.to_s, 'REDACTED')
    end

    # Extracts the package file extension (without the leading dot) from a download
    # URL, or nil when the URL's path does not end in a known package extension.
    def package_extension_from_url(url)
      path = URI.parse(url.to_s).path.to_s
      ext = ::File.extname(path).delete_prefix('.').downcase
      PACKAGE_EXTENSIONS.include?(ext) ? ext : nil
    rescue URI::InvalidURIError
      nil
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

    # Repairs the current process's PATH on Windows so that plain executable
    # names shipped with the OS (notably `msiexec`) resolve.
    #
    # Two independent breakages are handled, both seen on accounts that have
    # never interactively logged on (CI's `net user /add` test user driven
    # over WinRM is the canonical case):
    #
    #   1. Literal, unexpanded `%SystemRoot%`-style tokens inherited from the
    #      default user profile template. Mixlib::ShellOut does a literal
    #      directory search with no `%` expansion, so those entries resolve to
    #      nothing.
    #   2. A PATH that omits the Windows system directories entirely, which
    #      expansion alone obviously cannot fix.
    #
    # Both surface identically as "'msiexec' is not recognized as an internal
    # or external command" even though msiexec.exe is present on disk. No-op
    # on non-Windows.
    def repair_windows_path!
      return unless windows?

      path = ENV['PATH'].to_s
      path = path.gsub(/%([^%]+)%/) { ENV[Regexp.last_match(1)] || Regexp.last_match(0) } if path.include?('%')

      # Hardcoded rather than ::File::PATH_SEPARATOR: this branch only ever runs
      # on Windows, where the separator is always ';' regardless of what the Ruby
      # interpreter running the spec suite reports.
      sep = ';'
      system_root = ENV['SystemRoot'] || ENV['windir'] || 'C:\\Windows'
      system32 = ::File.join(system_root, 'System32').tr('/', '\\')
      required = [
        system32,
        system_root.tr('/', '\\'),
        ::File.join(system32, 'Wbem').tr('/', '\\'),
        ::File.join(system32, 'WindowsPowerShell', 'v1.0').tr('/', '\\'),
      ]

      existing = path.split(sep).map { |d| d.tr('/', '\\').chomp('\\').downcase }
      missing = required.reject { |d| existing.include?(d.chomp('\\').downcase) }

      ENV['PATH'] = ([path] + missing).reject(&:empty?).join(sep)
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
      running_chef_root.tr('\\', '/').include?('/hab/pkgs/')
    end

    # Returns the full Habitat ident (origin/name/version/release) of the currently running
    # Chef process, or nil if not running under Habitat.
    def running_hab_ident
      return unless running_under_hab?

      parts = running_chef_root.tr('\\', '/').split('/hab/pkgs/').last.split('/')
      return unless parts.length >= 4

      parts[0..3].join('/')
    end
  end
end
