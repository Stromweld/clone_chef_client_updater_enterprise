# AGENTS.md

## Purpose

Durable maintainer/agent decisions for the `chef_client_updater_enterprise` cookbook: non-obvious
implementation choices and the "do not do X because Y" rules behind them. Not a changelog.

## Architecture

Resource-driven only — no `recipes/` or `attributes/`. Four resources (`install`, `binlinks`,
`cleanup`, `remove_omnibus`) plus `libraries/helpers.rb`. Defaults live on resource properties,
`lazy` blocks, or helpers. Do not reintroduce `node['chef_client_updater_enterprise']` as an API.

**Partials.** Chef's `use` auto-prepends an underscore, so the single file `resources/_partials.rb`
is referenced as `use 'partials'` (`use '_partials'` would look for `__partials.rb`). Every resource
opens with that line. It holds only the two genuinely shared properties:

- `habitat_package` — `regex`-constrained to a bare `origin/name` ident. `cleanup.rb` must still
  shell-escape it; the regex is an early, actionable error, not the security control.
- `version` — `coerce`d so any casing of `latest` normalizes to lowercase. `install.rb`,
  `binlinks.rb` and `Helpers#chef_client_hab_binary_path` all compare against that literal. Before
  the coerce they disagreed (`== 'latest'` vs `.downcase`), so `version 'Latest'` meant "pinned
  version named Latest" to one resource and "newest installed" to another. Do not remove the coerce
  or reintroduce ad-hoc `.downcase` at comparison sites.

Do not split this into more partials unless a property is actually shared by multiple resources.
`use` requires Chef >= 17.0, enforced by `chef_version '>= 17.0'` in `metadata.rb`.

**`unified_mode true`** on all four resources keeps resources declared inside `action_class` methods
converging in the right order. Do not remove it.

**`desired_state: false`** marks properties describing *how* to reach state (credentials, download
tuning, toggles), keeping them out of resource reporting and why-run: `license_key`, `download_dir`,
`download_url`, `checksum`, `download_retries`, `download_retry_delay`, `manage_binlinks`,
`update_scheduler_resources`, `preserve_omnibus`, `fstab_handling` (install); `force` (binlinks);
`remove_directories` (remove_omnibus). Properties describing *what* the system should look like keep
the default `true`: `product_name`, `channel`, `version`, `habitat_package`,
`legacy_omnibus_package`, `keep_versions`. `spec/unit/resources/install_spec.rb` pins the split.

## Package Identity

Two identities; mixing them breaks installs.

- **`chef-ice`** — `install`'s `product_name`. Simultaneously the Commercial Download API product
  key and the native OS package name (rpm/deb/msi). Used only by `install`.
- **`chef/chef-infra-client`** — the Habitat ident (`habitat_package`). Used by `binlinks` for
  `hab pkg binlink`, and by `cleanup` (filesystem glob under `/hab/pkgs/` to list, `hab pkg
  uninstall` to remove).

Never use `chef/chef-ice` as a Habitat ident, or `chef/chef-infra-client` as an API product key.
`remove_omnibus` touches neither — it acts on its own `legacy_omnibus_package` (default `chef`).

## Dependencies

No runtime gem dependencies and no metadata `depends` entries. Do not reintroduce `mixlib-install`
as a metadata dep, a Gemfile entry, or a vendored `files/default/*.gem` installed via `chef_gem` —
that compile-time gem install is what made every Kitchen suite non-idempotent on its first run under
a freshly installed chef-ice. Use `Policyfile.rb`; do not reintroduce Berkshelf.

## Commercial Download API

`Helpers#commercial_artifact_metadata` does one GET against
`https://chefdownload-commercial.chef.io/<channel>/<product>/metadata` and returns the only three
values needed: `url`, `sha256`, resolved `version`. See <https://docs.chef.io/download/commercial/>.

**`direct=true` is required, not cosmetic.** Without it the API returns its `/download` handler URL,
whose path carries no package extension; `install` derives package type from that path and
hard-fails on a URL it cannot derive one from. With it, the `/files/...` URL ends in the real
`.rpm`/`.deb`/`.msi` filename and the advertised sha256 matches the body byte-for-byte.

**`pv` is discarded server-side** — `DynamoServices#ProductMetadata` blanks `PlatformVersion` before
the DB lookup. Verified live: for `p=el`, omitting `pv` or sending `9`, `9.4`, `7`, `99` or
`garbage` all return the same artifact. It is still sent because the API documents it, but
`Helpers#download_api_platform_info` passes Ohai's raw `platform_version` through untouched. Do not
reintroduce derivation logic (major-version truncation, `amazon 2` → `el 7`) — it cannot change the
response. chef-ice publishes one artifact per platform-family/architecture, so there is no
compatibility fallback either.

**`pm` is deliberately not sent.** It is optional and omnitruck-service derives the package format
from `p`. A locally-guessed `pm` can only agree redundantly or disagree harmfully.

**Platform aliases exist only because the API rejects unknown names.** omnitruck-service maps `p`
via `clients/omnitruck/package_manager_mapping.go`; a missing name returns
`HTTP 400 {"message":"Unable to derive package manager for platform 'almalinux'"}`. Verified live:

- Rejected: `almalinux`, `oracle`, `oracleserver`, `scientific`, `xenserver`, `opensuse` — these are
  exactly the six entries in `DOWNLOAD_API_PLATFORM_ALIASES`.
- Accepted verbatim: `el`, `redhat`, `centos`, `rocky`, `fedora`, `amazon`, `suse`, `sles`,
  `opensuseleap`, `debian`, `ubuntu`, `linuxmint`, `windows` — passed straight through.

Keep the table minimal; remapping a name the API already accepts creates a second source of truth.
This is not hypothetical: `almalinux` is `kitchen.yml`'s RHEL proxy and `oracle` is in the Dokken
matrix. Sending `pm` explicitly does not help — the unknown name still fails the DB lookup, just
with the vaguer `{"message":"Product information not found."}` (verified with `p=almalinux&pm=rpm`).
`mac_os_x` is accepted but returns `Product information not found` because chef-ice publishes no
macOS artifact; that is expected, not a mapping bug. `spec/unit/libraries/helpers_spec.rb` pins both
lists.

**Requests go through `Chef::HTTP::Simple`**, not `Net::HTTP`, so they honor the same
`Chef::Config` proxy settings as `remote_file`. `commercial_api_get` retries transient network
errors and 5xx (`retries: 3, retry_delay: 3`); 4xx is never retried, since a bad license or unknown
version will not succeed on retry.

**The license key travels in the query string, so every error path scrubs it** via
`scrub_license_key`. `license_id` is also required on the `/files` URL itself (403 without it),
which is why the downloading `remote_file` stays `sensitive true`.

**`license_key` is typed `[String, NilClass]`, not `String`.** Its default resolves to nil when
`CHEF_LICENSE_KEY` is unset, and the `download_url` path legitimately needs no key — with a bare
`String` type, merely READING the property raised `Chef::Exceptions::ValidationFailed` and broke the
airgapped/local-mirror workflow. Callers needing a key go through `validate_license!`.

### CDN Propagation — Both `retries` and `verify` Are Required

A new release is advertised by the API before it is downloadable at every CDN edge; until it
propagates, an edge returns 403/404 or a short error body with a 200. Windows MSIs are worst
affected. `install` handles this with `retries`/`retry_delay` on the `remote_file` (tunable via
`download_retries` / `download_retry_delay`, default 5 x 30s) **plus** a `verify` block.

**`remote_file`'s `checksum` property does NOT verify a download.** It is only an idempotency
short-circuit comparing an already-present local file
(`Chef::Provider::RemoteFile::Content#current_resource_matches_target_checksum?`); nothing checks
what came off the wire. Without `verify`, a CDN error page served with a 200 goes straight to
rpm/dpkg/msiexec. Do not drop `verify` on the grounds that `checksum` is set.

Retrying is safe: `verify` runs on the staged tempfile before it is moved into place, so a rejected
body never becomes the cached artifact, and `CacheControlData.load_and_validate` discards its saved
etag/mtime when they don't match the local file, forcing a full re-download rather than a 304.

### Package Type Comes From the Download URL

`Helpers#package_extension_from_url` parses the URL actually being fetched and returns its extension
(`PACKAGE_EXTENSIONS` = rpm/deb/msi/dmg/pkg), which `install` uses to build the staging filename.
Both paths always have a full file URL: the API is queried with `direct=true`, and a user-supplied
`download_url` points at a package file.

Do not reintroduce a platform-derived extension guess — it duplicates what the URL already carries
and can silently disagree, staging an `.msi` as `chef-ice-19.3.15.rpm`. `URI#path` excludes query
and fragment, so presigned/CDN URLs with `?X-Amz-...` or `?license_id=...` resolve correctly. A URL
with no known extension raises `Chef::Exceptions::ValidationFailed` naming the accepted extensions,
built from the URL with its query stripped so `license_id` never reaches the log.

## Sensitive Data

`sensitive true` is set on the `license_key` property and on the three resources that touch key
material: the artifact `remote_file`, `execute[migrate-ice apply airgap]`, and the Windows
`windows_env['CHEF_LICENSE_KEY for chef-ice MSI install']`. `scrub_license_key` covers the remaining
path — API failures whose URLs carry `license_id`.

## Why Not `converge_if_changed` / `converge_by` / `load_current_value`

Evaluated against Chef 19.3.15 source and deliberately rejected. Do not re-propose without reading
this.

Every action works by **declaring inner Chef resources** (`rpm_package`, `execute`,
`windows_package`, `file`, `windows_path`, `ruby_block`) rather than doing filesystem/shell work
inline. That is what buys per-step idempotency reporting, why-run support, and `not_if`/`only_if`
guards for free — and it is incompatible with `converge_by`, because of an ordering asymmetry:

- `ConvergeActions#add_action` yields **immediately** unless `Chef::Config[:why_run]` is set, so a
  `converge_by` body runs inline where it appears.
- `Chef::Provider#compile_and_converge_action` `instance_eval`s the *entire* action body to collect
  declared sub-resources, and only then calls `runner.converge`.

**So any plain Ruby in an action body — including everything inside `converge_by` — runs BEFORE
every sub-resource that action declares, regardless of source order.** Mixing the two silently
inverts the intended sequence. `converge_by` is also redundant: declared sub-resources already
report their own status, so wrapping them double-reports one change.

`load_current_value` runs once when the action starts, but this cookbook's state checks
(`binlink_current?`, `hab_pkg_dirs`, `current_native_version`) must evaluate at each sub-resource's
own converge time — `install` can install a package *during* the same converge. That is exactly why
they live in `not_if`/`only_if` guards and `lazy {}` blocks.

## Install: Preserving Multiple Versions

Every `chef-ice` package bundles a `migrate-ice` tool that the package manager's install transaction
invokes unconditionally, with no flag to preserve a previously installed version's Habitat
directory. `install` works around this per platform so a newer chef-ice never deletes an older one,
and preserves the legacy omnibus install when `preserve_omnibus` is true.

- **RHEL family** — `rpm_package` directly (bypassing dnf/yum) with `--replacefiles --noscripts
  --nodigest`, then runs `migrate-ice` via a separate `execute`. `--noscripts` suppresses the RPM's
  `%post` (which always runs `migrate-ice` without `--preserve-omnibus`). `--nodigest` is required
  because chef-ice's RPM is always built on an Amazon Linux 2 builder regardless of target and lacks
  a modern per-file payload digest — rpm 4.x tolerates this, rpm 6.x (Fedora) hard-fails. It does
  not skip the sha256 (enforced by the `remote_file`'s `verify` block) or GPG (already skipped by
  `--noscripts`). Do not switch to `package`/`dnf_package`/`yum_package` — they erase the previous
  NEVRA's entire file tree, including its Habitat directory, on upgrade.
- **Debian family** — `dpkg --unpack` then `dpkg --configure`, temporarily stubbing `migrate-ice`
  (and, on upgrades, the previous package's `postrm`, which can `rm -rf /hab`) between the phases;
  `dpkg -i` has no `--noscripts`. See below.
- **Windows** — `windows_package` (`installer_type :msi`). Each release has a distinct MSI
  `ProductCode`/`UpgradeCode`, so side-by-side is already safe; only the `CHEF_PRESERVE_OMNIBUS=1`
  MSI property is needed (forwarded to migrate-ice by the package's `PostInstall.ps1`, present only
  on builds from ~2026-04-23 onward). Installs take 7-13 minutes, past `windows_package`'s 600s
  default, so the resource hardcodes `timeout 1800`. There is no `timeout` cookbook property.

Do not simplify any of this back to a plain `package` resource without re-verifying on a live
multi-version Kitchen suite that the previous version's files survive an upgrade.

### Windows: `TARGETDIR` Must Be Pinned Explicitly

`install` always passes `TARGETDIR=C:\` (`Helpers::WINDOWS_MSI_TARGETDIR`) in the msiexec `options`,
independently of `CHEF_PRESERVE_OMNIBUS`. Do not drop it or make it conditional.

Only chef-ice **19.3.15 and newer** carry a `SetTARGETDIR = [WindowsVolume]` custom action
(sequenced in `InstallExecuteSequence` at 799, condition `NOT TARGETDIR`). Verified by exporting the
MSI tables of both releases: 19.3.14 has neither the `CustomAction` row nor the sequence entry. On
those older MSIs Windows Installer resolves `TARGETDIR` from `ROOTDRIVE` — *the fixed drive with the
most free space*, not the Windows volume. A GitHub Actions `windows-latest` runner ships C: with
~35GB free and D: with ~145GB free, so the payload lands in `D:\hab`.

Two things then break, and neither produces a useful error:

- The MSI's embedded `PostInstall.ps1` in 19.3.14 hardcodes `$bin = 'C:\hab\migration\bin'` (19.3.15
  changed this to `Join-Path $PSScriptRoot 'bin'`). With `$ErrorActionPreference = 'Stop'`, the
  missing `migrate-ice.exe` throws, `WixQuietExec` fails, and msiexec returns a bare **1603** after
  ~20 seconds with no diagnostic. This is what failed the `multi-version` suite, whose Windows
  branch installs 19.3.14 first.
- `Helpers#hab_pkg_root` and `Helpers#chef_client_binlink_dir` hardcode `C:\hab` and `C:\hab\bin`, so
  even an MSI that installed cleanly elsewhere is invisible to every guard, binlink and scheduler
  path in this cookbook.

**Reproduced directly** on a clean Windows Server 2022 EC2 instance (single C: volume, no `C:\hab`)
by installing the 19.3.14 MSI with an explicit off-volume `TARGETDIR` — `msiexec /qn /i
chef-ice-19.3.14-1_x64.msi TARGETDIR=C:\alt\ /l*v` — which reproduced the CI signature exactly
(`EXIT=1603` after 21s). The verbose log shows the payload correctly staged at
`C:\alt\hab\migration\bin\migrate-ice.exe` while `RunPostInstallFresh` invoked

```text
WixQuietExec: Executing: C:\hab\migration\bin\migrate-ice apply airgap --fresh-install C:\hab\...
WixQuietExec: Start-Process : This command cannot be run due to the error:
              The system cannot find the file specified.
              At C:\alt\hab\migration\PostInstall.ps1:97 char:6
```

Re-running the same MSI on the same box with `TARGETDIR=C:\` exits 0 in 460s and populates
`C:\hab\pkgs\chef\chef-infra-client\19.3.14`. Note EC2 instances have a single volume, so `ROOTDRIVE`
resolves to C: there and the Kitchen `multi-version` suite passes on EC2 with or without this fix —
**do not conclude from a green EC2 run that the fix is unnecessary.** It is only observable where a
second fixed drive has more free space than C:, which is exactly the GitHub Actions runner.

Passing `TARGETDIR` explicitly on 19.3.15+ merely makes its own `NOT TARGETDIR` condition false,
which is harmless — the value is identical. MSI directory properties require the trailing backslash,
hence `C:\` and not `C:`.

**This was not, on its own, what made `multi-version` fail in CI.** With `TARGETDIR` pinned the
suite still returned 1603, for the unrelated `C:\hab` file-lock reason documented under
"`kitchen.proxy.yml` Must Install Omnibus in `pre_converge` AND Pin `chef_client_path`". Pinning
`TARGETDIR` remains correct and necessary — an off-volume install is genuinely broken for every path
above — but treat the two as independent failures that happen to share an exit code.

### Debian Stub/Restore Must Stay in One `ruby_block`

The stub → `dpkg --configure` → restore sequence is a **single** `ruby_block` wrapping `shell_out!`
in `begin/ensure`. Do not split it into three declared resources: Chef has no cross-resource
`ensure`, so when `dpkg --configure` fails the run aborts and a separate "restore" resource never
converges — leaving `migrate-ice` as a permanent `#!/bin/sh\nexit 0` stub. Every later converge
would then run `execute[migrate-ice apply airgap]` against that stub, which exits 0 without
extracting anything: chef-ice would report clean successful installs forever while `/hab/pkgs`
stayed empty. The `ensure` still re-raises, so genuine dpkg failures still fail the converge.

A separate self-heal `ruby_block` reclaims a backup stranded by a harder failure (reboot, SIGKILL).
It runs **before** `dpkg --unpack` deliberately — restoring afterwards would overwrite the newly
unpacked release's `migrate-ice` with the previous one's. It is also deliberately not guarded by
`dpkg_already_current`; a stranded backup must be reclaimed whether or not this converge installs.

### `--fresh-install` Is Conditional

`execute[migrate-ice apply airgap]` decides whether to pass `--fresh-install` based on
`Helpers#chef_client_on_path?`, mirroring migrate-ice's own internal "is chef-client installed?"
check (which shells out via `$PATH`, not a check for `/opt/chef` on disk):

- **On `$PATH`** (native installs on real VMs/EC2): the non-fresh-install path runs a normal
  migration and fully respects `--preserve-omnibus true`.
- **Not on `$PATH`** (minimal Dokken/CI images invoking chef-client by full path): the
  installed-check fails, so `--fresh-install` is needed to extract the bundle unconditionally.

**Both branches exit 0**, which is why getting this wrong goes undetected: passing `--fresh-install`
unconditionally silently no-ops on EC2/native VMs (migrate-ice sees chef-client already installed
and refuses), leaving `/hab/pkgs` empty and the `not_if` never satisfiable. Do not pass it
unconditionally, and do not gate it on `File.directory?('/opt/chef')` (reintroduces a mount-remount
failure) — `chef_client_on_path?` is the check that matches migrate-ice's own logic.

### `--fstab ignore` When Preserving Omnibus

`migrate-ice`'s `--fstab` (`apply`/`fail`/`ignore`, default `apply`) is only processed on the
**migration** path (no `--fresh-install`). `apply` remounts the device at `/opt/chef` onto `/hab`,
which hard-fails and rolls back when `/opt/chef` is genuinely its own mount point:

```text
Failure while processing flag `fstab`, Error: error during mount migration:
  failed to mount <dev> to /hab: exit status 32.
```

Every kitchen-dokken container bind-mounts `/opt/chef` from the `chef/chef` data container, so this
fires 100% of the time in Dokken CI on any converge reaching the migration path. That is what broke
`multi-version` on every Linux platform: the first install takes `--fresh-install` (fstab never
processed) but binlinks chef-client onto `$PATH`, so the second install in the same converge takes
the migration path and dies. Suites that install only once per converge never hit it.

`fstab_handling` therefore defaults to `ignore` whenever `preserve_omnibus` is true (preserving the
omnibus install and moving its filesystem out from under it are contradictory), and to migrate-ice's
own `apply` otherwise. Do not drop the flag or force `apply`; do not "fix" this by forcing
`--fresh-install` on the upgrade path, which would silently no-op.

**`execute[migrate-ice apply airgap]` carries `retries 5` / `retry_delay 10`** for an upstream
migrate-ice/Go GC race (`fatal error: lfstack.push ... runtime.gcBgMarkStartWorkers`, exit 2) while
extracting the ~160MB tarball under CPU-constrained/emulated environments, regardless of flags or
`GOMAXPROCS`. Retry is the correct fix — do not address it by altering flag logic or GC tuning.

## Scheduler Reconvergence (in-place, no process handoff)

When a converge actually installs a new chef-ice version, `install` re-runs any already-declared
`chef_client_cron` / `chef_client_launchd` / `chef_client_systemd_timer` /
`chef_client_scheduled_task`, explicitly setting `chef_binary_path` to the resolved, fully-versioned
Habitat path (`Helpers#chef_client_hab_binary_path`) before re-running its declared action. The sole
purpose is to point an existing schedule at the newly-installed client. No re-exec or exit is
involved, on any platform.

**Do NOT point `chef_binary_path` at the mutable `/usr/bin/chef-client` binlink — on Linux/macOS.**
Scheduler resources re-resolve it at every *scheduled* invocation as root/SYSTEM, so a writable
well-known symlink there is a standing local privilege-escalation target between runs. The versioned
Habitat path points at the immutable, Habitat-verified payload.

**Windows is the deliberate exception**, and `chef_client_hab_binary_path` short-circuits to
`chef_client_binlink_path` (`C:\hab\bin\chef-client.bat`) there whenever that file exists. Two
independent reasons, and both must hold:

- **The threat model does not apply.** `hab pkg binlink` does not create a symlink on Windows; it
  generates a `.bat` shim whose *contents* name the resolved, fully-versioned package path. The
  version is pinned inside the file rather than by the path used to reach it, so there is no mutable
  indirection to hijack. `test/integration/scheduler-fix/default_test.rb` asserts this directly —
  the shim must contain a `hab\pkgs\chef\chef-infra-client` path and the expected version — so the
  premise can never silently stop being true.
- **Disagreeing with Chef core is not idempotent.** `Chef::Resource::Helpers::PathHelpers#chef_client_hab_binary_path`
  — the `chef_binary_path` *default* for every `chef_client_*` scheduler resource — returns exactly
  that shim on Windows (`return bat_path if File.exist?(bat_path) && ChefUtils.windows?`), and only
  falls through to `File.realpath($PROGRAM_NAME)` (the versioned path) elsewhere. Returning anything
  else on Windows guarantees a permanent diff against that default: every converge that re-evaluates
  it flips the scheduled task back and reports `windows_task[chef-client] task updated`, forever.
  On Linux the two already agree, which is why only Windows needs the special case.

**The Windows short-circuit is conditional on the shim naming the version resolved for THIS
converge**, via `Helpers#windows_binlink_targets?`. That the shim pins a version is the whole
justification for pointing a schedule at it, so it has to be the *right* version: a shim left behind
by a previous install still names the old package directory, and following it would hand the next
scheduled run the exact version this converge just replaced. Chef core's own helper does not check
this — it returns the shim on sight — so the check has to live here. When the shim does not match,
the cookbook logs a warning and falls back to the versioned Habitat path: correct scheduling wins
over matching Chef's default, and the resulting `task updated` on later converges is a true signal
that the binlink is unmanaged or stale, not noise.

`windows_binlink_targets?` compares only the trailing `ORIGIN/NAME/VERSION/RELEASE` ident, because
`hab_pkg_dirs` yields forward slashes on Windows while `hab pkg binlink` writes backslashes; it
normalizes separators and requires the full four-segment ident so `19.3.15` cannot match a shim
naming `19.3.150`.

In practice the fallback is dormant: the reconverge `ruby_block` is driven by a `:delayed`
notification, and `Chef::Runner#converge` drains those only after every declared resource —
including `chef_client_updater_enterprise_binlinks`, declared later in `action :install` — has
already converged. So with `manage_binlinks true` the shim is always freshly rewritten before the
schedule is repointed. It fires only when `manage_binlinks false` leaves nobody maintaining the
binlink, or on the `action :install` early-return path (pinned version already installed), which
returns before `binlinks` is ever declared.

`test/integration/scheduler-fix/default_test.rb` asserts all of this on the target: that the task
command names the shim, that the shim contains `hab\pkgs\chef\chef-infra-client\<version>\<release>`
with the version *in position*, and that the two agree with each other.

`spec/unit/libraries/helpers_spec.rb` pins every branch: the Windows short-circuit when the shim
matches (including when it matches an explicitly pinned older `version`), the fallback when the shim
is stale, the fallback when no shim exists yet, that a `19.3.150` shim does not satisfy a `19.3.15`
resolution, and that Linux *never* short-circuits even when `/usr/bin/chef-client` is present.

**Must explicitly SET the property — resetting is not enough.** An older bootstrap chef-client's
`chef_binary_path` default can be a plain hardcoded path, not a `lazy {}` block at all, so
`Property#reset` (which only forces a *default* to re-evaluate) changes nothing. Even for a lazy
default, `Property#get` only re-evaluates while the property is unset; the first read caches.

**`chef_client_hab_binary_path` takes the resource's `version`, not just `pkg`, and resolves the
PINNED version** rather than always `hab_pkg_dirs(pkg).last`. Multiple versions can coexist under
`/hab/pkgs`; a user pinning an older release (rolling back a regression) must not be silently
repointed at a newer one. `latest` resolves to `.last`; any explicit version filters to it.

Declaration order relative to `install` does not matter — Chef compiles the whole resource
collection before converging. **Gotcha**: inside `action_class`, `run_context` is a CHILD
`RunContext` scoped to that action; only `run_context.root_run_context.resource_collection` reaches
the shared collection.

This does not risk pointing at a version `cleanup` later removes. The delayed notification is
registered in `install`'s own child `RunContext`, so `Chef::Runner#converge` drains it at the end of
`install`'s action — not the end of the whole run — so reconvergence happens before `cleanup`.

**On Windows the resolved path is forward-slashed.** `Helpers#hab_pkg_root` returns
`"C:/hab/pkgs/#{pkg}"` and `chef_client_hab_binary_path` builds on it with `File.join`, so the value
written into the scheduled task is `C:/hab/pkgs/chef/chef-infra-client/<v>/<release>/bin/
chef-client.bat`, not a backslashed path. Windows accepts either separator and nothing normalizes
them, so `test/integration/scheduler-fix/default_test.rb` matches `[\\/]` rather than asserting on
that incidental formatting — a backslash-only regex there fails against a perfectly correct task.

**Notification-bound, by design.** The `ruby_block` is `action :nothing`, driven only by delayed
notifications from resources meaning "chef-ice was actually installed or upgraded in *this*
converge". `migrate-ice apply airgap`'s `not_if` is satisfied once `pkg_version` exists under
`/hab/pkgs`, so a steady-state converge does not run it, notify, or reconverge anything.

**Wire the notification per platform, not just to `execute[migrate-ice apply airgap]`.** That
`execute` is guarded by `only_if { ::File.exist?('/hab/migration/bin/migrate-ice') }`, a Linux-only
path — on Windows the MSI's embedded `PostInstall.ps1` invokes migrate-ice inside the msiexec
transaction instead. So the `windows_package` and the generic non-RHEL/non-Debian `package` fallback
carry the same `notifies :run, 'ruby_block[reconverge installed scheduler resources]', :delayed`.
Both are natively idempotent, so they notify only on a real install. Chef de-duplicates delayed
notifications by resource+action, so a platform where both fire still reconverges once. Without the
Windows notification a `chef_client_scheduled_task` is never repointed.

Do not switch the block to unconditional `action :run`. `Chef::Provider::RubyBlock` wraps the call
in an unconditional `converge_by` and discards the return value, so it would report a changed
resource on every converge forever and break the CI converge-twice check. For the same reason
`reconverge_scheduler_resources` computes no updated-or-not return value; nothing could consume one.

This is not a general repair mechanism for a `chef_binary_path` that drifted for unrelated reasons.
The only other entry point is the early return at the top of `action :install` (explicitly pinned
version already installed), which calls `reconverge_installed_scheduler_resources` directly in Ruby
because it returns before the `ruby_block` is declared.

**History**: an earlier design used `Kernel.exec`/`exit(213)` handoff, which deadlocked on Windows
(MRI's `Kernel.exec` can't truly replace a process there, so the parent stayed alive holding Chef's
run-lock). In-place reconvergence avoids the run-lock and needs no second chef-client run.

**Without reconvergence** (`update_scheduler_resources false`), a scheduler resource declared before
chef-ice is binlinked bakes in a stale path permanently. Separately, `cleanup` only excludes the
currently-*running* ident — once a lagging pinned version is no longer running, cleanup removes it
like any other, breaking a schedule still pointing at it.

## Cleanup Uses Direct `hab pkg uninstall`, Not `habitat_package`

`cleanup` removes old Habitat versions via a plain `execute` running
`hab pkg uninstall <origin>/<name>/<version>/<release>` (full ident). Do not "simplify" to
`habitat_package` without re-verifying on a live multi-version Kitchen suite.

**The bug:** `Chef::Provider::Package::Habitat#installed_version` runs `hab pkg path <origin/name>`
with no version qualifier — Habitat's *current/active* package, not "does this version exist on
disk". With multiple versions present it can report an older, still-installed version as "not
installed", so `habitat_package action :remove` silently no-ops.

**The fix:** drive `hab pkg uninstall` against the full ident, bypassing that idempotency check.
Each `execute` is uniquely named per ident and guarded with `only_if { File.directory?(...) }`
against that version's actual package directory. `HAB_LICENSE=accept-no-persist` is supplied via
`environment` to avoid an interactive prompt. The ident backing the currently-running chef-client is
excluded from `to_remove` before any `execute` is declared (`running_hab_ident`).

Both `hab_binary` and `ident` are `Shellwords#shellescape`d before interpolation — keep this even
though `habitat_package` is regex-validated. `spec/unit/resources/cleanup_spec.rb` asserts against
the declared `execute["remove Habitat package <ident>"]` resources and their `command` content, not
a package matcher.

## Binlinks

`hab pkg binlink` creates symlinks for all package binaries. This cookbook always passes an explicit
`--dest` (`Helpers#chef_client_binlink_dir`) because Habitat's default does not match these paths:
`/usr/bin` on Linux, `/usr/local/bin` on macOS, `.bat` shims in `C:\hab\bin` on Windows (added to
system PATH via `windows_path`).

`:remove` is a no-op that logs a warning — Habitat has no bulk unbinlink command.

`:create`'s `execute` MUST stay idempotent on every platform: `migrate-ice apply airgap` already
creates the binlink as a side effect, so the `not_if` (`binlink_current?` /
`binlink_current_windows?`, both `action_class` methods in `resources/binlinks.rb`) is satisfied
immediately and `hab pkg binlink` never re-runs in practice. Linux/macOS check via
`File.symlink?`/`File.readlink`; Windows binlinks are generated `.bat` shims (never true symlinks),
so they instead check whether the shim's content already references the resolved install path. Do
not remove either guard.

Stale-destination cleanup on Linux/macOS uses a `file` resource with `action :delete`, not a
`ruby_block` calling `::File.unlink` — `file` is idempotent and why-run aware and correctly reports
"up to date", whereas a `ruby_block` reports "updated" every time. Its guard still discriminates a
stale *regular file* (an old omnibus binary at `/usr/bin/chef-client`) from a symlink or directory:
`file action :delete` would happily unlink a correct current symlink, and `hab pkg binlink --force`
already replaces a symlink whose target changed. Deleting a correct symlink every converge is
exactly what previously made this resource non-idempotent.

## Omnibus Removal

`remove_omnibus` removes ONLY `legacy_omnibus_package` (default `chef`) via the native package
manager. It does not touch chef-ice or the Habitat install — that is `cleanup`'s job. Keep "remove
the old thing" and "manage the new thing" separate.

**Guards.** It logs a warning and returns rather than acting when either the running chef-client is
itself executing from the legacy omnibus install (`running_under_omnibus?` — removing files a
running process executes from would break the converge), or no chef-ice Habitat package is installed
yet (`hab_pkg_dirs(habitat_package)` empty — never tear down the fallback before its replacement is
confirmed).

**Linux/macOS** use the native `package ... action :remove` (idempotent, correct up-to-date
reporting) rather than shelling out to rpm/dpkg. With `remove_directories`, both delete `/opt/chef`
only — not `/opt/chef-ice`, which does not exist; chef-ice's payload lives under `/hab/pkgs/`. macOS
additionally runs `pkgutil --forget com.chef.chef`, only if that receipt is registered.

An earlier concern that `dnf_package`'s bundled `dnf_helper.py` might be missing after `migrate-ice`
does not apply: removal only runs once already confirmed under chef-ice, so the loaded chef gem's
`dnf_helper.py` is always chef-ice's own copy.

**Windows** deletes `C:\opscode\chef` with `remove_directories`, and **discovers the display name
before calling `windows_package`.** Chef core matches the Programs-and-Features *display* name by
exact string equality, not `legacy_omnibus_package` (`chef` is only the Linux rpm/dpkg name) — the
omnibus MSI registers as `Chef Infra Client v<version>`, which varies per box. The
`legacy_omnibus_display_name` `action_class` method runs `Get-Package -Name 'Chef Infra Client*'`
(via `shell_out` argv-array form, avoiding shell injection), filtering out `chef-ice`/`air-gapped`
matches since chef-ice's MSI entry also starts with `Chef Infra`. Do not hardcode a name or pass
`new_resource.legacy_omnibus_package` — neither matches the registry entry.

**Mount-point edge case: `/opt/chef` may itself be a mount point — never `rmdir` it, only empty it.**
Some customers mount a dedicated block device there, and the official `chef/chef` Dokken image
declares it a Docker `VOLUME`. `directory action :delete` on a mount point is an `rmdir()`, which the
kernel unconditionally refuses with `Errno::EBUSY` even when empty — not something `only_if` or
retries can work around. `Helpers#mount_point?` detects it (comparing `File.stat(path).dev` against
the parent's) and, when true, deletes each entry underneath individually via `file`/`directory`.
Plain directories keep the single `directory action :delete` path.

## Windows PATH Repair Before `msiexec`

`install`'s Windows branch calls `Helpers#repair_windows_path!` immediately before
`windows_package`. Accounts that have never interactively logged on — CI's `net user /add` user
driven over WinRM being the canonical case — can expose a PATH that contains literal, unexpanded
`%SystemRoot%`-style tokens (inherited from the default profile template) or omits the Windows
system directories entirely. `Mixlib::ShellOut` does a literal directory search with no `%`
expansion, so both break every bare-name OS executable and the MSI dies with `'msiexec' is not
recognized...` even though it is present on disk (this failed EVERY Windows suite). The helper does
both: expands `%VAR%` tokens AND appends any missing System32/Windows/Wbem/WindowsPowerShell
directories (case-insensitively deduplicated). Expansion alone is insufficient — it can only repair
entries that are already present.

## Chef Core Idempotency-Reporting Bugs (Windows)

- **`windows_env` has no built-in idempotency** — create and delete both act unconditionally every
  converge. The transient `CHEF_LICENSE_KEY` pair in `install` is therefore declared
  `action :nothing` and driven **only** by notifications from the `windows_package`:
  `notifies :create, ..., :before` and `notifies :delete, ...(cleanup)', :delayed`.

  **Do not go back to a `not_if` guard comparing versions.** The previous implementation used
  `not_if { pkg_version && current_native_version(product_name) == pkg_version }`, i.e. a
  PowerShell scrape of the registry `Uninstall\*` keys (`DisplayName -like '*chef-ice*'`,
  `-ExpandProperty DisplayVersion`) compared against the version the Download API advertised. That
  is a *second, independently-derived* answer to a question `windows_package` already answers via
  MSI `ProductCode` + `MsiGetProductInfo`. Whenever the two disagreed the pair reported 2 updated
  resources on every converge forever — which is exactly what failed the `default`,
  `preserve-omnibus` and `scheduler-fix` Windows suites (`3/16`, `3/11`, `5/14` resources updated on
  the second converge) even while Chef itself correctly logged
  `windows_package[chef-ice] action install (up to date)`.

  The `:before` notification makes the decision *exact* rather than merely better: `Chef::Runner`
  `#run_action` runs the notifying resource in `forced_why_run` first and fires before-notifications
  only when that pass sets `updated_by_last_action?`, then resets the flag before the real action.
  Under why-run `ConvergeActions#add_action` skips the block but still marks the resource updated, so
  nothing installs twice. Verified end-to-end with a scratch `unified_mode true` cookbook: a
  no-change third converge reports `0/N resources updated` with neither notification firing.

  Both notifications use **string** resource references and both work under `unified_mode`. The
  `:before` target must be declared *before* the notifying resource (`RunContext#notifies_before`
  raises `UnifiedModeBeforeSubscriptionEarlierResource` otherwise); the `:delayed` cleanup target is
  deliberately declared *after* it, and is drained by `Chef::Runner#converge` at the end of
  `install`'s child `RunContext`. `:immediately` is not used — `RunContext#notifies_immediately` has
  a unified-mode path that silently downgrades a string reference to "delayed until declaration".

  Any future one-shot `windows_env` bracketing an idempotent operation should use this same
  notification pattern rather than a hand-rolled guard.
- **`windows_task` is not idempotent unless `start_time` (and `start_day`) are pinned** —
  `Chef::Provider::WindowsTask#set_start_day_and_time` assigns `new_resource.start_time =
  Time.now.strftime('%H:%M')` and `start_day = Time.now.strftime('%m/%d/%Y')` whenever the caller
  left them nil, and `start_time_updated?` / `start_day_updated?` are guarded on those same
  properties being truthy. So an unpinned task compares "now" against whatever was stored on the
  first converge and reports `task updated` as soon as the clock crosses a minute (or midnight)
  boundary. `chef_client_scheduled_task` leaves both nil by default and forwards them straight
  through, which is why `test/cookbooks/.../recipes/scheduler_fix.rb` pins `start_time '00:00'` and
  `start_date '01/01/2026'`. `test/integration/scheduler-fix/default_test.rb` only asserts on the
  task's *command*, so pinning the schedule does not weaken it. This was necessary but not
  sufficient on Windows until `chef_client_hab_binary_path` was aligned with Chef core's own
  `chef_binary_path` default — see "Scheduler Reconvergence" for that second, independent cause.
- **`windows_path :add` never propagates its inner `env` sub-resource's "no change" status** — the
  outer resource counts as updated even when the nested `env "path"` is up to date.
  `binlinks.rb`'s `windows_path 'C:\hab\bin'` works around this with an explicit `not_if` reading
  the live Machine PATH (via `Win32::Registry`, falling back to `ENV['PATH']`), matched
  case-insensitively.

**General pattern**: treat any Chef-core resource with internally-nested sub-resources as suspect on
converge-twice checks, and guard it independently with `not_if`/`only_if`.

## Unit Testing (ChefSpec/RSpec)

`spec/unit/` runs via `chef exec rspec` (Chef Workstation bundles ChefSpec/RSpec — no Gemfile).

With no `recipes/` directory ChefSpec never registers the custom resources on its own (Chef only
compiles library/resource files for cookbooks in the run_list). `spec/spec_helper.rb`'s
`converge_resource` converges a throwaway `spec/fixtures/cookbooks/chefspec_shim` cookbook that
`depends` on this one, and defaults `step_into` to all four custom resources so `action_class` code
actually executes.

The real parent directory can't be ChefSpec's `cookbook_path` if another checkout declaring the same
cookbook name is ever present alongside it — Chef's `CookbookLoader` refuses duplicate names.
Instead `spec/fixtures/cookbooks/chef_client_updater_enterprise/` holds **per-file** symlinks back
to the real `metadata.rb`/`resources`/`libraries`. Do not replace these with directory-level
symlinks — `Dir.glob` does not recurse into symlinked directories, only symlinked files. **Whenever
a resource/library file is added, removed, or renamed, update the matching symlink**;
`spec/unit/fixture_sync_spec.rb` fails if the sets drift.

`.rubocop.yml` lints everything including `spec/` and `test/`; only `Gemfile` and `Policyfile.rb`
are excluded. Run `chef exec cookstyle .`.

## Test Kitchen Platforms and Suites

Five suites, each backed by a named run-list in
`test/cookbooks/chef_client_updater_enterprise_test/recipes/`: `default`, `preserve-omnibus`,
`remove-omnibus`, `multi-version`, `scheduler-fix`.

**`multi-version`'s expected version is resolved at verify time, not pinned.** Its third install is
deliberately unpinned (`version 'latest'`), so `test/integration/multi-version/default_test.rb`
GETs `/<channel>/chef-ice/versions/latest` from the Commercial Download API and asserts the single
retained Habitat version equals it. `/versions/latest` is used rather than `/metadata` because it
takes no platform parameters — the InSpec runner's OS is irrelevant and no platform alias is needed.
The call runs on the runner (not the target) using `ENV['CHEF_LICENSE_KEY']`, never an InSpec input,
so the key stays out of input/log output; any failure returns nil and degrades to a visible `skip`
rather than a spurious failure. An explicit `expected_chef_ice_version` input still wins, for
airgapped runs. Do not reintroduce a hardcoded `expected_chef_ice_version` for this suite — without
the API check, a silently no-opping `install latest` still leaves exactly one version behind with a
correct binlink and passes every other control in the profile (verified by mutation test).

`metadata.rb` declares broad OS-family `supports`, but tested platforms are narrower and differ per
driver. There are **five** kitchen config files; `kitchen.yml` is the base and the others are
selected with `KITCHEN_LOCAL_YAML`:

- `kitchen.yml` (Vagrant, default) — AlmaLinux 9/10, openSUSE Leap 15/16, Ubuntu 24.04/26.04,
  Windows Server 2022, Windows 11.
- `kitchen.dokken.yml` — the broad Linux matrix (18 platforms: Amazon Linux 2023, AlmaLinux 8/9/10,
  Debian 12/13, Fedora latest, openSUSE Leap 15/16, Oracle Linux 8/9/10, Rocky Linux 8/9/10, Ubuntu
  22.04/24.04/26.04). No Windows.
- `kitchen.ec2.yml` — RHEL 9/10, openSUSE Leap 16, Ubuntu 24.04/26.04, Windows 11, Windows Server
  2022/2025. Substitutes RHEL for Vagrant's AlmaLinux proxies.
- `kitchen.exec.yml` and `kitchen.proxy.yml` — both declare only `localhost` and `windows-latest`.
  `kitchen.proxy.yml` is what the Windows CI job uses.

Only `suites:` and `provisioner:` are inherited from `kitchen.yml` via Test Kitchen's recursive
merge; `platforms:` are matched by name and replaced wholesale, so a suite runs against whatever the
active file declares. `Kitchen::Instance.name_for` strips dots, so platform `ubuntu-24.04` yields
instance `ubuntu-2404` — which is why CI matrices name `ubuntu-2404` while the YAML says
`ubuntu-24.04`.

**Consequence: any platform-name list inside `kitchen.yml` must cover the union of every file's
names**, because lifecycle hooks live in `kitchen.yml` but run under whichever driver is active.

### `kitchen.proxy.yml` Must Install Omnibus in `pre_converge` AND Pin `chef_client_path`

The `proxy` driver's target IS the GitHub Actions runner, which already has
chef-workstation-enterprise installed under `C:\hab`. Unlike the Vagrant and EC2 drivers — whose
boxes are bare and therefore always get omnibus Chef 18 at `C:\opscode\chef` — the provisioner's
default `install_strategy: once` detects that Habitat chef-client (`chef installation detected at
C:\hab\pkgs\chef\chef-infra-client\...`) and **skips its own omnibus bootstrap**. Two suites broke
on that one difference, and both were misdiagnosed as MSI bugs before the Windows Installer log was
captured:

- **`multi-version` returned 1603 in ~10s.** The converging chef-client was itself executing out of
  `C:\hab`, holding `C:\hab\pkgs\core\zlib\1.3.1\...\bin\zlibwapi.dll` open. `migrate-ice` unpacks
  the chef-ice bundle *into* `C:\hab` and hit that file: `failed to create file ... zlibwapi.dll:
  The process cannot access the file because it is being used by another process`, then rolled back.
  This is the Windows analogue of `running_under_omnibus?` — you cannot replace files the running
  chef-client is executing from.
- **`preserve-omnibus` failed its `C:\opscode\chef` assertion**, because no omnibus install was ever
  created. `remove-omnibus` was passing *vacuously* for the same reason.

The fix is **two settings that are only correct together**; either alone leaves the runner converging
out of `C:\hab`.

1. **A `pre_converge` lifecycle hook installs omnibus Chef 18** via the Commercial Download API,
   guarded by `Test-Path 'C:\opscode\chef\bin\chef-client.bat'` so it is idempotent.
   `Kitchen::Instance#transition_to` wraps `run_with_hooks(transition) { send("#{transition}_action") }`,
   so `pre_converge` completes entirely before `converge_action` — including before the provisioner's
   own install/bootstrap step. Platform-level `lifecycle:` blocks **merge** with suite-level ones
   (`kitchen diagnose` confirms `remove-omnibus` carries both this `pre_converge` and its own
   `post_converge`).
2. **`provisioner.chef_client_path` is pinned** to `C:\opscode\chef\bin\chef-client.bat`, because
   installing omnibus is *not by itself sufficient*.
   `Kitchen::Provisioner::ChefInfra#find_chef_executable` searches, in order:
   1. `config[:chef_client_path]`
   2. `C:\hab\chef\bin\chef-client.ps1`
   3. `C:\hab\pkgs\chef\chef-infra-client\*\*\bin\chef-client.bat`
   4. `C:\opscode\chef\bin\chef-client.bat`

   **Step 3 precedes step 4**, so with `C:\hab` populated an omnibus install can only win via step 1.
   And `chef_client_path`'s own default interpolates `chef_omnibus_root`, which is assigned only as a
   *side effect* of install-command generation (`config[:chef_omnibus_root] = installer.root`); until
   that runs the default collapses to the useless `"\bin\chef-client.bat"` (confirmed via `kitchen
   diagnose`). So it must be set explicitly.

Do not "simplify" this back to `install_strategy: always`. That reinstalls omnibus on every converge
(slow, and it re-creates `C:\opscode\chef` after `remove-omnibus` deletes it) while still losing the
executable-resolution race at step 3 unless `chef_client_path` is pinned anyway. There is no
"install omnibus even though some other chef exists" setting — `once` looks for *any* chef-client.

Corollary: a 1603 from the chef-ice MSI is **not** self-diagnosing. `msiexec /qn` yields an empty
STDOUT/STDERR, so the Chef log shows only `returned 1603`. The Windows CI job enables the Windows
Installer logging policy and prints the resulting log on failure; leave that in place. Two plausible
causes (a wrong `TARGETDIR`, and a pre-existing Habitat `chef-infra-client` of a different version)
were both disproven against live EC2 boxes before the log identified the real one.

### Remote Shells Inherit No Environment

`kitchen exec` and lifecycle `remote:` commands open a **fresh WinRM/SSH shell that inherits nothing**
from the Kitchen host — `Kitchen::LifecycleHook::Remote#run` goes straight to
`instance.transport.connection(...)`. Without `HAB_LICENSE` in scope, chef-client stops at an
interactive `Do you accept the 1 product license? [yes/No/quit]` prompt for **Habitat** and exits 1.
Every such command therefore sets its licence/kitchen vars inline (`$env:X='...'; ` for PowerShell,
`export X=...; ` for sh). The Linux/Dokken path never hit this because it passes them via
`docker exec -e`.

Relatedly, **`kitchen.proxy.yml` repeats the WinRM credentials under an explicit `transport:` block.**
`Kitchen::Driver::SSHBase#backcompat_merged_state` injects driver credentials on the converge/verify
path only; `LifecycleHook::Remote#run` calls `instance.transport.connection(state_file.read)`
directly with no merge, so a hook fails with `password is a required option` if the credentials live
only under `driver:`.

Do not add a platform without confirming the Commercial Download API publishes chef-ice artifacts
for it (`GET /<channel>/chef-ice/metadata?p=&pv=&m=` returns HTTP 400 if not). chef-ice publishes no
macOS artifact, so the `mac_os_x` code paths are declared-but-untested.

**`kitchen-ec2` has no built-in `opensuse` `Aws::StandardPlatform`.** An unrecognized platform name
silently falls back to an Ubuntu AMI with no error, so `kitchen.ec2.yml`'s `opensuse-leap-16` pins an
explicit `image_id`. Any future non-standard name must do the same unless it is one of kitchen-ec2's
registered families (rhel/centos/alma/rocky/debian/ubuntu/amazon/amazon2/amazon2023/fedora/windows/
macos/freebsd).

**openSUSE Leap 15.6 is EOL and its AWS AMI delisted** — `opensuse-leap-15` is absent from
`kitchen.ec2.yml` but still present in `kitchen.yml` and `kitchen.dokken.yml`.

**Never run the Dokken + EC2 matrix concurrently against the same checkout** — `chef-cli`
read-modify-writes `Policyfile.lock.json` with no interprocess locking, so concurrent converges
corrupt it (`NoMethodError: undefined method '[]' for nil`). Run serially or use per-combo copies.

### The `remove-omnibus` `post_converge` Hook

`remove_omnibus` defers on the first converge (`running_under_omnibus?` stays true for the whole
life of the converging process), so a single converge can never complete the removal. This is
expected. `kitchen.yml`'s `remove-omnibus` suite therefore carries a `lifecycle: post_converge:`
hook running a second, separate chef-client invocation against the cookbook's own stable binlink
(`chef_client_binlink_path`), bypassing Test Kitchen's executable discovery, which would keep
resolving back to the omnibus path. Do not remove the hook or try to finish removal in one converge.

**The hook must be wrapped in `sh -c '...'` under Dokken** — kitchen-dokken's transport execs a raw
argv array with no shell, so `export FOO=1; ...` fails with `exec: "export": executable file not
found in $PATH`. Vagrant's ssh transport already runs a shell, so the wrapper is a harmless no-op
there. The hook also probes for `/opt/kitchen/client.rb` (Dokken sandbox root) and falls back to
`/tmp/kitchen` (Vagrant), since both drivers share this one `kitchen.yml`.

**A `remote:` lifecycle hook needs credentials on the TRANSPORT, not just the driver.**
`kitchen.proxy.yml` (the Windows CI config) declares `host`/`port`/`username`/`password` on the
`proxy` driver, and that is enough for converge/verify only because
`Kitchen::Driver::SSHBase#backcompat_merged_state` copies them into the connection.
`Kitchen::LifecycleHook::Remote#run` calls `instance.transport.connection(state_file.read)`
directly, with no such merge — so the winrm transport sees `password: nil` and dies with
`WinRM::ConnectionOpts#validate_required_fields': password is a required option` before the hook
runs at all. `kitchen.proxy.yml`'s `windows-latest` platform therefore repeats the credentials under
an explicit `transport:` block. Any new kitchen config growing a `remote:` hook needs the same.
Verified live: with this in place the hook connects and runs; without it the suite never gets past
`ConnectionOpts#validate_required_fields`.

**A `remote:` hook — and `kitchen exec` — opens a shell that inherits NOTHING from the kitchen
host.** `CHEF_LICENSE` / `HAB_LICENSE` exported in CI reach the kitchen process, not the target, so
chef-client stops at an interactive `Do you accept the 1 product license? [yes/No/quit]` for Habitat
and exits 1. Both variants of the hook, and the workflow's Habitat-backed idempotency step,
therefore set the license variables inline in the remote command. The Linux CI job never hit this
because it passes them explicitly via `docker exec -e`. This is not the same failure as the missing
transport credentials above — it appears only after those are fixed.

**Keep it scoped to the `remove-omnibus` suite — never move it to top level.** Lifecycle-hook
`includes`/`excludes` match on PLATFORM name only (`Kitchen::LifecycleHook::Base#should_run?`), so a
top-level hook cannot skip a suite and would re-run every suite's recipe. That is fatal for
`multi-version`, which installs an older version, then a newer one, then lets `cleanup` remove the
older: a second pass sees the older missing, reinstalls it over the newer, and kills the chef-client
process executing out of it (`Docker Exec (135)`).

The hook has one `remote:` for Linux and one for Windows, discriminated by `excludes:`/`includes:`
on platform name; both lists enumerate the same four Windows names — `windows-2022`, `windows-2025`,
`windows-11`, `windows-latest` — spanning `kitchen.yml`, `kitchen.ec2.yml`, `kitchen.exec.yml` and
`kitchen.proxy.yml`. A Windows platform missing from `excludes:` would silently get the Linux
`sh -c` variant and fail. `localhost` (exec/proxy) is deliberately in neither list, so it receives
the Linux variant.

Two things keep every other suite from needing a second pass, and both must hold:

- **No suite except `remove-omnibus` may declare `chef_client_updater_enterprise_remove_omnibus`.**
  Any recipe declaring it needs a second pass to finish, and CI's own second run would then be the
  thing performing the deferred `/opt/chef` deletions — reporting resources updated and failing the
  `0/N resources updated` assertion. The `default` recipe was moved off it for exactly this reason.
- **Nothing may install a gem at converge time** (see "Dependencies").

### CI Idempotency Checks

`.github/workflows/integration.yml` runs both jobs across all five suites.

- **Linux (Dokken)** — a second top-level `kitchen converge` would always re-bootstrap via
  kitchen-dokken's hardcoded `chef_binary: /opt/chef/bin/chef-client` regardless of what the first
  converge installed, so it can never validate real second-run idempotency. Instead the step
  `docker exec`s the cookbook's own stable binlink (`/usr/bin/chef-client`, resolved to confirm it
  is Habitat-backed) and requires `0/N resources updated`. Excluded: `multi-version` only, which
  installs a different Habitat version every converge and is never idempotent by design.
- **Windows (`kitchen.proxy.yml`, platform `windows-latest`)** — mirrors the Linux job: it invokes
  the cookbook's own stable binlink (`C:\hab\bin\chef-client.bat`) against the existing Kitchen
  sandbox via `kitchen exec`, and requires `0/N resources updated`. `kitchen exec` is used rather
  than a bare shell command so the run goes over the same WinRM transport/account as the converge
  and therefore resolves the same `%TEMP%\kitchen` sandbox; it propagates a non-zero exit code when
  the command fails (verified). Do NOT go back to a plain second `kitchen converge` — Test Kitchen
  re-bootstraps via the provisioner's own omnibus chef-client (`product_name: chef`,
  `product_version: "18"`) regardless of what the first converge installed, so it can never validate
  real second-run idempotency.

  Excluded: `multi-version` only — the same suite the Linux job excludes, and for the same reason
  (it installs a different Habitat version on every converge and is never idempotent by design).

  `remove-omnibus` **is** checked here. Its `post_converge` hook has already completed the deferred
  omnibus removal by the time this step runs, so this run is what proves the end state actually
  settles rather than merely that the hook ran. `scheduler-fix` **is** checked here too, now that
  `Helpers#chef_client_hab_binary_path` short-circuits to `C:\hab\bin\chef-client.bat` on Windows —
  the same value Chef core's `chef_binary_path` default resolves to, so the scheduled task no longer
  flips on every converge. Do not reintroduce either exclusion to paper over a regression in that
  alignment; see "Scheduler Reconvergence".

## Local Dokken Testing (Apple Silicon)

`kitchen.dokken.yml`'s `provisioner.clean_dokken_sandbox: false` is **required and permanent** —
kitchen-dokken otherwise wipes the bind-mounted `/opt/kitchen` sandbox (backing
`Chef::Config[:file_cache_path]`) after every converge, breaking idempotency for
`remote_file[chef-ice-*]` locally and on GitHub Actions.

To run Dokken suites on Apple Silicon, force the container architecture via kitchen-dokken's driver
`platform` option — `DOCKER_DEFAULT_PLATFORM` does NOT work, because kitchen-dokken uses the
`docker-api` gem's raw socket calls, not the `docker` CLI (the only thing honoring that env var):

```yaml
driver:
  platform: linux/amd64
```

Revert before committing; GitHub Actions Linux runners are already x86_64. Because this repo sets
`KITCHEN_LOCAL_YAML` explicitly (bypassing the usual `kitchen.local.yml` auto-merge), temporary
edits must go directly into `kitchen.dokken.yml`.

`CHEF_LICENSE_KEY` is a public GitHub Actions repository **variable**, not a secret — retrieve it
via `gh variable get CHEF_LICENSE_KEY --repo <owner>/<repo>`.
