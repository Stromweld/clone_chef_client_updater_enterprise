# chef_client_updater_enterprise CHANGELOG

This file is used to list changes made in each version of the chef_client_updater_enterprise cookbook.

## Unreleased

### Fixed

- `install.rb`: replace `hab_pkg_dirs`-based migration guard with bundle-existence guard; migration is now idempotent — runs only while the bundle file exists on disk
- `cleanup.rb`: revert package removal from `directory :delete` to `habitat_package :remove`; remove redundant ident split
- `binlinks.rb`: raise `Chef::Exceptions::ValidationFailed` when requested version is not found in the Habitat package store; remove unused `hab_pkg` local
- `remove_omnibus.rb`: gate omnibus directory deletion on hab binlink existence (`/usr/bin/chef-client` or `/usr/local/bin/chef-client`) so `/opt/chef` is never removed before the replacement binary is in place
- `preserve-omnibus` InSpec: remove hard assertion that `/opt/chef` exists post-migration (migrate-ice controls this); verify `/etc/chef` config preservation instead

## 0.1.0 - *2026-07-09*

### Added

- Initial release with resource-driven architecture (no recipes or attributes)
- `chef_client_updater_enterprise_install` resource — installs Chef Infra Client via `chef-ice` native OS packages using `mixlib-install`
- `chef_client_updater_enterprise_binlinks` resource — manages Habitat binlinks for `chef/chef-infra-client`
- `chef_client_updater_enterprise_cleanup` resource — prunes old Habitat package versions
- `chef_client_updater_enterprise_remove_omnibus` resource — removes legacy omnibus Chef installations (`chef` and `chef-ice` packages, directories, and macOS receipts)
- Shared resource partials: `_license`, `_version_channel`, `_pkg_names`
- Helper library with `hab_binary` detection and version queries
- Test Kitchen configurations for Vagrant (`kitchen.yml`) and Dokken (`kitchen.dokken.yml`)
- Documentation for all resources in `documentation/resources/`
- AGENTS.md with durable architectural decisions
