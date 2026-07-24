
# chef_client_updater_enterprise_binlinks

[back to resource list](../../README.md#resources)

Manages Habitat binlinks for the Chef Infra Client package. Uses `hab pkg binlink` to create symlinks for package binaries — on Linux and macOS these land in `/usr/bin/`, on Windows they become `.bat` shims in `C:\hab\bin\`. On Windows the resource also ensures `C:\hab\bin` is added to the system PATH.

Introduced: v0.1.0

## Actions

- `:create` — Create Habitat binlinks for the package (default)
- `:remove` — **Not yet implemented.** Logs a warning that `hab` does not support bulk unbinlink. Manual removal of symlinks is required.

## Properties

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `habitat_package` | String | `'chef/chef-infra-client'` | Habitat package identifier to binlink. |
| `product_name` | String | `'chef-ice'` | Native OS package name (not used directly by this resource). |
| `legacy_omnibus_package` | String | `'chef'` | Legacy omnibus package name (not used directly by this resource). |
| `version` | String | | Specific Habitat package version to binlink. Omit to use the most recently installed version. |
| `force` | true, false | `true` | Pass `--force` to `hab pkg binlink` to overwrite existing links. |

## Examples

Create binlinks using defaults (latest installed version, with `--force`):

```ruby
chef_client_updater_enterprise_binlinks 'default'
```

Binlink a specific version without forcing:

```ruby
chef_client_updater_enterprise_binlinks 'pinned' do
  version '18.5.0/20260101120000'
  force false
end
```
