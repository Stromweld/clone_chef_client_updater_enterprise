# frozen_string_literal: true

require 'spec_helper'

describe 'chef_client_updater_enterprise_cleanup' do
  let(:root) { '/hab/pkgs/chef/chef-infra-client' }
  let(:dirs) do
    [
      "#{root}/19.1.0/20260101090000",
      "#{root}/19.2.0/20260201090000",
      "#{root}/19.3.0/20260301090000",
    ]
  end

  def stub_installed_dirs(root, dirs)
    allow(::File).to receive(:directory?).and_call_original
    allow(::File).to receive(:directory?).with(root).and_return(true)
    allow(::Dir).to receive(:glob).with("#{root}/*/*").and_return(dirs)
    dirs.each { |d| allow(::File).to receive(:directory?).with(d).and_return(true) }
  end

  def stub_running_ident(gem_path)
    chef_spec = instance_double(Gem::Specification, full_gem_path: gem_path)
    allow(Gem).to receive(:loaded_specs).and_return('chef' => chef_spec)
  end

  # cleanup.rb drives removal via a plain `execute` resource (not the built-in
  # `habitat_package`, whose own idempotency check cannot distinguish a specific
  # non-latest installed version — see the comment in cleanup.rb for why). Several
  # `execute["remove Habitat package ..."]` resources share the same resource type
  # but differ by name (the full ident is baked into the resource name itself),
  # so — unlike the old habitat_package-based test — a plain type/name matcher
  # is inherently unambiguous per ident already. Collect the full set for clarity.
  def removed_idents(chef_run)
    chef_run.resource_collection.all_resources.select do |r|
      r.resource_name == :execute && r.name.start_with?('remove Habitat package ')
    end.map { |r| r.name.delete_prefix('remove Habitat package ') }
  end

  context 'fewer installed versions than keep_versions' do
    let(:chef_run) do
      stub_installed_dirs(root, dirs[0..0])
      stub_running_ident('/hab/pkgs/chef/chef-infra-client/19.1.0/20260101090000/lib/ruby/gems/3.1.0/gems/chef-19.1.0')

      converge_resource do
        chef_client_updater_enterprise_cleanup 'trim' do
          keep_versions 2
        end
      end
    end

    it 'removes nothing' do
      expect(removed_idents(chef_run)).to be_empty
    end
  end

  context 'more installed versions than keep_versions' do
    let(:chef_run) do
      stub_installed_dirs(root, dirs)
      stub_running_ident('/hab/pkgs/chef/chef-infra-client/19.3.0/20260301090000/lib/ruby/gems/3.1.0/gems/chef-19.3.0')

      converge_resource do
        chef_client_updater_enterprise_cleanup 'trim' do
          keep_versions 1
        end
      end
    end

    it 'removes every version older than the retained count, by full ident' do
      expect(removed_idents(chef_run)).to contain_exactly(
        'chef/chef-infra-client/19.1.0/20260101090000',
        'chef/chef-infra-client/19.2.0/20260201090000'
      )
    end

    it 'keeps the newest version' do
      expect(removed_idents(chef_run)).to_not include('chef/chef-infra-client/19.3.0/20260301090000')
    end

    it 'each removal execute resource actually targets the full ident, not just the version' do
      removal = chef_run.resource_collection.all_resources.find do |r|
        r.resource_name == :execute && r.name == 'remove Habitat package chef/chef-infra-client/19.1.0/20260101090000'
      end
      expect(removal.command).to include('chef/chef-infra-client/19.1.0/20260101090000')
    end
  end

  context 'the currently running version is also the oldest, scheduled for removal' do
    let(:chef_run) do
      stub_installed_dirs(root, dirs)
      # Running from the OLDEST installed version — would normally be pruned first.
      stub_running_ident('/hab/pkgs/chef/chef-infra-client/19.1.0/20260101090000/lib/ruby/gems/3.1.0/gems/chef-19.1.0')

      converge_resource do
        chef_client_updater_enterprise_cleanup 'trim' do
          keep_versions 1
        end
      end
    end

    it 'never removes the version the currently running process was loaded from' do
      expect(removed_idents(chef_run)).to_not include('chef/chef-infra-client/19.1.0/20260101090000')
    end

    it 'still removes other old versions' do
      expect(removed_idents(chef_run)).to include('chef/chef-infra-client/19.2.0/20260201090000')
    end
  end

  context 'habitat_package is misconfigured without an origin (malformed ident)' do
    let(:root) { '/hab/pkgs/chef-infra-client' }
    let(:dirs) { ["#{root}/19.1.0/20260101090000", "#{root}/19.2.0/20260201090000"] }

    let(:chef_run) do
      stub_installed_dirs(root, dirs)
      stub_running_ident('/opt/chef/embedded/lib/ruby/gems/3.1.0/gems/chef-19.0.0')

      converge_resource do
        chef_client_updater_enterprise_cleanup 'trim' do
          habitat_package 'chef-infra-client'
          keep_versions 1
        end
      end
    end

    it 'skips the malformed ident instead of raising or declaring a resource for it' do
      expect { chef_run }.to_not raise_error
      expect(removed_idents(chef_run)).to be_empty
    end
  end
end
