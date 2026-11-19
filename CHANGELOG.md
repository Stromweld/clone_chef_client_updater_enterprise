# chef_client_updater_enterprise CHANGELOG

This file is used to list changes made in each version of the chef_client_updater_enterprise cookbook.

## Unreleased

- install: hand chef-ice (releases newer than 19.4.50) to the native installer (`rpm_package`,
  `dpkg_package`, `dmg_package`, `windows_package`), which runs migrate-ice itself
- install: pass installer settings via `/tmp/chef_env` (Linux/macOS) or MSI properties (Windows);
  `manage_binlinks false` sends `CHEF_SKIP_BINLINKING`, and `CHEF_SKIP_OLD_RELEASE_REMOVAL` is always
  sent so `cleanup` owns old-release removal
- install: a release counts only with a regular (non-symlink) `IDENT`; the early return requires a
  complete release, and the converge fails if the target release is missing after install
- install: repair a registered-but-incomplete release automatically on RPM (`rpm -U --replacepkgs`),
  DEB (`dpkg -i`), macOS and Windows (`msiexec /i … REINSTALL=ALL REINSTALLMODE=vamus` from the
  downloaded MSI, copied first to the file name Windows Installer recorded at install time)
- remove_omnibus: empty `/opt/chef` instead of deleting it when it is a mount point

## 0.3.0 (2026-08-17)

- added scheduler_reconvergence resource
- code cleanup/simplification

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
