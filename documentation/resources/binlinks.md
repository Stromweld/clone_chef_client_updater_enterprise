
# chef_client_updater_enterprise_binlinks

[back to resource list](../../README.md#resources)

Manages Habitat binlinks for the Chef Infra Client package. Uses `hab pkg binlink` with an explicit
`--dest` to create symlinks for package binaries — `/usr/bin` on Linux, `/usr/local/bin` on macOS,
and `.bat` shims in `C:\hab\bin\` on Windows. (The `--dest` is always passed explicitly because
Habitat's own default destination does not match these paths.) On Windows the resource also ensures
`C:\hab\bin` is added to the system PATH.

The underlying `execute` resource is idempotent on every platform. `migrate-ice apply airgap`
already creates the binlink as a side effect of every install, so this resource's idempotency check
is normally satisfied immediately and `hab pkg binlink` never actually re-runs in practice. On
Linux/macOS, idempotency is detected via `File.symlink?`/`File.readlink` against the resolved
package path. On Windows, binlinks are generated `.bat` shim files rather than true symlinks, so
idempotency instead checks whether the shim's script content already references the resolved
package's install path.

This resource does **not** trigger scheduler resource reconvergence. That is driven entirely from
`chef_client_updater_enterprise_install` (see [its
documentation](install.md#scheduler-resource-reconvergence)).

On Linux/macOS the resource will also delete a stale *regular file* sitting at the binlink
destination — typically an old omnibus `chef-client` binary at `/usr/bin/chef-client` — but only
when `force` is `true`. A correct, current symlink is never deleted; `hab pkg binlink --force`
already replaces a symlink whose target changed.

Introduced: v0.1.0

## Actions

- `:create` — Create Habitat binlinks for the package (default)
- `:remove` — **Not yet implemented.** Logs a warning that `hab` does not support bulk unbinlink. Manual removal of symlinks is required.

## Properties

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `habitat_package` | String | `'chef/chef-infra-client'` | Habitat package identifier to binlink. Must be a bare `origin/name` ident. |
| `version` | String | `'latest'` | `'latest'` (accepted in any casing) uses the most recently installed version; specify an exact version to pin. |
| `force` | true, false | `true` | Delete a stale non-symlink file occupying the binlink destination before linking. Does not affect the `--force` flag passed to `hab pkg binlink`, which is always set. |

## Examples

Create binlinks using defaults (latest installed version):

```ruby
chef_client_updater_enterprise_binlinks 'default'
```

Binlink a specific version, leaving any pre-existing file at the destination alone:

```ruby
chef_client_updater_enterprise_binlinks 'pinned' do
  version '19.3.14'
  force false
end
```
