
# chef_client_updater_enterprise_install

[back to resource list](../../README.md#resources)

Installs Chef Infra Client via `chef-ice` native OS packages (rpm/deb/msi), resolving the
platform-appropriate package artifact through [Chef's Commercial Download
API](https://docs.chef.io/download/commercial/). No gem is installed at runtime and there are no
metadata dependencies — the lookup uses Chef's in-box `Chef::HTTP::Simple`, so it honors the same
proxy configuration as `remote_file`.

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
| `update_scheduler_resources` | true, false | `true` | When this converge actually installs a new chef-ice version, repoint any `chef_client_cron`/`chef_client_launchd`/`chef_client_systemd_timer`/`chef_client_scheduled_task` resources found in the resource collection at the just-installed client. Requires `manage_binlinks true` (or an externally managed, current binlink). See [Scheduler Resource Reconvergence](#scheduler-resource-reconvergence). |
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
  resource directly (bypassing `dnf`/`yum`) with `--replacefiles --noscripts --nodigest`.
  `--noscripts` suppresses the RPM's own `%post` scriptlet (which always runs `migrate-ice` without
  `--preserve-omnibus`); the resource then runs `migrate-ice` itself via an `execute` resource,
  passing `--preserve-omnibus` when requested. `--nodigest` is required because `chef-ice`'s RPMs
  lack a modern per-file payload digest, which rpm 4.x tolerates but rpm 6.x (Fedora 44) rejects
  outright; it disables only that specific check, not the SHA256 verification this resource
  performs on the download itself. Plain `rpm -i` never removes a different, already-installed
  NEVRA of the same package, so older versions' Habitat directories are left untouched.
- **Debian family (Ubuntu, Debian):** Drives `dpkg`'s two-phase lifecycle directly
  (`dpkg --unpack` then `dpkg --configure`), temporarily stubbing out `migrate-ice` (and, on
  upgrades, the previous package's `postrm`) between those two phases so the real `migrate-ice`
  binary can be invoked separately with `--preserve-omnibus`, avoiding both the destructive
  `postinst` migration and the previous version's `postrm` deleting the entire `/hab` tree during
  an upgrade transaction. The stub, `dpkg --configure` and restore steps run inside a single
  `ruby_block` with a `begin/ensure`, so a failed `dpkg --configure` cannot leave `migrate-ice`
  stubbed out on disk; a matching self-heal step reclaims a backup stranded by a harder failure
  (reboot, SIGKILL) before the next `dpkg --unpack`.
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

## Mounted `/opt/chef` and `--fstab`

`migrate-ice` has two distinct code paths, chosen automatically by this resource (see
`chef_client_on_path?` in `libraries/helpers.rb`):

- **fresh-install path** (`--fresh-install`, used when no `chef-client` resolves via `$PATH`) —
  extracts the airgap bundle unconditionally and never touches mounts.
- **migration path** (no `--fresh-install`, used when `chef-client` IS on `$PATH`) — additionally
  processes the `--fstab` flag.

On the migration path, `migrate-ice`'s own `--fstab` default is `apply`, which means "take the
block device currently mounted at `/opt/chef` and remount it at `/hab`". When `/opt/chef` is its
own mount point this does **not** degrade gracefully — it hard-fails the whole migration and rolls
back:

```text
[INFO] /opt/chef is mounted on device <dev>. Proceeding with migration.
Failure while processing flag `fstab`, Error: error during mount migration:
  failed to mount <dev> to /hab: exit status 32.
chef-client migration failed. ... Initiating rollback...
```

Because that is contradictory with `preserve_omnibus true` (keeping the omnibus install while
moving the filesystem out from under it), `fstab_handling` defaults to `ignore` whenever
`preserve_omnibus` is `true`, and only falls back to migrate-ice's own `apply` default when
`preserve_omnibus` is `false`. Set `fstab_handling` explicitly to override.

This is not a rare edge case: every `kitchen-dokken` container has `/opt/chef` bind-mounted in from
the `chef/chef` data container, and some sites deliberately keep `/opt/chef` on a dedicated
filesystem.

## Scheduler Resource Reconvergence

When `update_scheduler_resources` is `true` (the default) **and this converge actually installs a
new chef-ice version**, this resource finds any
`chef_client_cron`/`chef_client_launchd`/`chef_client_systemd_timer`/`chef_client_scheduled_task`
resources already declared in the run's resource collection, explicitly sets their
`chef_binary_path` property, and re-runs each one's own previously-declared action(s) in place — no
process handoff (re-exec or exit) of any kind is involved, on any platform.

The sole purpose is to point an existing schedule at the newly-installed client so its next
*scheduled* run uses it.

`chef_binary_path` is set to the **fully-versioned Habitat path** (for example
`/hab/pkgs/chef/chef-infra-client/19.3.15/20260601120000/bin/chef-client`), not the
`/usr/bin/chef-client` binlink. The scheduler resources re-resolve `chef_binary_path` at every
scheduled invocation, running as root/SYSTEM, so a writable well-known symlink there would be a
standing local privilege-escalation target between chef-client runs. If `version` is pinned, the
pinned version is resolved rather than simply the newest one present on disk, so an intentional
rollback is not silently undone.

The property is set explicitly rather than left to whatever default the resource would otherwise
compute: the chef-client actually bootstrapping the converge may be an older release (e.g. the
`stable` channel's 18.11.11) whose `chef_binary_path` default is a plain, non-lazy, hardcoded
legacy path — not the hab-aware lazy default newer Chef Infra Client releases have — so there is no
default behavior this cookbook can safely rely on to self-correct.

### What triggers it

Reconvergence runs from a `ruby_block` declared `action :nothing`, driven by **delayed notifications
from whichever resource actually installed or upgraded chef-ice in this converge**:

- On Linux, `execute[migrate-ice apply airgap]` — the step that populates `/hab/pkgs`. It carries a
  `not_if` which is satisfied once the target version is already present, so on a steady-state
  converge it does not run, does not notify, and no schedule is rewritten.
- On Windows, the `windows_package` resource. `execute[migrate-ice apply airgap]` is guarded on a
  Linux-only path and never runs there — the MSI's own embedded `PostInstall.ps1` custom action
  invokes migrate-ice inside the msiexec transaction instead. `windows_package`'s registry-based
  idempotency means it only notifies on a real install.
- On any other platform, the generic `package` fallback, for the same reason.

Chef de-duplicates delayed notifications by resource and action, so a platform where more than one
of these fires still reconverges exactly once.

That gating is deliberate in both directions:

- It scopes the feature to what it is for. This is not a general-purpose repair mechanism for a
  `chef_binary_path` that drifted for some unrelated reason; nothing re-asserts the path on
  converges where nothing was installed.
- It preserves idempotency. `ruby_block` reports "updated" whenever its block runs, so running it
  unconditionally would report a changed resource on every converge forever.

The one other entry point is `action :install`'s early return for an explicitly pinned version that
is already installed, which performs the same reconvergence directly in Ruby (it returns before the
`ruby_block` is ever declared).

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
  version '19.2.12'
  manage_binlinks false
  update_scheduler_resources false
end

chef_client_updater_enterprise_install 'install latest'
```
