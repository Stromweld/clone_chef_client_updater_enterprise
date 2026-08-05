# frozen_string_literal: true

require 'chefspec'

RSpec.configure do |config|
  config.filter_run_when_matching :focus
end

COOKBOOK_ROOT = File.expand_path('..', __dir__)

# All chef_client_updater_enterprise_* resources this cookbook defines. ChefSpec
# treats custom resources as opaque no-ops unless told to `step_into` them, so
# every unit spec needs its own resource's action_class code to actually run
# (that's the whole point of testing it) — default to stepping into all of them.
ALL_CUSTOM_RESOURCES = %w[
  chef_client_updater_enterprise_install
  chef_client_updater_enterprise_binlinks
  chef_client_updater_enterprise_cleanup
  chef_client_updater_enterprise_remove_omnibus
].freeze

# ChefSpec::SoloRunner#converge_block only compiles recipes/resources for
# cookbooks named in the run_list. This cookbook has no recipes/ directory
# (see AGENTS.md "Architecture"), so a plain converge_block never registers
# its custom resources. spec/fixtures/cookbooks/chefspec_shim `depends` on
# this cookbook, purely so converging its empty default recipe pulls
# chef_client_updater_enterprise's resources/*.rb into cookbook_order without
# executing any real resource actions. This cookbook's real parent directory
# is deliberately NOT used as cookbook_path: another checkout of this
# cookbook (declaring the same name in its own metadata.rb) may exist
# alongside it, which Chef's CookbookLoader refuses to merge. Instead,
# spec/fixtures/cookbooks/chef_client_updater_enterprise/{metadata.rb,
# resources,libraries} are individual per-file symlinks back to this
# cookbook's real files — Dir.glob (used by Chef's cookbook loader) does not
# recurse into symlinked *directories*, so each file must be symlinked
# separately rather than symlinking resources/libraries as whole directories.
def converge_resource(**options, &block)
  cookbook_path = File.join(COOKBOOK_ROOT, 'spec', 'fixtures', 'cookbooks')
  defaults = { platform: 'ubuntu', version: '22.04', cookbook_path: [cookbook_path], step_into: ALL_CUSTOM_RESOURCES }
  runner = ChefSpec::SoloRunner.new(defaults.merge(options))
  runner.converge('chefspec_shim::default') do
    recipe = Chef::Recipe.new('chefspec_shim', '_unit_test', runner.run_context)
    recipe.instance_exec(&block)
  end
  runner
end

