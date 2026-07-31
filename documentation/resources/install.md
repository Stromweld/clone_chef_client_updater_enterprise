
# chef_client_updater_enterprise_install

[back to resource list](../../README.md#resources)

Installs Chef Infra Client via `chef-ice` native OS packages (rpm/deb/msi), using `mixlib-install`
to resolve and download the platform-appropriate package artifact. The `mixlib-install` gem is
installed at compile time via `chef_gem` inside the resource — it is not a metadata dependency.

Side-by-side, multi-version installs are supported on every platform (RPM, deb, and MSI) while
preserving any existing legacy omnibus Chef installation, and installing a newer `chef-ice` version
never removes an older one that is still on disk (each version's Habitat-managed payload lives
under its own versioned path). See "Preserving Multiple Installed Versions" below for how each
package manager's destructive default behavior is bypassed.

A valid `license_key` is required whenever `download_url` is not set. The resource raises
`Chef::Exceptions::ConfigurationError` at converge time if the key is missing or blank.

Introduced: v0.1.0

## Actions

- `:install` — Install the requested version if it is not already present (default). When
  `version` is `'latest'`, the resolved artifact is always installed since the actual latest
  version isn't known ahead of time; when a specific `version` is given, the resource is a no-op
  if that exact version is already installed (native package or Habitat).

## Properties

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `license_key` | String | `ENV['CHEF_LICENSE_KEY']` | Chef license key. **Sensitive** — value is masked in Chef logs. Required unless `download_url` is set. |
| `version` | String | `'latest'` | Version of Chef Infra Client to install. `'latest'` resolves to the latest stable/current release via `mixlib-install`. |
| `channel` | Symbol | `:stable` | Release channel (`:stable` or `:current`). |
| `habitat_package` | String | `'chef/chef-infra-client'` | Habitat package identifier used by the binlinks/reconvergence logic. |
| `product_name` | String | `'chef-ice'` | Product name used by `mixlib-install` and the native OS package name (rpm/deb/msi). |
| `legacy_omnibus_package` | String | `'chef'` | Legacy omnibus package name used for install-time detection (not removed by this resource — see `chef_client_updater_enterprise_remove_omnibus`). |
| `download_dir` | String | `Chef::Config[:file_cache_path]` | Directory to stage downloaded packages before install. |
| `download_url` | String | | Direct package URL, bypassing `mixlib-install` entirely. Use for airgapped environments or local file servers. When set, `license_key` is not required. |
| `checksum` | String | | SHA256 checksum for the direct `download_url` package. Ignored when using `mixlib-install`. |
| `manage_binlinks` | true, false | `true` | Automatically run `chef_client_updater_enterprise_binlinks` after a successful install. |
| `update_scheduler_resources` | true, false | `true` | Reconverges any `chef_client_cron`/`chef_client_launchd`/`chef_client_systemd_timer`/`chef_client_scheduled_task` resources found in the resource collection whenever the binlinked package version changes — the initial omnibus migration AND every later chef-ice version upgrade. Requires `manage_binlinks true` (or an externally managed, current binlink). |
| `preserve_omnibus` | true, false | `true` | Pass `--preserve-omnibus` to `migrate-ice` so an existing legacy omnibus Chef installation is left in place instead of being deleted. |

## Preserving Multiple Installed Versions

Every `chef-ice` package (rpm, deb, and MSI) bundles a `migrate-ice` tool that unconditionally runs
as part of the native package manager's own install transaction, with no supported flag to skip
`--preserve-omnibus` or avoid deleting a previously installed version's files. This resource works
around each package manager's specific behavior so that:

- The currently-running `chef-client` process (which may itself be executing out of an older
  version's installed path) is never interrupted mid-converge.
- The legacy omnibus Chef installation is preserved when `preserve_omnibus` is `true`.
- Multiple `chef-ice` versions can coexist on disk (Habitat manages the versioned payload;
  only the native package manager's single "installed version" pointer changes).

Platform-specific handling:

- **RHEL family (RHEL, Amazon Linux, Fedora, SLES/SUSE):** Installs via Chef's `rpm_package`
  resource directly (bypassing `dnf`/`yum`) with `--replacefiles --noscripts`. `--noscripts`
  suppresses the RPM's own `%post` scriptlet (which always runs `migrate-ice` without
  `--preserve-omnibus`); the resource then runs `migrate-ice` itself via an `execute` resource,
  passing `--preserve-omnibus` when requested. Plain `rpm -i` never removes a different,
  already-installed NEVRA of the same package, so older versions' Habitat directories are left
  untouched.
- **Debian family (Ubuntu, Debian):** Drives `dpkg`'s two-phase lifecycle directly
  (`dpkg --unpack` then `dpkg --configure`), temporarily stubbing out `migrate-ice` (and, on
  upgrades, the previous package's `postrm`) between those two phases so the real `migrate-ice`
  binary can be invoked separately with `--preserve-omnibus`, avoiding both the destructive
  `postinst` migration and the previous version's `postrm` deleting the entire `/hab` tree during
  an upgrade transaction.
- **Windows:** Installs via Chef's `windows_package` resource (`installer_type :msi`). Since each
  `chef-ice` release uses a distinct MSI `ProductCode`/`UpgradeCode`, side-by-side installs of
  different versions are already safe natively — no `dnf`/`yum`-style obsoletes handling to work
  around. Sets the `CHEF_PRESERVE_OMNIBUS=1` MSI property (via `options`) when `preserve_omnibus`
  is `true`, which the package's embedded `PostInstall.ps1` custom action forwards to
  `migrate-ice --preserve-omnibus`. Note: this MSI property only exists on `chef-ice` releases
  built on/after ~2026-04-23; older releases always migrate destructively regardless of this
  setting. The MSI install can legitimately take 7-13 minutes (the `timeout` property defaults to
  `1800` seconds to accommodate this).
- **All other platforms (e.g. macOS):** Installs via Chef's built-in `package` resource with no
  special-casing.

## Scheduler Resource Reconvergence

When `update_scheduler_resources` is `true` (the default), this resource finds any
`chef_client_cron`/`chef_client_launchd`/`chef_client_systemd_timer`/`chef_client_scheduled_task`
resources already declared in the run_list's resource collection, explicitly sets their
`chef_binary_path` property to the resolved stable binlink path, and re-runs each one's own
previously-declared action(s) in place — no process handoff (re-exec or exit) of any kind is
involved, on any platform. The property is set explicitly rather than left to whatever default the
resource would otherwise compute: the chef-client actually bootstrapping the converge may be an
older release (e.g. the `stable` channel's 18.11.11) whose `chef_binary_path` default is a plain,
non-lazy, hardcoded legacy path — not the hab-aware lazy default newer Chef Infra Client releases
have — so there is no default behavior this cookbook can safely rely on to self-correct. See
AGENTS.md's "Scheduler Resource Reconvergence" section for the full rationale, including why this
replaced an earlier Kernel.exec(Linux/macOS)/exit(213)(Windows) process handoff mechanism.

The reconvergence is triggered by a `:immediately` notification from the platform-specific
package-install resource in `action :install` (`rpm_package`/the `dpkg --configure` `execute`/
`windows_package`/the generic `package` fallback) — each of these is properly idempotent and only
reports a change when chef-ice was actually installed/upgraded in that converge. It is **not**
triggered by `chef_client_updater_enterprise_binlinks` (even though that resource also carries the
same notification as a harmless redundant backup): `migrate-ice apply airgap` already creates the
binlink symlink as a side effect of every install, so `binlinks`' own idempotency check is
satisfied immediately and it never reports a change — wiring the primary notification there would
silently make the reconvergence permanent dead code (confirmed live via `scheduler-fix` Test
Kitchen failures before this was fixed).

The reconvergence fires on **every** successful install/upgrade that changes chef-ice — not just
the initial omnibus-to-chef-ice migration — as long as `update_scheduler_resources` is `true`
(default).

This works regardless of whether the scheduler resource is declared before or after this resource
in the run_list: Chef fully compiles the resource collection for the entire run_list before
convergence begins, so the scheduler resource is always already present by the time the
reconvergence runs. It also keeps `chef_client_cron`/`chef_client_launchd`/
`chef_client_systemd_timer`/`chef_client_scheduled_task`'s `chef_binary_path` in sync with
`chef_client_updater_enterprise_cleanup`'s protection of the currently running version (see
AGENTS.md for the full rationale and the failure mode this prevents).

Set `update_scheduler_resources false` if an external mechanism already keeps those resources'
`chef_binary_path` current, or if you want to defer reconvergence to a later, explicit step.

## Examples

Install the latest stable version using an environment variable for the license key:

```ruby
chef_client_updater_enterprise_install 'default'
```

Install a specific version with an explicit license key:

```ruby
chef_client_updater_enterprise_install 'default' do
  version '19.3.15'
  license_key 'your-license-key-here'
end
```

Install from the current (unstable) channel without managing binlinks or scheduler reconvergence:

```ruby
chef_client_updater_enterprise_install 'default' do
  channel :current
  manage_binlinks false
  update_scheduler_resources false
end
```

Install multiple versions side-by-side without triggering binlink/reconvergence until the last one
(used by this cookbook's own multi-version integration tests):

```ruby
chef_client_updater_enterprise_install 'install older version' do
  version '19.2.12'
  manage_binlinks false
  update_scheduler_resources false
  license_key node['chef_client_updater_enterprise']['license_key']
end

chef_client_updater_enterprise_install 'install latest' do
  license_key node['chef_client_updater_enterprise']['license_key']
end
```
