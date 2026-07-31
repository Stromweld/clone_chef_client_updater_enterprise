
# chef_client_updater_enterprise_binlinks

[back to resource list](../../README.md#resources)

Manages Habitat binlinks for the Chef Infra Client package. Uses `hab pkg binlink` to create symlinks for package binaries — on Linux and macOS these land in `/usr/bin/`, on Windows they become `.bat` shims in `C:\hab\bin\`. On Windows the resource also ensures `C:\hab\bin` is added to the system PATH.

The underlying `execute` resource is idempotent on every platform. This resource also carries a redundant-backup `:immediately` notification (triggering scheduler resource reconvergence) to the parent `chef_client_updater_enterprise_install` resource's `ruby_block`, but the *primary* trigger is wired from the platform-specific package-install resource in `install.rb`'s `action :install` instead — `migrate-ice apply airgap` already creates the binlink as a side effect of every install, so this resource's own idempotency check is satisfied immediately and it never actually reports a change in practice (see `install.md`'s "Scheduler Resource Reconvergence" section). On Linux/macOS, idempotency is detected via `File.symlink?`/`File.readlink` against the resolved package path. On Windows, binlinks are generated `.bat` shim files rather than true symlinks, so idempotency instead checks whether the shim's script content already references the resolved package's install path.

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
| `version` | String | `'latest'` | `'latest'` uses the most recently installed version; specify an exact version/release to pin. |
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
