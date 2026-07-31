# frozen_string_literal: true

require 'spec_helper'

# spec/fixtures/cookbooks/chef_client_updater_enterprise/{resources,libraries} are
# per-file symlinks (see spec_helper.rb) that must be kept in sync by hand whenever
# a resource or library file is added/removed. This guards against silent drift:
# if it fails, add/remove the matching symlink under spec/fixtures/cookbooks/...
describe 'spec/fixtures/cookbooks/chef_client_updater_enterprise symlink fixture' do
  %w[resources libraries].each do |segment|
    it "mirrors every file in #{segment}/ exactly" do
      real_files = Dir.glob(File.join(COOKBOOK_ROOT, segment, '*.rb')).map { |f| File.basename(f) }.sort
      fixture_files = Dir.glob(File.join(COOKBOOK_ROOT, 'spec', 'fixtures', 'cookbooks',
                                          'chef_client_updater_enterprise', segment, '*.rb'))
                          .map { |f| File.basename(f) }.sort

      expect(fixture_files).to eq(real_files)
    end
  end
end
