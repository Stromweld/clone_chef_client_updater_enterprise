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

  # ChefSpec's remove_habitat_package(name).with(version: ...) matcher looks up
  # a resource by (type, name) only, so with several habitat_package resources
  # sharing the same name (only `version` differs), it can only ever see the
  # last one declared. Inspect every declared :remove resource by version instead.
  def removed_habitat_versions(chef_run, name)
    chef_run.resource_collection.all_resources.select do |r|
      r.resource_name == :habitat_package && r.name == name && r.performed_action?(:remove)
    end.map(&:version)
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
      expect(chef_run).to_not remove_habitat_package('chef/chef-infra-client')
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

    it 'removes every version older than the retained count' do
      expect(removed_habitat_versions(chef_run, 'chef/chef-infra-client')).to contain_exactly('19.1.0', '19.2.0')
    end

    it 'keeps the newest version' do
      expect(removed_habitat_versions(chef_run, 'chef/chef-infra-client')).to_not include('19.3.0')
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
      expect(removed_habitat_versions(chef_run, 'chef/chef-infra-client')).to_not include('19.1.0')
    end

    it 'still removes other old versions' do
      expect(removed_habitat_versions(chef_run, 'chef/chef-infra-client')).to include('19.2.0')
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
      expect(chef_run).to_not remove_habitat_package('chef-infra-client')
    end
  end
end
