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

  # omnitruck-service derives the package format from `p` via a fixed lookup table
  # and rejects any name missing from it with HTTP 400 "Unable to derive package
  # manager for platform '<name>'". Every expectation below was verified live
  # against chefdownload-commercial.chef.io, so this spec is the record of which
  # Ohai names actually need remapping. See AGENTS.md "Platform Names Sent to the
  # Commercial Download API".
  describe '#download_api_platform_info' do
    def set_platform(host, platform:, platform_version:, platform_family: [])
      host.fake_node = { 'platform' => platform, 'platform_version' => platform_version }
      host.fake_platform = platform
      host.fake_platform_family = platform_family
    end

    # These are the names the API rejects outright. almalinux and oracle are not
    # hypothetical: both are Kitchen-tested platforms for this cookbook.
    {
      'almalinux' => 'el',
      'oracle' => 'el',
      'oracleserver' => 'el',
      'scientific' => 'el',
      'xenserver' => 'el',
      'opensuse' => 'sles',
    }.each do |ohai_name, api_name|
      it "aliases #{ohai_name} to #{api_name}, which the API rejects otherwise" do
        set_platform(host, platform: ohai_name, platform_version: '9.4')
        expect(host.download_api_platform_info.first).to eq(api_name)
      end
    end

    # Verified to return HTTP 200 when sent verbatim, so remapping them would only
    # add cases that could drift out of sync with the API.
    %w(el redhat centos rocky fedora amazon suse sles opensuseleap debian ubuntu linuxmint windows).each do |ohai_name|
      it "passes #{ohai_name} through unchanged" do
        set_platform(host, platform: ohai_name, platform_version: '9.4')
        expect(host.download_api_platform_info.first).to eq(ohai_name)
      end
    end

    # ProductMetadata sets params.PlatformVersion = "" before the database lookup and
    # does not validate it, so pv cannot affect the response. Sending Ohai's raw value
    # keeps this method free of derivation logic that would look meaningful but never
    # change anything.
    it 'sends the raw platform_version, since the metadata endpoint discards pv' do
      set_platform(host, platform: 'ubuntu', platform_version: '24.04')
      expect(host.download_api_platform_info).to eq(%w(ubuntu 24.04))
    end

    it 'does not truncate a dotted platform_version to its major version' do
      set_platform(host, platform: 'almalinux', platform_version: '9.4')
      expect(host.download_api_platform_info).to eq(%w(el 9.4))
    end

    # Amazon Linux 2 used to be rewritten to el/7 and 2022/2023 kept as amazon. Since
    # pv is discarded and `amazon` is an accepted platform name, none of that changed
    # the response.
    it 'no longer special-cases Amazon Linux versions' do
      set_platform(host, platform: 'amazon', platform_version: '2')
      expect(host.download_api_platform_info).to eq(%w(amazon 2))

      set_platform(host, platform: 'amazon', platform_version: '2023')
      expect(host.download_api_platform_info).to eq(%w(amazon 2023))
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
      allow(::File).to receive(:directory?).with(unsorted.first).and_return(true)
      allow(::File).to receive(:directory?).with(unsorted.last).and_return(true)

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

    # running_hab_ident normalizes separators, so running_under_hab? -- which now
    # guards it -- has to agree on a backslashed path rather than reporting false.
    it 'recognizes a Habitat install regardless of slash direction' do
      host.fake_windows = true
      allow(host).to receive(:running_chef_root)
        .and_return('C:\hab\pkgs\chef\chef-infra-client\19.3.15\20260601120000')
      expect(host.running_under_hab?).to be true
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

  # The package type is derived from the artifact URL rather than guessed from the
  # node's platform, so the locally-staged filename can never disagree with the file
  # actually fetched. See AGENTS.md "Package Type Comes From the Download URL".
  describe '#package_extension_from_url' do
    it 'derives the extension from a Commercial Download API /files URL' do
      expect(
        host.package_extension_from_url(
          'https://chefdownload-commercial.chef.io/files/stable/chef-ice/19.3.15/' \
          'el/9/chef-ice-19.3.15-1.el9.x86_64.rpm'
        )
      ).to eq('rpm')
    end

    it 'ignores a query string so presigned and license-bearing URLs still resolve' do
      expect(
        host.package_extension_from_url(
          'https://example.invalid/chef-ice_19.3.15-1_amd64.deb?license_id=free-abc&X-Amz-Signature=xyz'
        )
      ).to eq('deb')
    end

    it 'is case insensitive so an uppercased filename still resolves' do
      expect(host.package_extension_from_url('https://example.invalid/chef-ice-19.3.15-1.X86_64.MSI')).to eq('msi')
    end

    %w(rpm deb msi dmg pkg).each do |ext|
      it "recognizes .#{ext}" do
        expect(host.package_extension_from_url("https://example.invalid/chef-ice.#{ext}")).to eq(ext)
      end
    end

    # The API only returns a handler URL like this when `direct=true` is missing.
    # Its response body is not the package, so its advertised sha256 would not match
    # what is actually fetched — returning nil is what lets install.rb reject it.
    it 'returns nil for an API /download handler URL with no filename' do
      expect(
        host.package_extension_from_url('https://chefdownload-commercial.chef.io/stable/chef-ice/download?p=el')
      ).to be_nil
    end

    it 'returns nil for an unknown extension' do
      expect(host.package_extension_from_url('https://example.invalid/chef-ice-19.3.15.tar.gz')).to be_nil
    end

    it 'returns nil rather than raising on an unparseable URL' do
      expect(host.package_extension_from_url('http://exa mple.invalid/chef-ice.rpm')).to be_nil
    end

    it 'returns nil for nil' do
      expect(host.package_extension_from_url(nil)).to be_nil
    end
  end

  # The Commercial Download API replaced the mixlib-install gem (see AGENTS.md
  # "Package Metadata Comes From the Commercial Download API, Not mixlib-install").
  # These specs pin the two behaviors that silently regress if the request is built
  # wrong: `direct=true` (without it the API hands back a /download handler URL with
  # no package extension, and resources/install.rb then skips checksum verification
  # entirely) and license-key scrubbing on every error path.
  describe '#commercial_artifact_metadata' do
    let(:license_key) { 'free-deadbeef-0000-1111-2222-333344445555-9999' }
    let(:body) do
      {
        'sha1' => 'c6d4bc39880e5725d8e73104d9414c567eec1457',
        'sha256' => 'fe004919ddbf171947c6a59d9bd5d516a61ff30e64cf6e4ddd95521b90cc80af',
        'url' => 'https://chefdownload-commercial.chef.io/files/stable/chef-ice/19.3.15/' \
                 "linux/x86_64/rpm/chef-ice-19.3.15-1.amzn2.x86_64.rpm?license_id=#{license_key}",
        'version' => '19.3.15',
      }.to_json
    end

    def metadata(**overrides)
      host.commercial_artifact_metadata(**{
        product: 'chef-ice',
        version: '19.3.15',
        channel: :stable,
        license_key: license_key,
        platform: 'el',
        platform_version: '9',
        architecture: 'x86_64',
      }.merge(overrides))
    end

    it 'requests the metadata endpoint with direct=true and every lookup parameter' do
      requested = nil
      allow(host).to receive(:commercial_api_get) { |path, _key|
        requested = path
        body
      }

      metadata

      expect(requested).to start_with('/stable/chef-ice/metadata?')
      query = URI.decode_www_form(URI.parse(requested).query).to_h
      expect(query).to include(
        'p' => 'el', 'pv' => '9', 'm' => 'x86_64', 'v' => '19.3.15',
        'license_id' => license_key, 'direct' => 'true'
      )
    end

    # `pm` is optional: omnitruck-service derives the package format from `p`.
    # Sending a locally-guessed value could only ever disagree with the platform
    # the API is already being told about.
    it 'does not send a pm package-manager parameter' do
      requested = nil
      allow(host).to receive(:commercial_api_get) { |path, _key|
        requested = path
        body
      }

      metadata

      expect(URI.decode_www_form(URI.parse(requested).query).to_h).not_to have_key('pm')
    end

    it 'returns a /files URL ending in the package filename so the sha256 is verifiable' do
      allow(host).to receive(:commercial_api_get).and_return(body)

      result = metadata
      expect(URI.parse(result['url']).path).to end_with('.rpm')
      expect(result['sha256']).to eq('fe004919ddbf171947c6a59d9bd5d516a61ff30e64cf6e4ddd95521b90cc80af')
      expect(result['version']).to eq('19.3.15')
    end

    it 'raises without leaking the license key when the response is not JSON' do
      allow(host).to receive(:commercial_api_get).and_return("<html>#{license_key}</html>")

      expect { metadata }.to raise_error(/unparseable response/) { |e|
        expect(e.message).not_to include(license_key)
      }
    end

    it 'raises without leaking the license key when required fields are missing' do
      allow(host).to receive(:commercial_api_get)
        .and_return({ 'version' => '19.3.15', 'license_id' => license_key }.to_json)

      expect { metadata }.to raise_error(/missing url, sha256/) { |e|
        expect(e.message).not_to include(license_key)
      }
    end
  end

  describe '#scrub_license_key' do
    it 'redacts the key anywhere it appears' do
      expect(host.scrub_license_key('a=key&b=key', 'key')).to eq('a=REDACTED&b=REDACTED')
    end

    it 'passes the text through when no key is set' do
      expect(host.scrub_license_key('no key here', nil)).to eq('no key here')
      expect(host.scrub_license_key('no key here', '')).to eq('no key here')
    end
  end
end
