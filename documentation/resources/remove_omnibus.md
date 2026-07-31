
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
| `habitat_package` | String | `'chef/chef-infra-client'` | Habitat package identifier, used only to confirm `chef-ice` is already installed before proceeding. |
| `product_name` | String | `'chef-ice'` | Not used directly by this resource — accepted only via the shared `pkg_names` partial. |
| `legacy_omnibus_package` | String | `'chef'` | Legacy omnibus package name to remove via the native package manager. |
| `remove_directories` | true, false | `true` | Remove the legacy omnibus installation directory after package uninstall. |

## Package Removal by Platform

- **Windows:** `Get-Package -Name '<legacy_omnibus_package>' | Uninstall-Package` via
  `powershell_script`, with failures ignored.
- **Linux (RHEL family):** `rpm -e --nodeps <legacy_omnibus_package>` via `execute`, failures
  ignored. Shells out directly to `rpm` rather than `dnf`/`yum`/`zypper`, since those frontends may
  no longer have a working helper script once `migrate-ice` has run.
- **Linux (Debian family):** `dpkg --purge <legacy_omnibus_package>` via `execute`, failures
  ignored.
- **macOS:** Runs `pkgutil --forget com.chef.chef` only if that package receipt is currently
  registered.
- Any other platform: no package-manager removal step is run (directory removal still applies if
  `remove_directories` is `true`).

## Directories Removed

When `remove_directories` is `true`:

- **Linux/macOS:** `/opt/chef`
- **Windows:** `C:\opscode\chef`

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
