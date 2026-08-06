# chef_client_updater_enterprise CHANGELOG

This file is used to list changes made in each version of the chef_client_updater_enterprise cookbook.

## 0.2.0 (2026-08-06)

- removed use of mixlib-install
- package type is now derived from the download URL instead of the node's platform
- added derivitive platforms
- removed dead code and enabled linting for spec and test files
- various bug fixes

## 0.1.0 (2026-07-09)

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
