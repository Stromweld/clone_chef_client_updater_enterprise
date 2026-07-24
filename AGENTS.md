# AGENTS.md

## Purpose

This file records maintainer and agent decisions for the chef_client_updater_enterprise cookbook.
Keep it focused on durable patterns, support boundaries, and non-obvious implementation choices. Do
not use it as a task changelog.

## Architecture

This cookbook is resource-driven only. There are no `recipes/` or `attributes/` directories.
All defaults live on resource properties, `lazy` helper calls, or helper methods in `libraries/`.
Do not reintroduce `node['chef_client_updater_enterprise']` as an attribute API surface.

## Resource Partials and the `use` Directive

Chef's `use` directive auto-prepends an underscore when resolving partial filenames. The partial
file on disk is named `_license.rb`, but the reference in a resource must be `use 'license'`.
Using `use '_license'` would resolve to `__license.rb` and raise a `NameError` at converge time.

Correct:

```ruby
use 'license'          # resolves to _license.rb
use 'version_channel'  # resolves to _version_channel.rb
use 'pkg_names'        # resolves to _pkg_names.rb
```

The `use` partial DSL requires Chef Infra Client >= 17.0. This constraint is enforced in
`metadata.rb` via `chef_version '>= 17.0'`.

## Package Identity

Two distinct package identities are used in this cookbook. Mixing them up will break installs:

- **`chef-ice`** — The `product_name` for `mixlib-install` API calls and the native OS package
  name (rpm/deb/msi). Used by the `install` and `remove_omnibus` resources.
- **`chef/chef-infra-client`** — The Habitat package identifier. Used by the `binlinks` and
  `cleanup` resources for `hab pkg binlink`, `hab pkg list`, and `hab pkg uninstall`.

Do not use `chef/chef-ice` as a Habitat identifier. Do not use `chef/chef-infra-client` as a
`mixlib-install` product name.

## Dependency Management

`mixlib-install` is not a metadata `depends` entry or a Gemfile dependency. It is installed at
compile time via `chef_gem` inside the `install` resource's `action_class`. Do not add it to
`metadata.rb`. This avoids version conflicts with the gem bundled in Chef Workstation.

Use `Policyfile.rb` for dependency resolution. Do not reintroduce Berkshelf files.

## Sensitive Data

The `license_key` property on the `_license` partial is marked `sensitive: true`. The `remote_file`
resource that downloads the package artifact is also `sensitive: true`. Both prevent key material
from appearing in Chef logs or resource diffs.

## Unified Mode

All resources set `unified_mode true`. This ensures that compile-phase resource calls (like
`chef_gem compile_time: true`) inside `action_class` methods are evaluated in the correct converge
order. Do not remove `unified_mode true` from any resource.

## Omnibus Removal

The `remove_omnibus` resource removes both `chef` AND `chef-ice` packages from the native package
manager. When `remove_directories` is true, it also deletes:

- Linux/macOS: `/opt/chef` and `/opt/chef-ice`
- Windows: `C:\opscode\chef`
- macOS: runs `pkgutil --forget` for `com.chef.chef` and `com.chef.chef-ice` receipts

## Platform Support

Intended targets: RHEL 7/8/9, Ubuntu 18.04/22.04/24.04, SLES 15 SP5/SP6. Kitchen configs use
CentOS 7, AlmaLinux 8/9, and openSUSE Leap 15 as test proxies for RHEL and SLES respectively.

Keep `metadata.rb`, Kitchen files, and README platform lists aligned. Do not add platforms without
updating all three locations and confirming `mixlib-install` artifact availability for that platform.

## Binlinks

`hab pkg binlink` creates symlinks for all package binaries. On Linux and macOS these land in
`/usr/bin/`. On Windows they become `.bat` shims in `C:\hab\bin\`, and the resource adds that
directory to the system PATH via `windows_path`.

The `:remove` action on the binlinks resource is a no-op that logs a warning. Habitat does not
provide a bulk unbinlink command. Manual symlink cleanup is required if binlinks need to be removed.
