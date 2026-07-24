
# chef_client_updater_enterprise_install

[back to resource list](../../README.md#resources)

Installs Chef Infra Client via `chef-ice` native OS packages using `mixlib-install`. Downloads the platform-appropriate package artifact, installs it through the native package manager, and optionally creates Habitat binlinks. The `mixlib-install` gem is installed at compile time via `chef_gem` inside the resource — it is not a metadata dependency.

A valid `license_key` is required. The resource raises `Chef::Exceptions::ConfigurationError` at converge time if the key is missing or blank.

Introduced: v0.1.0

## Actions

- `:install` — Install if no version is currently present (default)
- `:upgrade` — Always download and install, even if a version exists

## Properties

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `license_key` | String | `ENV['CHEF_LICENSE_KEY']` | Chef license key. **Sensitive** — value is masked in Chef logs. |
| `version` | String | `'latest'` | Version of Chef Infra Client to install. |
| `channel` | Symbol | `:stable` | Release channel (`:stable` or `:current`). |
| `habitat_package` | String | `'chef/chef-infra-client'` | Habitat package identifier for binlink operations. |
| `product_name` | String | `'chef-ice'` | Product name used by `mixlib-install` and the native OS package name. |
| `legacy_omnibus_package` | String | `'chef'` | Legacy omnibus package name used for detection. |
| `preserve_existing_versions` | true, false | `true` | When true, skip install if any version is already present. |
| `download_dir` | String | `Chef::Config[:file_cache_path]` | Directory to stage downloaded packages before install. |
| `timeout` | Integer | `900` | Timeout in seconds for package download and install operations. |
| `manage_binlinks` | true, false | `true` | Automatically run the binlinks resource after a successful install. |

## Examples

Install the latest stable version using an environment variable for the license key:

```ruby
chef_client_updater_enterprise_install 'default'
```

Install a specific version with an explicit license key:

```ruby
chef_client_updater_enterprise_install 'default' do
  version '18.5.0'
  license_key 'your-license-key-here'
end
```

Upgrade to the latest version from the current channel, skipping binlink management:

```ruby
chef_client_updater_enterprise_install 'default' do
  channel :current
  manage_binlinks false
  action :upgrade
end
```
