
# chef_client_updater_enterprise_remove_omnibus

[back to resource list](../../README.md#resources)

Removes a legacy omnibus Chef Infra Client installation (the `legacy_omnibus_package`, `chef` by
default) — **not** `chef-ice` or the Habitat-managed installation, which are managed separately by
`chef_client_updater_enterprise_install` and `chef_client_updater_enterprise_cleanup`. Optionally
deletes the leftover installation directory afterward.

This resource is a no-op (with a warning) in two safety-guarding situations:

- If the *currently running* `chef-client` process is itself executing from the legacy omnibus
  install, removal is deferred to a subsequent converge running under `chef-ice`/Habitat instead —
  removing the omnibus files out from under the running process would break the converge.
- If no `chef-ice` Habitat package is installed yet (nothing under
  `hab_pkg_dirs(habitat_package)`), removal is deferred until `chef-ice` is actually present —
  this resource assumes the Habitat-based install has already succeeded before the omnibus
  fallback is torn down.

Introduced: v0.1.0

## Actions

- `:remove` — Remove the legacy omnibus package and (optionally) its installation directory
  (default)

## Properties

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `habitat_package` | String | `'chef/chef-infra-client'` | Habitat package identifier, used only to confirm `chef-ice` is already installed before proceeding. Must be a bare `origin/name` ident. |
| `version` | String | `'latest'` | Accepted via the shared property partial but not used by this resource. |
| `legacy_omnibus_package` | String | `'chef'` | Legacy omnibus package name to remove via the native package manager. |
| `remove_directories` | true, false | `true` | Remove the legacy omnibus installation directory after package uninstall. |

## Package Removal by Platform

- **Windows:** The omnibus MSI registers in Programs and Features under a per-version *display*
  name (`Chef Infra Client v<version>`), which Chef matches by exact string equality — so the
  `legacy_omnibus_package` property does not apply here. The resource first discovers the exact
  display name with `Get-Package -Name 'Chef Infra Client*'` (filtering out `chef-ice` and
  `air-gapped` matches, since chef-ice's own MSI entry also starts with `Chef Infra`), then hands
  that name to Chef's `windows_package` resource for a native, idempotent removal. If no matching
  entry is found, the step is skipped with an informational log message.
- **Linux (all families):** Chef's built-in `package` resource with `action :remove`, so removal is
  idempotent and reports up-to-date correctly. Failures are ignored.
- **macOS:** Runs `pkgutil --forget com.chef.chef` only if that package receipt is currently
  registered.
- Any other platform: no package-manager removal step is run (directory removal still applies if
  `remove_directories` is `true`).

## Directories Removed

When `remove_directories` is `true`:

- **Linux/macOS:** `/opt/chef`
- **Windows:** `C:\opscode\chef`

`chef-ice` has no `/opt/chef-ice` equivalent to remove — its payload lives under `/hab/pkgs/` and is
managed by `chef_client_updater_enterprise_cleanup`.

If `/opt/chef` is itself a dedicated mount point (some sites mount a separate block device there,
and the official `chef/chef` Dokken image declares it as a Docker `VOLUME`), its *contents* are
deleted entry by entry instead of the directory itself. Deleting a mount point is an `rmdir()`,
which the kernel refuses with `EBUSY` even when the directory is empty.

## Examples

Remove the legacy omnibus installation and its directory:

```ruby
chef_client_updater_enterprise_remove_omnibus 'default'
```

Remove the package but keep the installation directory:

```ruby
chef_client_updater_enterprise_remove_omnibus 'default' do
  remove_directories false
end
```
