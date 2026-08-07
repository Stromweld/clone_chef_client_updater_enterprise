# chef_client_updater_enterprise cookbook

Installs and manages Chef Infra Client via `chef-ice` native OS packages resolved through [Chef's Commercial Download API](https://docs.chef.io/download/commercial/), creates [Habitat](https://www.habitat.sh/) binlinks for `chef/chef-infra-client`, and handles cleanup of legacy omnibus installations.

## Requirements

Chef Infra Client >= 17.0 (required for the `use` partial DSL).

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

`CHEF_LICENSE_KEY` must be exported wherever the converge actually runs `migrate-ice` (Test Kitchen
drivers, CI runners, production nodes) — the `install` resource's `license_key` property defaults
to reading it from the environment, and `migrate-ice apply airgap` fails without a valid key.

This downloads the latest stable `chef-ice` package, installs it via the native package manager
(rpm/deb/msi, preserving any previously installed `chef-ice` version and the legacy omnibus
install), and creates Habitat binlinks. The running `chef-client` process is **not** re-executed or
replaced — the new client takes effect on the next chef-client run. If the node has a
`chef_client_cron`/`chef_client_launchd`/`chef_client_systemd_timer`/`chef_client_scheduled_task`
schedule declared, the install resource repoints it at the newly installed client so that next
scheduled run picks it up.

To also clean up old versions and remove a legacy omnibus installation:

```ruby
chef_client_updater_enterprise_install 'default'

chef_client_updater_enterprise_cleanup 'default' do
  keep_versions 1
end

chef_client_updater_enterprise_remove_omnibus 'default'
```

See [documentation/resources/install.md](documentation/resources/install.md) for details on the multi-version preservation and scheduler reconvergence mechanisms.

## Testing

This cookbook uses Test Kitchen with Vagrant, Dokken, and live EC2 drivers:

```bash
# Vagrant (kitchen.yml)
kitchen converge

# Dokken (kitchen.dokken.yml)
KITCHEN_LOCAL_YAML=kitchen.dokken.yml kitchen converge

# Live EC2 (kitchen.ec2.yml) — required for platforms without a Vagrant/Dokken box,
# e.g. windows-2022 and rhel-9. Requires AWS credentials and a Chef license key.
KITCHEN_LOCAL_YAML=kitchen.ec2.yml CHEF_LICENSE_KEY=<your-license-key> kitchen converge
```

## License

Apache-2.0
