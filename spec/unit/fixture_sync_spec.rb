# frozen_string_literal: true

require 'spec_helper'

# spec/fixtures/cookbooks/chef_client_updater_enterprise/{resources,libraries} are
# per-file symlinks (see spec_helper.rb) that must be kept in sync by hand whenever
# a resource or library file is added/removed. This guards against silent drift:
# if it fails, add/remove the matching symlink under spec/fixtures/cookbooks/...
describe 'spec/fixtures/cookbooks/chef_client_updater_enterprise symlink fixture' do
  %w(resources libraries).each do |segment|
    it "mirrors every file in #{segment}/ exactly" do
      real_files = Dir.glob(File.join(COOKBOOK_ROOT, segment, '*.rb')).map { |f| File.basename(f) }.sort
      fixture_files = Dir.glob(File.join(COOKBOOK_ROOT, 'spec', 'fixtures', 'cookbooks',
                                          'chef_client_updater_enterprise', segment, '*.rb'))
                         .map { |f| File.basename(f) }.sort

      expect(fixture_files).to eq(real_files)
    end

    it "has every fixture file in #{segment}/ symlinked (not copied) to the real file" do
      fixture_dir = File.join(COOKBOOK_ROOT, 'spec', 'fixtures', 'cookbooks',
                               'chef_client_updater_enterprise', segment)
      Dir.glob(File.join(fixture_dir, '*.rb')).each do |fixture_path|
        expect(File.symlink?(fixture_path)).to be(true),
          "#{fixture_path} is a regular file, not a symlink — it will silently drift from " \
          'the real cookbook source. See AGENTS.md "Unit Testing (ChefSpec/RSpec)".'

        real_path = File.join(COOKBOOK_ROOT, segment, File.basename(fixture_path))
        expect(File.realpath(fixture_path)).to eq(File.realpath(real_path)),
          "#{fixture_path} does not resolve to #{real_path}"
      end
    end
  end

  it 'symlinks metadata.rb to the real file' do
    fixture_path = File.join(COOKBOOK_ROOT, 'spec', 'fixtures', 'cookbooks',
                              'chef_client_updater_enterprise', 'metadata.rb')
    real_path = File.join(COOKBOOK_ROOT, 'metadata.rb')

    expect(File.symlink?(fixture_path)).to be(true),
      "#{fixture_path} is a regular file, not a symlink — it will silently drift from " \
      'the real cookbook source.'
    expect(File.realpath(fixture_path)).to eq(File.realpath(real_path))
  end
end
