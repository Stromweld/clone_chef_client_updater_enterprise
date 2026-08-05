# AGENTS.md

## Purpose

This file records maintainer and agent decisions for the chef_client_updater_enterprise cookbook.
Keep it focused on durable patterns, support boundaries, and non-obvious implementation choices. Do
not use it as a task changelog.

## Architecture

This cookbook is resource-driven only. There are no `recipes/` or `attributes/` directories.
All defaults live on resource properties, `lazy` helper calls, or helper methods in `libraries/`.
Do not reintroduce `node['chef_client_updater_enterprise']` as an attribute API surface.

## Resource Partials and the `use` Directive

Chef's `use` directive auto-prepends an underscore when resolving partial filenames. The partial
file on disk is named `_license.rb`, but the reference in a resource must be `use 'license'`.
Using `use '_license'` would resolve to `__license.rb` and raise a `NameError` at converge time.

Correct:

```ruby
use 'license'          # resolves to _license.rb
use 'version_channel'  # resolves to _version_channel.rb
use 'pkg_names'        # resolves to _pkg_names.rb
```

The `use` partial DSL requires Chef Infra Client >= 17.0. This constraint is enforced in
`metadata.rb` via `chef_version '>= 17.0'`.

## Package Identity

Two distinct package identities are used in this cookbook. Mixing them up will break installs:

- **`chef_client_updater_enterprise_binlinks`** — The `product_name` for `mixlib-install` API calls and the native OS package
  name (rpm/deb/msi). Used by the `install` and `remove_omnibus` resources.
- **`chef/chef-infra-client`** — The Habitat package identifier. Used by the `binlinks` resource
  for `hab pkg binlink`, and by the `cleanup` resource (via a filesystem glob under
  `/hab/pkgs/`, not the `hab` CLI, for listing; removal is driven directly via `hab pkg uninstall`
  with the full ident, not Chef's built-in `habitat_package` resource — see "Cleanup Removal Uses
  Direct `hab pkg uninstall`, Not `habitat_package`" below for why).

Do not use `chef/chef-ice` as a Habitat identifier. Do not use `chef/chef-infra-client` as a
`mixlib-install` product name.

## Dependency Management

`mixlib-install` is not a metadata `depends` entry or a Gemfile dependency. It is installed at
compile time via `chef_gem` inside the `install` resource's `action_class`. Do not add it to
`metadata.rb`. This avoids version conflicts with the gem bundled in Chef Workstation.

Use `Policyfile.rb` for dependency resolution. Do not reintroduce Berkshelf files.

## Unit Testing (ChefSpec/RSpec)

`spec/unit/` holds ChefSpec/RSpec tests, run via `chef exec rspec` (Chef Workstation bundles
ChefSpec/RSpec — no Gemfile needed).

This cookbook has no `recipes/` directory, so ChefSpec never registers its custom resources on its
own (Chef only compiles library/resource files for cookbooks named in the run_list).
`spec/spec_helper.rb`'s `converge_resource` helper works around this by converging a throwaway
`spec/fixtures/cookbooks/chefspec_shim` cookbook that `depends` on this one.

This cookbook's real parent directory can't be ChefSpec's `cookbook_path` if another checkout of
this cookbook (declaring the same `chef_client_updater_enterprise` name in its own `metadata.rb`)
is ever present alongside it — Chef's `CookbookLoader` refuses to merge duplicate cookbook names.
Instead `spec/fixtures/cookbooks/chef_client_updater_enterprise/` holds
**per-file** symlinks back to the real `metadata.rb`/`resources`/`libraries`. Do not replace these
with directory-level symlinks — `Dir.glob` (used by Chef's cookbook loader) does not recurse into
symlinked directories, only symlinked files. **Whenever a resource/library file is added, removed,
or renamed, update the matching symlink** — `spec/unit/fixture_sync_spec.rb` fails if the symlinked
set drifts from the real one.

`converge_resource` defaults `step_into` to all four custom resources so their `action_class` code
actually executes (ChefSpec otherwise treats custom resources as opaque no-ops). `cleanup.rb`
declares removal via uniquely-named `execute` resources (one per full Habitat ident) rather than
repeated `habitat_package` resources sharing one name — see "Cleanup Removal Uses Direct `hab pkg
uninstall`" below.

## Sensitive Data

The `license_key` property on the `_license` partial is marked `sensitive: true`. The `remote_file`
resource that downloads the package artifact is also `sensitive: true`. Both prevent key material
from appearing in Chef logs or resource diffs.

## Unified Mode

All resources set `unified_mode true`. This ensures that compile-phase resource calls (like
`chef_gem compile_time: true`) inside `action_class` methods are evaluated in the correct converge
order. Do not remove `unified_mode true` from any resource.

## Omnibus Removal

The `remove_omnibus` resource removes ONLY the `legacy_omnibus_package` (`chef` by default) via the
native package manager — it does **not** touch `chef-ice` or the Habitat-managed installation;
those are the responsibility of `chef_client_updater_enterprise_cleanup`. Do not add chef-ice
removal logic to this resource; keep the "remove the old thing" and "manage the new thing"
responsibilities separate.

### Guard Conditions

The resource defers (logs a warning and returns) rather than acting when either:
- The currently running `chef-client` process is itself executing from the legacy omnibus install
  (`running_under_omnibus?`) — removing the files a running process is executing from would break
  the converge.
- No `chef-ice` Habitat package is installed yet (`hab_pkg_dirs(habitat_package)` is empty) — the
  omnibus fallback should never be torn down before its Habitat-based replacement is confirmed
  present.

### Linux Behavior

Uses the native `package '<legacy_omnibus_package>' do action :remove end` (idempotent, proper
up-to-date reporting) rather than shelling out to `rpm`/`dpkg` directly.

When `remove_directories` is true, also deletes `/opt/chef` only (not `/opt/chef-ice` — chef-ice
has no such directory; its payload lives under `/hab/pkgs/`). See "Mount-Point Edge Case" below for
the case where `/opt/chef` is a dedicated mount point.

### macOS Behavior

Also removes the legacy package via the native package manager (see "Linux Behavior" above for the
mechanism). When `remove_directories` is true, it also:

- Deletes `/opt/chef` only (same path and mount-point caveat as Linux — see "Mount-Point Edge Case"
  below).
- Runs `pkgutil --forget com.chef.chef` only if that receipt is currently registered.

### Windows Behavior

When `remove_directories` is true, deletes `C:\opscode\chef`.

**Windows package uninstall discovers the display name first, then uses `windows_package`.** Chef
core matches the Programs-and-Features *display* name via exact string equality, not the
`legacy_omnibus_package` property (`chef`, which only applies to the Linux rpm/dpkg name) — the
omnibus MSI registers as `Chef Infra Client v<version>`, which varies per box. The
`legacy_omnibus_display_name` helper runs `Get-Package -Name 'Chef Infra Client*'` (via `shell_out`
argv-array form, to avoid shell injection) to discover the exact display name, filtering out
`chef-ice`/`air-gapped` matches since chef-ice's own MSI entry also starts with `Chef Infra`. That
discovered name is then passed to `windows_package` for native, idempotent removal. Do not
"simplify" this back to a hardcoded name or `new_resource.legacy_omnibus_package` directly — neither
matches the registry entry.

### Mount-Point Edge Case

**`/opt/chef` may itself be a dedicated mount point — never `rmdir` it, only empty its contents.**
Some customers mount a separate block device at `/opt/chef` (the official `chef/chef` Dokken test
image itself declares it as a Docker `VOLUME`). `directory action :delete` on a mount point is
really an `rmdir()`, which the kernel unconditionally refuses with `Errno::EBUSY` regardless of
whether the directory is empty — not something `only_if` guards or retries can work around. The
`mount_point?(path)` helper (`libraries/helpers.rb`, comparing `File.stat(path).dev` against the
parent's device ID) detects this and, when true, deletes each entry under `/opt/chef` individually
via `file`/`directory` instead of ever calling `directory action :delete` on the mount point itself.
Plain, non-mounted directories use the original single `directory action :delete` path unchanged.

### Historical Notes

**Linux uses the native `package` resource, not `dnf_package`/`rpm`/`dpkg` directly.** An earlier
concern that `dnf_package`'s bundled `dnf_helper.py` might be missing after `migrate-ice` doesn't
apply: removal only runs once already confirmed under chef-ice (see "Guard Conditions" above), so
the loaded chef gem's `dnf_helper.py` is always chef-ice's own copy.

**The `remove-omnibus` Test Kitchen suite needs a second chef-client pass.** A single converge can
never complete the deferred removal, since `running_under_omnibus?` stays true for the whole life
of the converging process — this is expected. `kitchen.yml`'s `remove-omnibus` suite therefore
carries a `lifecycle: post_converge:` hook that runs a second, separate chef-client invocation
against the cookbook's own stable binlink path (`chef_client_binlink_path`), bypassing Test
Kitchen's own executable-discovery (which would otherwise keep resolving back to the omnibus path).
Do not remove this hook or try to make `remove_omnibus` complete in a single converge.

**That `post_converge` hook must be wrapped in `sh -c '...'` under Dokken** — `kitchen-dokken`'s
transport execs a raw argv array with no shell involved, so `export FOO=1; ...` fails with
`exec: "export": executable file not found in $PATH`. The ssh-based Vagrant transport already runs
through a shell, so the wrapper is a no-op there but required for Dokken. The hook also probes for
`/opt/kitchen/client.rb` (Dokken sandbox root) and falls back to `/tmp/kitchen` (Vagrant), since
both drivers share this one `kitchen.yml`.

**`remove-omnibus` is excluded from the CI idempotency check's second top-level `kitchen
converge`** — `kitchen-dokken` hardcodes `chef_binary: "/opt/chef/bin/chef-client"` for every
top-level converge, but this suite deletes `/opt/chef` by the end of the first one, so a second
top-level converge fails with `Errno::ENOENT`. This is expected, not a missed check: the suite's
own `post_converge` hook already re-exercises idempotency via the stable chef-ice binlink on every
converge. Do not remove this CI exclusion or try to make a second top-level converge work here.

## Platform Support

`metadata.rb` declares broad OS-family `supports`, but actual Kitchen-tested platforms are
narrower: `almalinux-9` (Vagrant) / `rhel-9` (EC2) as the RHEL proxy, `opensuse-leap-15`/`-16` as
the SLES/SUSE proxy, `ubuntu-2404`, and `windows-2022`. `kitchen.yml` (Vagrant) and `kitchen.ec2.yml`
(`KITCHEN_LOCAL_YAML=kitchen.ec2.yml`) must keep matching platform `name:` values — `kitchen.ec2.yml`
has no `provisioner:` key of its own and inherits it via Test Kitchen's recursive merge, but
`platforms:` are looked up by name, so adding one to only one file makes it unrunnable in the other
mode.

Do not add a platform anywhere without confirming `mixlib-install` publishes `chef-ice` artifacts
for it.

**`kitchen-ec2` has no built-in `opensuse` `Aws::StandardPlatform` support.** An unrecognized
platform name silently falls back to an Ubuntu AMI with no error — `kitchen.ec2.yml`'s
`opensuse-leap-16` entry therefore pins an explicit `image_id`. Any future non-standard platform
name added to `kitchen.ec2.yml` must do the same unless it's one of kitchen-ec2's registered
families (rhel/centos/alma/rocky/debian/ubuntu/amazon/amazon2/amazon2023/fedora/windows/macos/freebsd).

**openSUSE Leap 15.6 is EOL and its AWS AMI is delisted** — `opensuse-leap-15` has been removed
from `kitchen.ec2.yml` (still testable via Dokken only).

**Never run the Dokken + EC2 matrix concurrently against the same checkout** — `chef-cli`
read-modify-writes `Policyfile.lock.json` with no interprocess locking, so concurrent converges can
corrupt it (`NoMethodError: undefined method '[]' for nil`). Run matrix testing fully serially, or
use per-combo checkout copies.

## Preserving Multiple Installed Versions

Every `chef-ice` package (rpm/deb/MSI) bundles a `migrate-ice` tool that the native package
manager's install transaction invokes unconditionally, with no flag to preserve a previously
installed version's Habitat directory. `install` works around this per-platform so a newer
`chef-ice` never deletes an older one still on disk, and preserves the legacy omnibus install when
`preserve_omnibus` is true:

- **RHEL family:** Uses `rpm_package` directly (bypassing `dnf`/`yum`) with `--replacefiles
  --noscripts --nodigest`, then runs `migrate-ice` itself via a separate `execute`. `--noscripts`
  suppresses the RPM's `%post` (which always runs `migrate-ice` without `--preserve-omnibus`).
  `--nodigest` is required because `chef-ice`'s RPM is always built on an Amazon Linux 2 builder
  regardless of target platform and lacks a modern per-file payload digest — rpm 4.x tolerates
  this, but Fedora's rpm 6.x hard-fails without it. `--nodigest` does not skip the SHA256 checksum
  (already verified via `remote_file`'s `checksum`) or GPG verification (already skipped via
  `--noscripts`). Do not switch back to `package`/`dnf_package`/`yum_package` — those erase a
  previous NEVRA's entire file tree (including its Habitat directory) during an upgrade.
- **Debian family:** Drives `dpkg --unpack` then `dpkg --configure` directly, temporarily stubbing
  `migrate-ice` (and, on upgrades, the previous package's `postrm`, which can `rm -rf /hab`)
  between the two phases — `dpkg -i` has no `--noscripts` equivalent.
- **Windows:** Uses `windows_package` (`installer_type :msi`). Each release has a distinct MSI
  `ProductCode`/`UpgradeCode` so side-by-side installs are already safe; only the
  `CHEF_PRESERVE_OMNIBUS=1` MSI property is needed (forwarded to `migrate-ice` by the package's
  `PostInstall.ps1`). Only present on `chef-ice` builds from ~2026-04-23 onward — older MSIs always
  migrate destructively. MSI installs can take 7-13 minutes; `timeout` defaults to `1800`.

Do not simplify any of this back to a plain `package`/`dnf_package`/`apt_package` resource without
re-verifying on a live multi-version Kitchen suite that a previous version's files survive an
upgrade.

## `migrate-ice apply airgap`'s `--fresh-install` Flag Is Conditional, Not Unconditional

`chef_client_updater_enterprise_install`'s `execute[migrate-ice apply airgap]` decides whether to
pass `--fresh-install` based on `chef_client_on_path?` (in `libraries/helpers.rb`), mirroring
migrate-ice's own internal "is chef-client already installed?" check (which shells out to
`chef-client` via `$PATH`, not a check for `/opt/chef` on disk):

- **`chef-client` on `$PATH`** (native package installs on real VMs/EC2): the non-fresh-install
  path runs a normal migration and fully respects `--preserve-omnibus true`.
- **`chef-client` NOT on `$PATH`** (minimal Dokken/CI images invoking chef-client by full path):
  the non-fresh-install path's installed-check fails, so `--fresh-install` is required to skip it
  and extract the bundle unconditionally.

**Both branches exit 0 either way**, which is why getting this wrong goes undetected: passing
`--fresh-install` unconditionally silently no-ops on EC2/native VMs (migrate-ice detects chef-client
is already installed and refuses to run), leaving `/hab/pkgs` permanently empty and making
`execute[migrate-ice apply airgap]`'s `not_if` never satisfiable (re-runs harmlessly every
converge, forever).

Do not go back to unconditionally passing `--fresh-install`, and do not gate the flag on
`File.directory?('/opt/chef')` either (reintroduces a mount-remount failure mode) —
`chef_client_on_path?` is the one check that matches migrate-ice's own internal logic exactly.

## `--fstab ignore` Is Required Whenever the Migration Path Runs With `preserve_omnibus`

`migrate-ice`'s `--fstab` flag (values `apply`/`fail`/`ignore`, default `apply`) is only processed
on the **migration** path (i.e. when `--fresh-install` is NOT passed). `apply` means "remount the
device currently mounted at `/opt/chef` onto `/hab`". When `/opt/chef` is genuinely its own mount
point, that hard-fails the entire migration and rolls back:

```text
[INFO] /opt/chef is mounted on device <dev>. Proceeding with migration.
Failure while processing flag `fstab`, Error: error during mount migration:
  failed to mount <dev> to /hab: exit status 32.
```

Every kitchen-dokken container bind-mounts `/opt/chef` in from the `chef/chef` data container, so
this fires 100% of the time in Dokken CI on any converge that reaches the migration path. That is
exactly what broke the `multi-version` suite on every Linux platform: the FIRST install takes the
`--fresh-install` path (fstab never processed) but binlinks `chef-client` onto `$PATH`, so the
SECOND install in the same converge takes the migration path and dies. `remove-omnibus`/`default`/
`preserve-omnibus`/`scheduler-fix` never hit it because they only ever install once per converge.

The `fstab_handling` property defaults to `ignore` whenever `preserve_omnibus` is true (preserving
the omnibus install and moving its filesystem out from under it are contradictory) and to
migrate-ice's own `apply` otherwise. Do not drop the flag or make it unconditional `apply`; do not
"fix" this by forcing `--fresh-install` on the upgrade path instead — `--fresh-install` refuses to
run when a chef-client is already installed, so it would silently no-op and never extract the new
version.

**`execute[migrate-ice apply airgap]` carries `retries 3` / `retry_delay 5`** to work around an
upstream migrate-ice/Go-runtime GC race (`fatal error: lfstack.push ... created by
runtime.gcBgMarkStartWorkers`, exit code 2) that occurs under CPU-constrained/virtualized/emulated
environments while extracting the ~160MB airgap tarball, regardless of flag values or
`GOMAXPROCS`. The retry is the correct fix — do not attempt to fix this by altering
fresh-install/preserve-omnibus logic or disabling GC tuning.

## Scheduler Resource Reconvergence (in-place, no process handoff, all platforms)

After a successful install + binlink, the `install` resource re-runs any already-declared
`chef_client_cron`/`chef_client_launchd`/`chef_client_systemd_timer`/`chef_client_scheduled_task`
resources, explicitly setting their `chef_binary_path` to the resolved, fully-versioned Habitat path
(`ChefClientUpdaterEnterprise::Helpers#chef_client_hab_binary_path`) before re-running their
already-declared `action`. No process handoff (re-exec or exit) is involved, on any platform.

**Do NOT point `chef_binary_path` at the mutable `/usr/bin/chef-client` binlink symlink.** The
scheduler resources re-resolve `chef_binary_path` at every *scheduled* invocation (not just at
converge time), running as root/SYSTEM — a writable, well-known symlink there is a standing local
privilege-escalation target between chef-client runs. The fully-versioned Habitat path points
directly at the immutable, Habitat-verified package payload instead.

This does not risk pointing at a version `cleanup` later removes: `install` and `cleanup` are
separate resources and Chef executes resources in declaration order, so reconvergence always
re-points `chef_binary_path` at the newly installed version **before** `cleanup` runs in the same
converge. A schedule can only end up referencing a removed version if `update_scheduler_resources`
is disabled or reconvergence is otherwise bypassed.

**The fix must explicitly SET `chef_binary_path` — resetting the property is not enough.** An
older bootstrap chef-client's `chef_binary_path` default can be a plain, non-lazy, hardcoded legacy
path (not a `lazy {}` block at all), so `Property#reset` (which only forces a *default* to
re-evaluate) changes nothing. Even for a genuinely lazy default, `Property#get` only re-evaluates
while the property remains unset — the first read caches the evaluated result. Explicitly setting
the property bypasses whatever default logic exists, regardless of the bootstrap Chef version.

**`chef_client_hab_binary_path` takes the resource's `version` property, not just `pkg`, and
resolves the PINNED version rather than always defaulting to `hab_pkg_dirs(pkg).last` (newest on
disk).** Multiple `chef/chef-infra-client` versions can coexist under `/hab/pkgs`; a user
explicitly pinning `version` to an older release (e.g. rolling back a regression) must not have
their schedule silently repointed at a newer version still on disk. `version: 'latest'` (the
default) resolves to `.last`; any explicit version string filters to that specific version/release.

Declaration order relative to `chef_client_updater_enterprise_install` does not matter — Chef fully
compiles the resource collection before convergence begins, so the scheduler resource is always
already present when `reconverge_scheduler_resources` runs. **Gotcha**: inside a custom resource's
`action_class`, `run_context` is a CHILD `RunContext` scoped to that action's own declarations —
only `run_context.root_run_context.resource_collection` reaches the full, shared collection.

**History**: this replaced an earlier `Kernel.exec`/`exit(213)` process handoff, which deadlocked
on Windows (MRI's `Kernel.exec` can't truly replace a process there, so the parent stays alive
holding Chef's run-lock). In-place reconvergence avoids the run-lock entirely and needs no second
chef-client run, on any platform.

The reconvergence `ruby_block` runs with `action :run` **unconditionally on every converge**, not
gated behind a notification from the package-install step. An earlier, notification-based design
only fired when chef-ice was actually installed/upgraded *in that converge* — so on any later,
otherwise-unrelated converge, the scheduler resources' own stale default silently reverted
`chef_binary_path` back to the legacy omnibus path with nothing left to correct it. Running the
block unconditionally means idempotency is determined purely by whether the scheduler resources'
own underlying content already matches; `resolved_binary_path` only changes when the package it
resolves to changes (a new install for `version: 'latest'`, or never for an explicitly pinned
version), so this can never itself introduce a false "not idempotent" result.

## Cleanup Removal Uses Direct `hab pkg uninstall`, Not `habitat_package`

`chef_client_updater_enterprise_cleanup` removes old Habitat versions via a plain `execute`
(`hab pkg uninstall <origin>/<name>/<version>/<release>`, the full ident), not Chef's built-in
`habitat_package` resource. Do not "simplify" this back without re-verifying on a live
multi-version Kitchen suite.

**The bug this works around:** `Chef::Provider::Package::Habitat#installed_version` determines
"installed" by running `hab pkg path <bare origin/name>` (no version qualifier) — Habitat's notion
of the *current/active* package, not "does this specific version exist on disk." When multiple
`chef/chef-infra-client` versions coexist, this can report an older, still-present version as "not
installed," so `habitat_package action :remove` silently no-ops instead of removing it.

**The fix:** drive `hab pkg uninstall` directly against the full ident, bypassing
`habitat_package`'s idempotency check. Each `execute` is named uniquely per ident and guarded with
`only_if { File.directory?(...) }` against the actual package directory for that version/release.
`HAB_LICENSE=accept-no-persist` is supplied via `environment` to avoid an interactive license
prompt. The Habitat ident backing the currently-running `chef-client` process is excluded from
`to_remove` before any `execute` resources are declared (`running_hab_ident` in
`resources/cleanup.rb`).

Both `hab_binary` and the full `ident` are shell-escaped (`Shellwords#shellescape`) before
interpolation into the `command` string — `new_resource.habitat_package` is a user-configurable
`String` with no format validation.

`spec/unit/resources/cleanup_spec.rb` asserts against the declared `execute["remove Habitat
package <full-ident>"]` resources and their `command` content directly, not a ChefSpec
package-resource matcher.

## Chef Core Idempotency-Reporting Bugs to Watch For (Windows)

Two Chef-core built-in resources misreport idempotency on converge #2 even when nothing changed:

- **`windows_env` create/delete have no built-in idempotency** — both actions unconditionally
  rewrite/remove every converge. The transient `CHEF_LICENSE_KEY` env-var pair in
  `resources/install.rb` is guarded with `not_if { msi_already_current }` on both actions. Any
  future one-shot `windows_env` bracketing an idempotent operation needs the same guard.
- **`windows_path`'s `:add` action never propagates its inner `env` sub-resource's "no change"
  status** — the outer resource still counts as "updated" even when the nested `env "path"` is
  `(up to date)`. `resources/binlinks.rb`'s `windows_path 'C:\hab\bin'` works around this with an
  explicit `not_if` that reads the live Machine `PATH` (via `Win32::Registry`, falling back to
  `ENV['PATH']`) and checks case-insensitively for `C:\hab\bin`.

**General pattern**: treat any Chef-core resource with internally-nested sub-resources as suspect
for idempotency-reporting on converge-twice checks, and guard independently with `not_if`/`only_if`.

**Without reconvergence** (`update_scheduler_resources false`), a scheduler resource declared
before chef-ice is binlinked bakes a stale path in permanently. Separately, `cleanup` only excludes
the currently-*running* Habitat ident from removal — once a lagging pinned version is no longer
"running," cleanup removes it like any other old version, breaking any schedule still pointing at
it.

## Binlinks

`hab pkg binlink` creates symlinks for all package binaries: `/usr/bin/` on Linux/macOS, `.bat`
shims in `C:\hab\bin\` on Windows (added to system PATH via `windows_path`).

The `:remove` action is a no-op that logs a warning — Habitat has no bulk unbinlink command; manual
symlink cleanup is required.

The `:create` action's `execute` MUST stay idempotent on every platform: `migrate-ice apply airgap`
already creates the binlink as a side effect of install, so `binlink_current?`/
`binlink_current_windows?` (the resource's `not_if`) is satisfied immediately and `hab pkg binlink`
never actually re-runs in practice. Linux/macOS check via `File.symlink?`/`File.readlink`; Windows
binlinks are generated `.bat` shims (not true symlinks, so `File.symlink?` is always false) and
instead check whether the shim's content already references the resolved install path
(`binlink_current_windows?`). Do not remove either `not_if` guard.

## Local Dokken CI Testing (Apple Silicon / general)

`kitchen.dokken.yml`'s `provisioner.clean_dokken_sandbox: false` is **required, permanent** —
kitchen-dokken defaults to wiping the bind-mounted `/opt/kitchen` sandbox (backing
`Chef::Config[:file_cache_path]`) after every converge, which breaks idempotency for
`cookbook_file[mixlib-install.gem]`/`remote_file[chef-ice-*]` on both local and GitHub Actions
runners.

To test Dokken suites locally on Apple Silicon, force the container architecture via
kitchen-dokken's driver `platform` option — `DOCKER_DEFAULT_PLATFORM` does NOT work (kitchen-dokken
uses the `docker-api` gem's raw socket calls, not the `docker` CLI, which is the only thing that
honors that env var). Temporarily add to `kitchen.dokken.yml`'s `driver:` block:

```yaml
driver:
  platform: linux/amd64
```

Revert before committing — GitHub Actions Linux runners are already native x86_64. Since this repo
sets `KITCHEN_LOCAL_YAML=kitchen.dokken.yml` explicitly (bypassing Test Kitchen's usual
`kitchen.local.yml` auto-merge), temporary edits must go directly into `kitchen.dokken.yml`.

`CHEF_LICENSE_KEY` is a public GitHub Actions repository **variable** (not secret) — retrieve it
for local reproduction via `gh variable get CHEF_LICENSE_KEY --repo <owner>/<repo>`.
