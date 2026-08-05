
# chef_client_updater_enterprise_cleanup

[back to resource list](../../README.md#resources)

Prunes old Habitat package versions of Chef Infra Client, keeping only the most recent installations. Enumerates installed versions via a filesystem glob under the Habitat package root (no `hab` CLI dependency for listing) and removes the oldest entries beyond the retention count.

Removal is driven directly via `hab pkg uninstall <origin>/<name>/<version>/<release>` (the full ident) through an `execute` resource, **not** Chef's built-in `habitat_package` resource. `habitat_package`'s own idempotency check (`Chef::Provider::Package::Habitat#installed_version`) shells out to `hab pkg path <bare origin/name>`, which resolves whatever Habitat currently considers the active/latest package for that name — not the specific, possibly-older version being removed. When multiple versions coexist on disk (the normal case this cookbook exists to support), that check can report an older version as "not installed" even though its directory is still present, silently no-opping the removal. Driving `hab pkg uninstall` directly against the full ident sidesteps this ambiguity entirely. Each `execute` resource carries its own `only_if { File.directory?(...) }` guard (checked against the actual Habitat package directory) for correct idempotency reporting, and `HAB_LICENSE=accept-no-persist` is supplied via `environment` so the command never blocks on an interactive license prompt.

The Habitat ident backing the *currently running* `chef-client` process is always excluded from removal, even if it would otherwise fall outside the retained count — removing it out from under the running process would break the converge.

Introduced: v0.1.0

## Actions

- `:cleanup` — Remove old Habitat package versions beyond the retention count (default)

## Properties

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `habitat_package` | String | `'chef/chef-infra-client'` | Habitat package identifier to clean up. |
| `product_name` | String | `'chef-ice'` | Native OS package name (not used directly by this resource). |
| `legacy_omnibus_package` | String | `'chef'` | Legacy omnibus package name (not used directly by this resource). |
| `keep_versions` | Integer | `1` | Number of most recently installed Habitat versions to retain. |

## Examples

Clean up old versions, keeping only the latest:

```ruby
chef_client_updater_enterprise_cleanup 'default'
```

Keep the two most recent versions:

```ruby
chef_client_updater_enterprise_cleanup 'default' do
  keep_versions 2
end
```
