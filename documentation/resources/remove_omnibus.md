
# chef_client_updater_enterprise_remove_omnibus

[back to resource list](../../README.md#resources)

Removes legacy omnibus Chef Infra Client installations. Uninstalls both the `chef` and `chef-ice` packages through the native OS package manager, then optionally deletes the leftover installation directories. On macOS, also runs `pkgutil --forget` to clear package receipts.

Introduced: v0.1.0

## Actions

- `:remove` — Remove legacy omnibus packages and directories (default)

## Properties

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `habitat_package` | String | `'chef/chef-infra-client'` | Habitat package identifier (not used directly by this resource). |
| `product_name` | String | `'chef-ice'` | Native OS package name to remove via the package manager. |
| `legacy_omnibus_package` | String | `'chef'` | Legacy omnibus package name to remove via the package manager. |
| `remove_directories` | true, false | `true` | Remove legacy omnibus installation directories after package uninstall. |

## Directories Removed

When `remove_directories` is `true`:

- **Linux/macOS:** `/opt/chef` and `/opt/chef-ice`
- **Windows:** `C:\opscode\chef`
- **macOS additional:** Forgets `com.chef.chef` and `com.chef.chef-ice` package receipts via `pkgutil`

## Examples

Remove all legacy omnibus installations and directories:

```ruby
chef_client_updater_enterprise_remove_omnibus 'default'
```

Remove packages but keep the installation directories:

```ruby
chef_client_updater_enterprise_remove_omnibus 'default' do
  remove_directories false
end
```
