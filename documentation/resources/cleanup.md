
# chef_client_updater_enterprise_cleanup

[back to resource list](../../README.md#resources)

Prunes old Habitat package versions of Chef Infra Client, keeping only the most recent installations. Enumerates installed versions via a filesystem glob under the Habitat package root (no `hab` CLI dependency for listing) and removes the oldest entries beyond the retention count via Chef's built-in `habitat_package` resource with `action :remove`.

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
