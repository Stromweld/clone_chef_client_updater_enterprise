# chef_client_updater_enterprise cookbook

Installs and manages Chef Infra Client via `chef-ice` native OS packages using [mixlib-install](https://github.com/chef/mixlib-install), creates [Habitat](https://www.habitat.sh/) binlinks for `chef/chef-infra-client`, and handles cleanup of legacy omnibus installations.

## Requirements

Chef Infra Client >= 17.0 (required for the `use` partial DSL).

### Platforms

- RHEL 7, 8, 9 (CentOS, AlmaLinux, Red Hat Enterprise Linux)
- Ubuntu 18.04, 22.04, 24.04
- SLES 15 SP5, SP6 (openSUSE Leap 15)

### Dependencies

This cookbook has no external cookbook dependencies. The `mixlib-install` gem is installed at runtime via `chef_gem` inside the install resource.

## Resources

- [chef_client_updater_enterprise_install](documentation/resources/install.md)
- [chef_client_updater_enterprise_binlinks](documentation/resources/binlinks.md)
- [chef_client_updater_enterprise_cleanup](documentation/resources/cleanup.md)
- [chef_client_updater_enterprise_remove_omnibus](documentation/resources/remove_omnibus.md)

## Usage

Set the `CHEF_LICENSE_KEY` environment variable on your nodes, then use the install resource:

```ruby
chef_client_updater_enterprise_install 'default'
```

This downloads the latest stable `chef-ice` package, installs it via the native package manager, and creates Habitat binlinks. To also clean up old versions and remove a legacy omnibus installation:

```ruby
chef_client_updater_enterprise_install 'default'

chef_client_updater_enterprise_cleanup 'default' do
  keep_versions 1
end

chef_client_updater_enterprise_remove_omnibus 'default'
```

## Testing

This cookbook uses Test Kitchen with both Vagrant and Dokken drivers:

```bash
# Vagrant (kitchen.yml)
kitchen converge

# Dokken (kitchen.dokken.yml)
KITCHEN_LOCAL_YAML=kitchen.dokken.yml kitchen converge
```

## License

Apache-2.0
