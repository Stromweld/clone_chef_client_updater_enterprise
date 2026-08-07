# frozen_string_literal: true
#
# InSpec Integration Test:: multi-version
#
# Verifies the pinned-upgrade scenario driven by the `multi_version` recipe: an
# older chef-ice is installed first, then 19.3.15, then an UNPINNED `latest`;
# binlinks are pointed at the newest version and cleanup keeps only that one.
#
# The third install is deliberately unpinned, so the version that must survive
# cleanup changes whenever a newer chef-ice is promoted to stable. Rather than
# hardcoding it here (which rots silently until someone notices), this profile
# asks the Commercial Download API what `latest` currently resolves to.

require 'json'
require 'net/http'
require 'uri'

title 'multi-version upgrade verification'

# Resolves the version `latest` currently points at for a product/channel.
#
# `/versions/latest` is used rather than `/metadata` because it takes no
# platform parameters at all — the InSpec runner's own OS is irrelevant here and
# there is no platform name needing an alias (see AGENTS.md, "Commercial
# Download API"). The call runs on the runner, not the target.
#
# Returns nil on ANY failure so an unreachable API degrades to a visible skip
# rather than a spurious cookbook failure. The license key is never placed in a
# message or exception, only in the query string.
def published_latest_version(channel, product, license_key)
  return if license_key.to_s.empty?

  uri = URI("https://chefdownload-commercial.chef.io/#{channel}/#{product}/versions/latest")
  uri.query = URI.encode_www_form('license_id' => license_key)

  response = Net::HTTP.get_response(uri)
  return unless response.is_a?(Net::HTTPSuccess)

  version = JSON.parse(response.body)
  version.is_a?(String) && !version.empty? ? version : nil
rescue StandardError
  nil
end

# An explicit input still wins, so an airgapped or deliberately pinned run can
# bypass the network call entirely. kitchen.yml does NOT pin it for this suite.
pinned = input('expected_chef_ice_version', value: nil)
expected_version = pinned.is_a?(String) && !pinned.empty? ? pinned : nil
expected_version ||= published_latest_version(
  input('chef_ice_channel', value: 'stable'),
  'chef-ice',
  ENV.fetch('CHEF_LICENSE_KEY', nil)
)

describe command('chef-client --version') do
  its('exit_status') { should eq 0 }
  its('stdout') { should match(/Chef Infra Client/) }
end

if os.linux?
  older_chef_ice_version = input('older_chef_ice_version', value: '19.2.12')

  # Discover what actually survived rather than trusting a hardcoded value, and
  # additionally assert exactly ONE version directory remains (not just that a
  # plausible-looking one exists), so an incomplete cleanup leaving several
  # versions behind can't slip past this control.
  retained_dirs = command('ls -1 /hab/pkgs/chef/chef-infra-client').stdout.split("\n").reject(&:empty?)
  retained_version = retained_dirs.grep(/\A\d+(\.\d+)*\z/).max_by { |v| Gem::Version.new(v) }

  describe retained_dirs do
    it { should_not be_empty }
  end

  describe 'retained chef-infra-client version count' do
    subject { retained_dirs.length }
    it { should eq 1 }
  end

  # This is the control the API query exists for. Every other assertion here is
  # satisfied even if the unpinned third install silently no-ops: exactly one
  # version would still remain, the binlink would still point at it, and the
  # older version would still be gone — just at a stale release.
  describe 'retained chef-infra-client version vs latest published chef-ice' do
    if expected_version
      subject { retained_version }
      it { should eq expected_version }
    else
      skip 'could not resolve the latest published chef-ice version ' \
           '(CHEF_LICENSE_KEY unset or Commercial Download API unreachable)'
    end
  end

  describe file('/usr/bin/chef-client') do
    it { should exist }
    it { should be_symlink }
    its('link_path') { should include('/hab/pkgs/chef/chef-infra-client/') }
    its('link_path') { should include(retained_version) } if retained_version
  end

  if retained_version
    describe file("/hab/pkgs/chef/chef-infra-client/#{retained_version}") do
      it { should exist }
      it { should be_directory }
    end
  end

  describe file("/hab/pkgs/chef/chef-infra-client/#{older_chef_ice_version}") do
    it { should_not exist }
  end
end

if os.windows?
  describe file('C:/hab/bin/chef-client.bat') do
    it { should exist }
  end
end
