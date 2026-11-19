
# chef_client_updater_enterprise_install

[back to resource list](../../README.md#resources)

Installs Chef Infra Client via `chef-ice` native OS packages (rpm/deb/dmg/msi), resolving the
platform-appropriate package artifact through [Chef's Commercial Download
API](https://docs.chef.io/download/commercial/). No gem is installed at runtime and there are no
metadata dependencies — the lookup uses Chef's in-box `Chef::HTTP::Simple`, so it honors the same
proxy configuration as `remote_file`.

Side-by-side, multi-version installs are supported on every platform (RPM, deb, and MSI) while
preserving any existing legacy omnibus Chef installation, and installing a newer `chef-ice` version
never removes an older one that is still on disk (each version's Habitat-managed payload lives
under its own versioned path). See "Preserving Multiple Installed Versions" below for how each
each platform is installed.

Only chef-ice releases **newer than 19.4.50** are supported; older releases raise
`Chef::Exceptions::ValidationFailed` before anything is installed. With `download_url` and
`version 'latest'` the version is unknown and the check is skipped. On macOS, `download_url`
requires an explicit `version`.

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
| `license_key` | String, nil | `ENV['CHEF_LICENSE_KEY']` | Chef license key. **Sensitive** — value is masked in Chef logs and in reported resource state. Required unless `download_url` is set. |
| `version` | String | `'latest'` | Version of Chef Infra Client to install. `'latest'` (accepted in any casing and normalized to lowercase) is resolved server-side by the Commercial Download API. |
| `channel` | String, Symbol | `:stable` | Release channel (`:stable` or `:current`). Accepts a String in any casing and coerces it to a Symbol, so `channel 'stable'` and `channel :stable` are equivalent. |
| `habitat_package` | String | `'chef/chef-infra-client'` | Habitat package identifier used by the binlinks/reconvergence logic. Must be a bare `origin/name` ident. |
| `product_name` | String | `'chef-ice'` | [Commercial Download API product key](https://docs.chef.io/download/commercial/#chef-product-names) and the native OS package name (rpm/deb/msi). |
| `download_dir` | String | `Chef::Config[:file_cache_path]` | Directory to stage downloaded packages before install. |
| `download_url` | String | | Direct package URL, bypassing the Commercial Download API entirely. Use for airgapped environments or local file servers. When set, `license_key` is not required. Its path must end in `.rpm`, `.deb`, `.msi`, `.dmg` or `.pkg` — see [Package type is derived from the URL](#package-type-is-derived-from-the-url). |
| `checksum` | String | | SHA256 checksum for the direct `download_url` package. Ignored when resolving via the Commercial Download API, which supplies its own sha256. |
| `download_retries` | Integer | `5` | Times to retry the package download. Must be `0` or greater. See [CDN propagation delay](#cdn-propagation-delay-and-download-verification). |
| `download_retry_delay` | Integer | `30` | Seconds between package download attempts. Must be `0` or greater. See [CDN propagation delay](#cdn-propagation-delay-and-download-verification). |
| `manage_binlinks` | true, false | `true` | Automatically run `chef_client_updater_enterprise_binlinks` after a successful install. |
| `update_scheduler_resources` | true, false | `true` | When this converge actually installs a new chef-ice version, declare and run `chef_client_updater_enterprise_scheduler_reconvergence` to repoint any `chef_client_cron`/`chef_client_launchd`/`chef_client_systemd_timer`/`chef_client_scheduled_task` resources found in the resource collection at the just-installed client. Requires `manage_binlinks true` (or an externally managed, current binlink). See [Scheduler Resource Reconvergence](#scheduler-resource-reconvergence). |
| `preserve_omnibus` | true, false | `true` | Pass `--preserve-omnibus` to `migrate-ice` so an existing legacy omnibus Chef installation is left in place instead of being deleted. |
| `fstab_handling` | `apply`, `fail`, `ignore` | `ignore` when `preserve_omnibus` is `true`, otherwise `apply` | Value passed to `migrate-ice --fstab` on the migration code path, controlling what it does when `/opt/chef` is its own dedicated mount point: `apply` (migrate-ice's default) remounts that device at `/hab`, `fail` aborts, `ignore` leaves the mount alone. See [Mounted `/opt/chef` and `--fstab`](#mounted-optchef-and---fstab). |

## Package type is derived from the URL

The package format (`rpm`, `deb`, `msi`, `dmg`, `pkg`) is taken from the file extension of the URL
the artifact is actually fetched from, and is used to name the staged file under `download_dir`. It
is **not** guessed from the node's platform, so the staged filename can never disagree with the file
that was downloaded.

Both code paths always have a full file URL to work from:

- The Commercial Download API is queried with `direct=true`, so it returns the `/files/…` URL ending
  in the real artifact filename rather than its `/download` handler URL.
- A user-supplied `download_url` points at a package file on a local mirror or file server.

Query strings and fragments are ignored, so presigned or license-bearing URLs
(`…/chef-ice_19.3.15-1_amd64.deb?license_id=…`) work unchanged.

If the URL's path does not end in one of the extensions above, the resource raises
`Chef::Exceptions::ValidationFailed` rather than guessing. The most common cause is a `download_url`
pointing at a redirect or handler endpoint instead of the package file itself:

```text
chef_client_updater_enterprise_install: could not determine a package type from
https://example.com/stable/chef-ice/download — the URL's path must end in one of
.rpm, .deb, .msi, .dmg, .pkg.
```

## CDN propagation delay and download verification

The Commercial Download API advertises a release as soon as it is published, but the artifact
itself still has to propagate to the caller's nearest CDN edge. Until it gets there, that edge can
answer with a `403`/`404`, or serve a short error body with a `200`. This is most noticeable for
the Windows MSI, and it means a converge started shortly after a release can fail on a version the
API says exists.

Two things guard against that:

- **Retries.** The download is retried `download_retries` times, `download_retry_delay` seconds
  apart (default: 5 attempts, 30s apart). Raise either if your edge routinely needs longer:

  ```ruby
  chef_client_updater_enterprise_install 'chef-ice' do
    download_retries 10
    download_retry_delay 60
  end
  ```

- **Real checksum verification.** `remote_file`'s own `checksum` property does *not* verify a
  download — it only compares an already-present local file to decide whether to skip fetching.
  This resource additionally attaches a `verify` block that hashes the freshly-staged download and
  compares it to the sha256 the API advertised, so a truncated transfer or a CDN error page is
  rejected and retried rather than handed to `rpm`/`dpkg`/`msiexec` as a "package".

Verification runs before the staged file is moved into place, so a rejected body never becomes the
cached artifact, and each retry re-downloads in full.

## Preserving Multiple Installed Versions

Each platform's native installer runs `migrate-ice` itself and honors the settings this resource
passes, so a newer `chef-ice` never removes an older version's Habitat directory, and the legacy
omnibus install is kept when `preserve_omnibus` is `true`.

- **RHEL/SUSE family:** `rpm_package` from the downloaded file. chef-ice's `%preun` only acts on a
  full erase, so an upgrade leaves the previous version under `/hab/pkgs`.
- **Debian family:** `dpkg_package` from the downloaded file.
- **macOS:** `dmg_package` with `type 'pkg'`, mounting the volume `Chef Infra Client <version>`.
- **Windows:** `windows_package` (`installer_type :msi`, `timeout 1800`, since installs take 7-13
  minutes). All chef-ice MSIs share one `UpgradeCode`, so the new MSI replaces the old one in Programs
  and Features; the old Habitat release stays under `C:\hab\pkgs` until `cleanup` removes it. `TARGETDIR=C:\` is
  always passed so the payload lands under `C:\hab`.

Each package resource is skipped when the target version is already present under `/hab/pkgs`.

## Incomplete releases and recovery

A Habitat release counts as installed only when its directory holds a regular (non-symlink)
`IDENT` file. When the target version is known, a guard after the package step fails the converge
if no such release of that version exists. If the package manager already records the target
version but the release is incomplete (an interrupted migration), the next converge repairs it:

- **RPM:** `rpm -U --replacepkgs` of the same file re-runs `%post`.
- **DEB:** `dpkg -i` of the same `.deb` re-runs `postinst`.
- **macOS:** `dmg_package` reinstalls the `.pkg`.
- **Windows:** `windows_package` skips the registered MSI, so a guarded `execute` runs
  `msiexec /i "<msi>" REINSTALL=ALL REINSTALLMODE=vamus` with the same properties as the install
  (`TARGETDIR=C:\`, `CHEF_SKIP_OLD_RELEASE_REMOVAL=1`, and `CHEF_PRESERVE_OMNIBUS=1` /
  `CHEF_SKIP_BINLINKING=1` when they apply), logging to `<download_dir>\<product>-<version>-repair.log`.
  Exit codes 0 and 3010 (success, reboot required) are accepted.

Windows Installer accepts this maintenance install only from a package with the file name it
recorded when the product was installed (its `PackageName`). Any other name failed with 1603
(`SECREPAIR: Error determining package source type`), and repairing by ProductCode alone failed
with 1706 once the original MSI was gone. The resource therefore asks Windows Installer for that
name and, when it differs from the downloaded file, copies the downloaded MSI to that name in the
same directory before running `msiexec`. This was tested with chef-ice installed from a differently
named MSI that was then deleted, with `manage_binlinks` true and false.

To repair by hand, from an elevated prompt, use an MSI of the same version named exactly as the
recorded `PackageName`:

```powershell
msiexec /i "C:\path\to\<recorded PackageName>.msi" REINSTALL=ALL REINSTALLMODE=vamus TARGETDIR=C:\ CHEF_PRESERVE_OMNIBUS=1 CHEF_SKIP_OLD_RELEASE_REMOVAL=1 CHEF_SKIP_BINLINKING=1 /qn /norestart /l*v C:\chef-ice-repair.log
```

Omit `CHEF_SKIP_BINLINKING=1` if the repaired version should also become the active binlink. Do **not**
use `msiexec /fa`: in testing, the properties never reached the installer, so migrate-ice removed
the older releases under `C:\hab\pkgs`. Do not create an empty `IDENT` file; that
hides an incomplete release.

Known risk: chef-ice MSIs built before the old-release-removal fix delete older releases on upgrade
even when `CHEF_SKIP_OLD_RELEASE_REMOVAL=1` is passed.

## Installer settings

- **Linux/macOS:** written to `/tmp/chef_env` (root-owned, mode 0600, contents never logged) just
  before the package installs: `CHEF_PRESERVE_OMNIBUS`, `CHEF_SKIP_BINLINKING`,
  `CHEF_SKIP_OLD_RELEASE_REMOVAL`, `CHEF_FSTAB` (not on macOS) and `CHEF_LICENSE_KEY`. The installer reads and deletes it; this resource also deletes it at
  the end of its action. If the converge fails after the file is written but before the installer
  runs, it is left behind until the next install.
- **Windows:** MSI properties `TARGETDIR=C:\`, `CHEF_PRESERVE_OMNIBUS=1`, `CHEF_SKIP_BINLINKING=1` and
  `CHEF_SKIP_OLD_RELEASE_REMOVAL=1`; the license key
  is set as a Machine environment variable only for the install, then removed.

`CHEF_SKIP_OLD_RELEASE_REMOVAL` is always sent, so the installer keeps older releases and removal
is left to `chef_client_updater_enterprise_cleanup`.

`manage_binlinks false` tells the installer to skip binlinking and does not declare
`chef_client_updater_enterprise_binlinks`.

`preserve_omnibus false` is ignored, with a warning, while chef-client itself runs from the omnibus
install; use `chef_client_updater_enterprise_remove_omnibus` on a later run.

`fstab_handling` (`CHEF_FSTAB`) defaults to `ignore` when `preserve_omnibus` is `true`. migrate-ice's
own default, `apply`, remounts a device mounted at `/opt/chef` onto `/hab`, which hard-fails where
`/opt/chef` is its own mount point (every `kitchen-dokken` container) and contradicts preserving the
omnibus install.

## Scheduler Resource Reconvergence

When `update_scheduler_resources` is `true` (the default) **and this converge actually installs a
new chef-ice version**, this resource declares and runs
`chef_client_updater_enterprise_scheduler_reconvergence`, passing along its own `habitat_package`
and `version`. That resource finds any
`chef_client_cron`/`chef_client_launchd`/`chef_client_systemd_timer`/`chef_client_scheduled_task`
resources already declared in the run's resource collection, explicitly sets their
`chef_binary_path` property, and re-runs each one's own previously-declared action(s) in place — no
process handoff (re-exec or exit) of any kind is involved, on any platform. See
[`chef_client_updater_enterprise_scheduler_reconvergence`](scheduler_reconvergence.md) for the full
mechanism and rationale.

The sole purpose is to point an existing schedule at the newly-installed client so its next
*scheduled* run uses it.

### What triggers it

Reconvergence is driven by **delayed notifications from the native package resource** (`rpm_package`,
`dpkg_package`, `dmg_package` or `windows_package`). It is skipped when the target version is
already present, so on a steady-state converge nothing installs, notifies, or rewrites a schedule.

That gating is deliberate in both directions:

- It scopes the feature to what it is for. This is not a general-purpose repair mechanism for a
  `chef_binary_path` that drifted for some unrelated reason; nothing re-asserts the path on
  converges where nothing was installed.
- It preserves idempotency. Reconvergence re-runs the scheduler resources' actions, so running it
  unconditionally could report changed resources on every converge.

`action :install` returns early, before any of this is declared, when an explicitly pinned version
is already installed; nothing is reconverged on that path.

The delayed notification is registered in this resource's own child `RunContext`, so it is drained
at the end of *this resource's* action rather than at the end of the whole chef-client run. That
ordering matters: reconvergence always completes before a separately declared
`chef_client_updater_enterprise_cleanup` could prune an old version.

This works regardless of whether the scheduler resource is declared before or after this resource
in the run_list: Chef fully compiles the resource collection for the entire run_list before
convergence begins, so the scheduler resource is always already present by the time the
reconvergence runs.

Set `update_scheduler_resources false` if an external mechanism already keeps those resources'
`chef_binary_path` current, or if you want to defer reconvergence to a later, explicit step. Be
aware that with it disabled, a scheduler resource declared before chef-ice is installed bakes in
whatever path its own default produced.

See AGENTS.md's "Scheduler Resource Reconvergence" section for the full rationale, including why
this replaced an earlier `Kernel.exec` (Linux/macOS) / `exit(213)` (Windows) process handoff.

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
(this is the shape used by this cookbook's own multi-version integration tests, where
`license_key` is supplied by the wrapper cookbook; the resource itself defaults it to
`ENV['CHEF_LICENSE_KEY']` and this cookbook exposes no node attributes of its own):

```ruby
chef_client_updater_enterprise_install 'install older version' do
  version '19.4.56'
  manage_binlinks false
  update_scheduler_resources false
end

chef_client_updater_enterprise_install 'install latest'
```
