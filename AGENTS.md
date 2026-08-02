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

- **`chef-ice`** — The `product_name` for `mixlib-install` API calls and the native OS package
  name (rpm/deb/msi). Used by the `install` and `remove_omnibus` resources.
- **`chef/chef-infra-client`** — The Habitat package identifier. Used by the `binlinks` resource
  for `hab pkg binlink`, and by the `cleanup` resource (via a filesystem glob under
  `/hab/pkgs/`, not the `hab` CLI, for listing) and Chef's built-in `habitat_package` resource for
  removal.

Do not use `chef/chef-ice` as a Habitat identifier. Do not use `chef/chef-infra-client` as a
`mixlib-install` product name.

## Dependency Management

`mixlib-install` is not a metadata `depends` entry or a Gemfile dependency. It is installed at
compile time via `chef_gem` inside the `install` resource's `action_class`. Do not add it to
`metadata.rb`. This avoids version conflicts with the gem bundled in Chef Workstation.

Use `Policyfile.rb` for dependency resolution. Do not reintroduce Berkshelf files.

## Unit Testing (ChefSpec/RSpec)

`spec/unit/` holds fast ChefSpec/RSpec tests (run via `chef exec rspec`, no Gemfile needed — Chef
Workstation bundles ChefSpec/RSpec). This cookbook has no `recipes/` directory, so `ChefSpec::
SoloRunner#converge_block` alone never registers its custom resources (Chef only compiles library/
resource files for cookbooks named in the run_list — see `Chef::RunContext::CookbookCompiler#
cookbook_order`). `spec/spec_helper.rb`'s `converge_resource` helper works around this via
`spec/fixtures/cookbooks/chefspec_shim`, a throwaway cookbook that `depends` on this one and has a
single empty recipe; converging it pulls this cookbook's resources into `cookbook_order` without
executing any of its actual resource actions.

`testing/` (this cookbook's real parent directory) is deliberately **not** used as ChefSpec's
`cookbook_path` — it also contains a `clone_chef_client_updater_enterprise` sibling with the same
cookbook name, which Chef's `CookbookLoader` refuses to merge. Instead, `spec/fixtures/cookbooks/
chef_client_updater_enterprise/{metadata.rb,resources,libraries}` are individual **per-file**
symlinks back to this cookbook's real files. Do not replace these with directory-level symlinks:
`Dir.glob` (what Chef's cookbook loader uses) does not recurse into symlinked directories, only
symlinked files, so `resources`/`libraries` must stay real directories containing per-file symlinks.
**Whenever a resource or library file is added, removed, or renamed, add/update the matching symlink
under `spec/fixtures/cookbooks/chef_client_updater_enterprise/`** — `spec/unit/fixture_sync_spec.rb`
fails loudly if the symlinked set drifts from the real one.

Since `chef_client_updater_enterprise_*` are custom resources, ChefSpec treats them as opaque no-ops
unless told to `step_into` them — `converge_resource` defaults `step_into` to all four so their
`action_class` code actually executes. When asserting on multiple same-named built-in resources
declared with different property values (e.g. `cleanup`'s `habitat_package 'x' { version v; action
:remove }` per version removed), do not use ChefSpec's `.with(property: value)` chained matcher: it
looks up by `(type, name)` only and only ever inspects the *last* declared match. Filter
`chef_run.resource_collection.all_resources` directly instead (see `removed_habitat_versions` in
`spec/unit/resources/cleanup_spec.rb`).

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

Linux uses the native `package '<legacy_omnibus_package>' do action :remove end` (idempotent,
proper up-to-date reporting) rather than shelling out to `rpm`/`dpkg` directly. An earlier version
avoided the native resource over a concern that `dnf_package`'s `dnf_helper.py` (bundled with the
`chef` gem itself, resolved relative to whichever gem is currently loaded — see
`Chef::Provider::Package::Dnf::PythonHelper::DNF_HELPER`) might be missing after `migrate-ice`. That
concern doesn't apply here: removal only ever runs once we're already confirmed to be running under
chef-ice (see the `running_under_omnibus?` guard below), so the currently-loaded chef gem — and
therefore `dnf_helper.py` — is chef-ice's own bundled copy, never the (possibly-altered) omnibus
one.

The resource defers (logs a warning and returns) rather than acting when either:
- The currently running `chef-client` process is itself executing from the legacy omnibus install
  (`running_under_omnibus?`) — removing the files a running process is executing from would break
  the converge.
- No `chef-ice` Habitat package is installed yet (`hab_pkg_dirs(habitat_package)` is empty) — the
  omnibus fallback should never be torn down before its Habitat-based replacement is confirmed
  present.

When `remove_directories` is true, it also deletes:

- Linux/macOS: `/opt/chef` only (not `/opt/chef-ice` — chef-ice has no such directory; its payload
  lives under `/hab/pkgs/`)
- Windows: `C:\opscode\chef`
- macOS: runs `pkgutil --forget com.chef.chef` only if that receipt is currently registered

**Windows package uninstall discovers the display name first, then uses `windows_package`.**
`Chef::Provider::Package::Windows::RegistryUninstallEntry.find_entries` (Chef core) matches the
Programs-and-Features *display* name via **exact string equality**, not the `legacy_omnibus_package`
property value (`chef`, which only applies to the rpm/dpkg native package name in the Linux branch)
— the omnibus MSI registers as `Chef Infra Client v<version>`, and that version varies per box. The
`legacy_omnibus_display_name` helper runs `Get-Package -Name 'Chef Infra Client*'` (wildcard search,
via `shell_out` with argv-array form to avoid shell quoting/injection) to discover the exact
currently-installed display name, filtering out anything matching `chef-ice`/`air-gapped` since
chef-ice's own MSI entry also starts with `Chef Infra` — a broader wildcard risks matching it too.
That discovered name is then passed to `windows_package '<discovered name>' do action :remove end`
for native, idempotent removal. Do not "simplify" this back to a hardcoded name or to reusing
`new_resource.legacy_omnibus_package` directly — neither will match the registry entry.

**History — why the `remove-omnibus` Test Kitchen suite needs a second chef-client pass.** Before
the `Kernel.exec`/`exit(213)` process handoff was replaced with in-place scheduler resource
reconvergence (see "Scheduler Resource Reconvergence" below), that handoff had an unrelated side
effect: it forced a second, full chef-client run under chef-ice within the same `kitchen converge`,
which is when `remove_omnibus`'s deferred deletion actually completed. Without it, `running_under_
omnibus?` stays true for the entire lifetime of the converging process, so a single converge can
never complete the removal — this is expected, not a bug, and is why `kitchen.yml`'s `remove-omnibus`
suite carries a `lifecycle: post_converge:` hook that runs a second, genuinely separate chef-client
invocation directly against the cookbook's own stable binlink path (`chef_client_binlink_path`),
bypassing Test Kitchen's own executable-discovery (`chef_client_path`/`find_chef_executable` in
`kitchen-chef-enterprise`) entirely. That discovery mechanism resolves `config[:chef_client_path]`
(defaulting to the omnibus path) once per `kitchen converge` invocation and would otherwise keep
resolving back to omnibus forever, since removal is gated on the same "not running under omnibus"
check the discovery mechanism itself would never flip. `multiple_converge` cannot substitute for
this either — it chains N chef-client invocations against a single executable path resolved once,
not per invocation, so it can never pick up chef-ice mid-chain. Do not remove this hook or attempt
to make `remove_omnibus` complete in a single converge; that would require changing its guard logic,
which is deliberately out of scope (see the resource description above).

## Platform Support

`metadata.rb` declares broad OS-family support via `supports` (amazon, centos, debian, fedora,
mac_os_x, opensuseleap, oracle, redhat, suse, ubuntu, windows). Actual Kitchen-tested platforms are
narrower and currently: `almalinux-9` (Vagrant) / `rhel-9` (EC2) as the RHEL proxy,
`opensuse-leap-15` and `opensuse-leap-16` as the SLES/SUSE proxy, `ubuntu-2404`, and `windows-2022`.
`kitchen.yml` (Vagrant/local) and `kitchen.ec2.yml` (live EC2, used via
`KITCHEN_LOCAL_YAML=kitchen.ec2.yml`) must keep matching platform names — `kitchen.ec2.yml` has no
`provisioner:` key and inherits it from `kitchen.yml` via Test Kitchen's recursive config merge, but
`platforms:` are looked up by matching `name:`, so a platform added to one file without the other
simply won't be runnable in that mode.

Do not add a platform to any one of `metadata.rb`, `kitchen.yml`, `kitchen.ec2.yml`, or the README
without also confirming `mixlib-install` publishes `chef-ice` artifacts for it.

**`kitchen-ec2` (the gem) has NO built-in `opensuse` `Aws::StandardPlatform` support** (only
rhel/centos/alma/rocky/debian/ubuntu/amazon/amazon2/amazon2023/fedora/windows/macos/freebsd are
registered). When a platform name isn't recognized, `Ec2#default_ami` silently falls back to
`Aws::StandardPlatform.from_platform_string(self, "ubuntu")` — **no error, no warning** — so an
`opensuse-leap-*` EC2 platform without an explicit `image_id` will silently boot an Ubuntu AMI
instead (confirmed live: `Detected platform: ubuntu version 26.04` in kitchen logs for an
`opensuse-leap-16` instance). `kitchen.ec2.yml`'s `opensuse-leap-16` entry therefore pins an
explicit `image_id`. General rule: any future non-standard platform name added to
`kitchen.ec2.yml` must pin `image_id` explicitly unless it's one of kitchen-ec2's registered
families above.

**openSUSE Leap 15.6 reached upstream EOL (2026-04-30) and its AWS AMI has been fully delisted**
from `us-west-2` (confirmed via `aws ec2 describe-images` returning zero results across every
owner). `opensuse-leap-15` has been removed from `kitchen.ec2.yml` entirely for this reason — it
remains testable via Dokken only (container image availability is independent of AMI delisting).

**Running the full Dokken + EC2 matrix concurrently (multiple `kitchen converge` processes against
the same checkout) can corrupt/race `Policyfile.lock.json`** — `chef-cli install`/`update`
read-modify-write that file with no interprocess locking, so 2+ concurrent converges produced a
transient `NoMethodError: undefined method '[]' for nil`. Always run matrix-style multi-platform
Kitchen testing fully serially (one `kitchen converge` at a time) against a single checkout, or use
per-combo checkout copies if parallelism is required.

## Preserving Multiple Installed Versions

`chef-ice` packages (rpm, deb, and MSI) each bundle a `migrate-ice` tool that the native package
manager's own install transaction invokes unconditionally, with no supported flag to add
`--preserve-omnibus` or avoid deleting a previously installed version's Habitat directory. The
`install` resource works around this per-platform so that installing a newer `chef-ice` version
never deletes an older one still on disk, and the legacy omnibus install (if present) is preserved
when `preserve_omnibus` is true:

- **RHEL family (RHEL, Amazon Linux, Fedora, SLES/SUSE):** Uses Chef's `rpm_package` resource
  directly (bypassing `dnf`/`yum`) with `--replacefiles --noscripts --nodigest`. `--noscripts`
  suppresses the RPM's `%post` scriptlet (which always runs `migrate-ice` without
  `--preserve-omnibus`); the resource then runs `migrate-ice` itself via a separate `execute`
  resource. `--nodigest` is required in addition: `chef-ice`'s published RPM builds are always
  built on an Amazon Linux 2 builder regardless of the target platform requested from
  mixlib-install (confirmed live: `p=fedora`/`p=el`/`p=amazon` all resolve to the byte-identical
  `chef-ice-*.amzn2.x86_64.rpm`, same sha256) and lack a modern per-file payload digest. Whether
  that's rejected depends on the installed `rpm` binary's own `_pkgverify_level` default: rpm 4.x
  (RHEL/Alma/Rocky 8/9, Amazon Linux) tolerates it silently, but Fedora 44's bundled rpm 6.0.2
  defaults to `_pkgverify_level=digest` and hard-fails with `package ... does not verify: no
  digest`. `--nodigest` disables only this specific payload-digest check — it does NOT skip the
  SHA256 checksum already verified independently via `remote_file`'s `checksum` property, and does
  not affect GPG signature verification (already skipped via `--noscripts`). Do not switch this
  back to `package`/`dnf_package`/`yum_package` — those frontends erase a previous NEVRA's entire
  file tree (including its versioned Habitat directory) as part of an upgrade transaction, which
  can delete the very files the currently-running chef-client process is executing from mid-converge.
- **Debian family:** Drives `dpkg --unpack` then `dpkg --configure` directly, temporarily stubbing
  `migrate-ice` (and, on upgrades, the previous package's `postrm`, which unconditionally
  `rm -rf /hab`s under certain conditions) between the two phases. `dpkg -i` has no `--noscripts`
  equivalent, so this two-phase approach is required to intercept the maintainer scripts.
- **Windows:** Uses `windows_package` with `installer_type :msi`. Each `chef-ice` release has a
  distinct MSI `ProductCode`/`UpgradeCode`, so side-by-side installs are already safe without any
  special handling — only the `CHEF_PRESERVE_OMNIBUS=1` MSI property (via `options`) is needed,
  which the package's embedded `PostInstall.ps1` forwards to `migrate-ice`. This property only
  exists on `chef-ice` builds from ~2026-04-23 onward; older MSI releases always migrate
  destructively. MSI installs can take 7-13 minutes — `timeout` defaults to `1800`.

Do not "simplify" any of this back to a plain `package`/`dnf_package`/`apt_package` resource without
re-verifying (ideally on a live multi-version Kitchen suite) that a previous version's files survive
an upgrade — this exact regression is what these workarounds fix.

## `migrate-ice apply airgap`'s `--fresh-install` Flag Is Conditional, Not Unconditional

`chef_client_updater_enterprise_install`'s `execute[migrate-ice apply airgap]` resource decides
whether to pass `--fresh-install` based on `chef_client_on_path?` (in `libraries/helpers.rb`), NOT
unconditionally. This mirrors migrate-ice's OWN internal "is chef-client already installed?"
detection exactly, which shells out to `chef-client` via `$PATH` (confirmed via
`/var/log/chef19migrate.log` and direct binary testing against a live EC2 instance) rather than
checking for `/opt/chef` on disk:

- **`chef-client` on `$PATH`** (true for native package installs of omnibus Chef on real
  VMs/EC2 — `/usr/bin/chef-client`, etc.): migrate-ice's non-fresh-install path runs a normal,
  correctly-behaved migration — detects the existing version, extracts the bundle, populates
  `/hab/pkgs`, and fully respects `--preserve-omnibus true` by gracefully logging `/opt/chef is
  not mounted. Skipping --fstab flag handling.` rather than erroring, in the (overwhelmingly
  common) case where `/opt/chef` is not its own dedicated mount point.
- **`chef-client` NOT on `$PATH`** (normal for minimal Dokken/CI container images that invoke the
  bootstrap chef-client by full path): the non-fresh-install path's own installed-check fails, so
  `--fresh-install` is required to skip that check and just extract the bundle unconditionally.

**Both branches exit 0 either way** — this is exactly why getting it wrong went undetected for a
while: an earlier version of this cookbook unconditionally passed `--fresh-install`, which silently
no-ops on every EC2/native-VM converge where `chef-client` is resolvable via `$PATH`, leaving
`/hab/pkgs` permanently empty. That in turn made `execute[migrate-ice apply airgap]`'s own `not_if`
guard (checking `hab_pkg_dirs`) never satisfiable, so it re-ran (harmlessly but pointlessly, and
looking like a `NOT_IDEMPOTENT` bug) on every single subsequent converge, forever. Confirmed
root-caused via direct SSH onto a live EC2 `preserve-omnibus` instance (both `rhel-9` and
`ubuntu-24.04`): `/hab/pkgs/chef/chef-infra-client/` did not exist despite rpm/dpkg correctly
reporting chef-ice installed. NOT reproducible on Dokken, whose minimal images never have
`chef-client` on `$PATH` to begin with — this asymmetry (EC2-only failure, Dokken always clean) was
the initial clue.

Do not go back to unconditionally passing `--fresh-install`, and do not gate the flag on
`File.directory?('/opt/chef')` either (that reintroduces the older, now-removed mount-remount
failure mode this comment used to warn about) — `chef_client_on_path?` is the one check that matches
migrate-ice's own internal logic exactly.

**End-to-end verification (live EC2, full Kitchen converge+reconverge cycle):** Confirmed on
`preserve-omnibus-ubuntu-2404` — first converge installed chef-ice and correctly populated
`/hab/pkgs`; a second, independent converge reported `Infra Phase complete, 0/15 resources updated`
(fully idempotent, `execute[migrate-ice apply airgap]` correctly skipped via its `not_if`). Note: an
early version of the ad-hoc verification harness used for this check had its own bug — a naive
`grep -qE "[1-9][0-9]* resources updated"` false-positived on the `15` in `0/15 resources updated`
(total resource count, not the updated count), misreporting a fully idempotent run as
`NOT_IDEMPOTENT`. Fixed by anchoring the regex to `Infra Phase complete, [1-9][0-9]*/[0-9]+ resources
updated`. Not a cookbook bug — a lesson for anyone else scripting Kitchen-log-based idempotency
checks against this cookbook's `Infra Phase complete, X/Y resources updated` output format.
`preserve-omnibus-rhel-9` initially failed three consecutive times at the `chef_infra` provisioner's
own initial omnibus Chef v18 bootstrap step (`kitchen.yml`'s `product_version: 18`) — before any of
this cookbook's resources run at all — with a transient `Omnitruck artifact does not exist for
version 18 on platform el` 404 from `chefdownload-commercial.chef.io`, despite the identical metadata
URL succeeding reliably via direct `curl` from the orchestrating machine at the same time. On a
fourth attempt (fresh AWS session), bootstrap succeeded cleanly and the full converge+reconverge+
verify cycle passed: converge 1 installed chef-ice 19.3.15 (6/11 resources updated), converge 2
reported `0/11 resources updated` (fully idempotent, `migrate-ice apply airgap` skipped via
`not_if`), and `kitchen verify` passed all 9 InSpec checks (chef-client 19.3.15 correctly binlinked
at `/usr/bin/chef-client`, `/opt/chef` legacy omnibus preserved). This confirms the three earlier
404s were transient EC2-instance-side DNS/network flakiness reaching that endpoint during
provisioning, not a cookbook or omnitruck-service bug — retry if this recurs.

## Scheduler Resource Reconvergence (in-place, no process handoff, all platforms)

After a successful install + binlink, the `install` resource re-runs any
`chef_client_cron`/`chef_client_launchd`/`chef_client_systemd_timer`/`chef_client_scheduled_task`
resources already declared in the run_list's resource collection, explicitly setting their
`chef_binary_path` property to the resolved, immutable, fully-versioned Habitat path
(`ChefClientUpdaterEnterprise::Helpers#chef_client_hab_binary_path`, e.g.
`/hab/pkgs/chef/chef-infra-client/19.3.15/20260601120000/bin/chef-client`) before re-running their
already-declared `action`. No process handoff (re-exec or exit) of any kind is involved, on any
platform.

**Do NOT point `chef_binary_path` at `chef_client_binlink_path` (the mutable `/usr/bin/chef-client`
symlink)** — an earlier version of this fix did exactly that, reasoning it would "just work" across
future upgrades since `hab pkg binlink --force` repoints that symlink automatically. That reasoning
is true for pure idempotency/upgrade-tracking purposes, but it introduces a real local
privilege-escalation window: `chef_client_cron`/`chef_client_systemd_timer`/`chef_client_launchd`/
`chef_client_scheduled_task` all re-resolve their configured `chef_binary_path` fresh at every
*scheduled* invocation (not just at chef-converge time), running as root/SYSTEM. A writable,
well-known symlink sitting at that path is a standing target for the entire interval between
chef-client runs — anyone able to repoint or replace `/usr/bin/chef-client` gets arbitrary
root code execution on the next scheduled run, with no chef-client convergence involved at all.
The fully-versioned Habitat path has no such window: it points directly at the immutable,
Habitat-verified package payload, not a symlink indirection layer this cookbook itself maintains.

This does not reopen the "stale version after cleanup" problem that pointing at a versioned path
might suggest: `reconverge_scheduler_resources` runs as part of *every* successful install/upgrade
(see below), always re-pointing `chef_binary_path` at the newly installed version's resolved path
**before** `chef_client_updater_enterprise_cleanup` ever runs — `install` and `cleanup` are declared
as two separate resources in the run_list and Chef executes resources in declaration order, so by
the time `cleanup` removes old Habitat versions, the schedule has already been repointed at the new
one in the same converge. A schedule can only end up referencing a version `cleanup` later removes
if `update_scheduler_resources` is disabled, or reconvergence is otherwise bypassed — the same
responsibility boundary already documented on that property.

**The fix must explicitly set `chef_binary_path` — it cannot rely on resetting or re-reading
whatever default the resource would otherwise compute.** Confirmed via direct inspection of the
actual chef-client gem bootstrapping the converge (whatever Test Kitchen/production installs as a
starting point — e.g. the `stable` channel's 18.11.11): `chef_client_scheduled_task`'s
`chef_binary_path` there is a plain, non-lazy, **hardcoded legacy path**
(`"C:/#{LEGACY_CONF_DIR}/#{DIR_SUFFIX}/bin/#{CLIENT}"` — no `lazy {}` at all). Newer Chef Infra
Client releases (e.g. whatever chef-ice itself ships, confirmed via `chef/chef`'s
`lib/chef/resource/helpers/path_helpers.rb`) instead default `chef_binary_path` to a lazy,
hab-aware `Chef::ResourceHelpers::PathHelpers.chef_client_hab_binary_path` block that resolves
`File.realpath($PROGRAM_NAME)` — i.e., the *currently running* process's own resolved path. We
deliberately do not rely on that upstream default either, even post-migration: it only produces the
right answer when the process reading it is itself the Habitat-installed chef-client, which is not
guaranteed for every caller/context in this cookbook's own reconvergence step, so
`chef_client_hab_binary_path(pkg)` (this cookbook's own helper, in `libraries/helpers.rb`) resolves
the same shape of path directly from the Habitat package store instead of relying on
`$PROGRAM_NAME`. Since this cookbook's entire purpose is migrating *from* an unknown, potentially
old bootstrap chef-client, we cannot assume the resource's own default is lazy or hab-aware at all —
resetting a property (`Property#reset`) only forces a *default* to re-evaluate, and if that default
is a hardcoded string, resetting changes nothing. Explicitly setting the property bypasses whatever
default logic exists entirely, so it works identically regardless of the bootstrap Chef version's
implementation.

**`chef_client_hab_binary_path` takes the resource's `version` property, not just `pkg`, and must
resolve the PINNED version rather than always defaulting to `hab_pkg_dirs(pkg).last` (newest on
disk).** Multiple `chef/chef-infra-client` versions can legitimately coexist under `/hab/pkgs`
(see "Preserving Multiple Installed Versions" above), and a user explicitly pinning
`chef_client_updater_enterprise_install`'s `version` property to an OLDER release — e.g. to work
around a regression discovered in the latest one — is a supported, expected operation, not just an
upgrade path. If reconvergence always resolved to `.last`, a user who intentionally rolled back to
an older version would have their schedule silently repointed at a *newer* version still sitting on
disk from an earlier run, undoing the rollback they just performed for the running chef-client
process while leaving the schedule pointed at the version they were trying to avoid. `version:
'latest'` (the resource's own default) still resolves to `hab_pkg_dirs(pkg).last`; any other
explicit version string filters to that specific version/release pair instead.


Declaration order relative to `chef_client_updater_enterprise_install` does not matter: Chef fully
compiles the resource collection for the entire run_list before convergence begins (`lib/chef/
client.rb`'s Phase 2/Phase 3 separation), so the scheduler resource is always already present by
the time our `reconverge_scheduler_resources` helper runs, regardless of where in the recipe it was
declared. `test/cookbooks/.../recipes/scheduler_fix.rb` deliberately declares its scheduler resource
*before* `chef_client_updater_enterprise_install` to prove this. **Gotcha**: `run_context` accessed
from inside a custom resource's `action_class` is a CHILD `RunContext` scoped to that action's own
nested declarations (empty of sibling recipe-level resources, even in `unified_mode`) — only
`run_context.root_run_context.resource_collection` reaches the full, shared, recipe-level
collection; `run_context.resource_collection` alone will find nothing.

**History — why this replaced a Kernel.exec/exit(213) process handoff.** An earlier version of this
resource actually re-executed chef-client (`Kernel.exec(handoff_bin, *ARGV)` on Linux/macOS) or
exited with a Test Kitchen-recognized code (`exit(213)` on Windows, since Windows' `Kernel.exec`
can't truly replace a process — MRI spawns-and-waits instead of using `execve()`, so the parent
stays alive holding Chef's own run-lock, deadlocking the freshly spawned child against its own
still-running parent; confirmed live via 45+ minute EC2 hangs). That entire mechanism is no longer
needed, on any platform: reconverging the scheduler resource in-place solves the exact same problem
without ever touching the run-lock, without depending on an orchestrator honoring Test Kitchen's
`retry_on_exit_code: [35, 213]` convention (which real production systems have no equivalent of),
and without a second chef-client run at all.

**History — an earlier version of *this same reconvergence redesign* tried to avoid explicitly
setting `chef_binary_path`,** reasoning that Chef's lazy property defaults are never memoized after
the first read (true, per `Property#get`/`#stored_value_to_output` in `lib/chef/property.rb`) and
that simply re-running the resource's action would be enough to let its own unmodified default
re-evaluate. That reasoning was incomplete: `Property#get` only re-evaluates a lazy default on
every read while the property remains *unset* on the resource instance; the very first read stores
the *already-evaluated result* (not the lazy block) onto the resource, so every subsequent read
before an explicit reset just returns that cached value — and, as established above, an older
bootstrap chef-client's default may not even be lazy at all, in which case no amount of resetting
helps. Confirmed live on Windows: `windows_task` reported `(up to date)` (no change) with the old
approach even after explicitly calling `Property#reset`, and only started reporting
`task updated` once `chef_binary_path` was explicitly set instead.

The reconvergence `ruby_block` runs with `action :run` **unconditionally on every converge** (not
gated behind a notification from the package-install step) — this was the second, previously
undetected bug found via live Dokken testing of the `scheduler-fix` suite: an earlier version wired
this via `notifies :run, ..., :immediately` from the platform-specific package-install resources
(`rpm_package`/the `dpkg --configure` `execute`/`windows_package`/`package`) with the block itself
declared `action :nothing`. Those install resources are properly idempotent and only report a
change (thus only fire the notification) when chef-ice is actually installed/upgraded *in that
converge*. That looked correct for the initial migration, but on any *later*, otherwise-unrelated
converge — no chef-ice change, so no notification — the individually-declared
`chef_client_cron`/`chef_client_systemd_timer`/etc. resources (with no explicit `chef_binary_path`
in the calling recipe) still re-run their own previously-declared action every converge regardless,
re-evaluating their own stale built-in default and silently reverting `chef_binary_path` back to
the legacy omnibus path — with nothing left to correct it, since the notification that would fix it
never fires again. Confirmed live: `scheduler-fix-almalinux-9`'s second (idempotency-check)
converge flipped `/etc/cron.d/chef-client` and `/etc/systemd/system/chef-client.service` straight
back from the correct `/usr/bin/chef-client` to `/opt/chef/bin/chef-client`, breaking both
idempotency and the actual schedule.

Running the `ruby_block` every converge instead means `reconverge_scheduler_resources` always
re-asserts `resolved_binary_path` on the scheduler resources' `chef_binary_path`, so whether this
run is "idempotent" is determined purely by whether the individual scheduler resources' own
underlying templates/cron_d/systemd_unit/scheduled_task content already matches. `resolved_binary_path`
(from `chef_client_hab_binary_path`) only changes when a genuinely new chef-ice version is
installed — it always resolves to the newest installed version's directory — so this can never
itself introduce a false "not idempotent" result on an otherwise-unrelated converge. The individual
`notifies :run, 'ruby_block[...]', :immediately` declarations on the package-install resources and
on `chef_client_updater_enterprise_binlinks` have been removed entirely — they're now fully
redundant (the block already runs every converge unconditionally) and kept the misleading
appearance of being load-bearing.

## Chef Core Idempotency-Reporting Bugs to Watch For (Windows)

Two Chef-core built-in resources were found, live on EC2 `windows-2022`, to misreport idempotency
in ways that made this cookbook's own resources look "not idempotent" on converge2 even though
nothing had actually changed:

- **`windows_env` create/delete pairs have zero built-in idempotency of their own** — `:create`
  unconditionally rewrites the variable and `:delete` unconditionally removes it, every converge,
  regardless of current state. The `CHEF_LICENSE_KEY` env-var pair (used only transiently, to pass
  the license into chef-ice's MSI `PostInstall.ps1`) in `resources/install.rb` is guarded with a
  `msi_already_current = pkg_version && installed_version == pkg_version` local and `not_if {
  msi_already_current }` on both the `:create` and `:delete` resources. Any future one-shot
  `windows_env` bracketing an idempotent operation needs the same kind of explicit guard.
- **`Chef::Resource::WindowsPath`'s `:add` action never propagates its inner sub-resource's
  "no change" status.** It wraps a nested `env "path" { action :modify }` internally
  (`lib/chef/resource/windows_path.rb`, part of Chef core) — confirmed live via logs showing
  `windows_env[path] action modify (up to date)` nested directly under `windows_path[C:\hab\bin]
  action add`, while the OUTER `windows_path` resource still counted as "updated" toward the
  converge's resource-update total. `resources/binlinks.rb`'s `windows_path 'C:\hab\bin'` resource
  works around this with an explicit `not_if` block that reads the live Machine `PATH` via
  `Win32::Registry` (falling back to `ENV['PATH']`) and checks case-insensitively whether
  `C:\hab\bin` is already present.

**General pattern**: any Chef-core built-in resource that internally declares its own nested
sub-resources should be treated with suspicion for idempotency-reporting correctness on
converge-twice checks, and independently guarded with `not_if`/`only_if` against the actual
desired end-state rather than trusted to self-report "no change" correctly.

Without reconvergence (`update_scheduler_resources false`), a scheduler resource declared while
chef-ice isn't yet binlinked bakes a stale/fallback path into its cron_d/plist/systemd-unit/
scheduled-task permanently, since nothing else would ever cause it to re-evaluate. One additional
concrete consequence to be aware of regardless of this setting:

`chef_client_updater_enterprise_cleanup` always excludes `running_hab_ident` from removal (see
`resources/cleanup.rb`), but "running" can mean a version several releases behind the newest
installed one. Once that lagging version is no longer "running", cleanup treats it as just
another old version and removes it — breaking any schedule that still references it.

## Binlinks

`hab pkg binlink` creates symlinks for all package binaries. On Linux and macOS these land in
`/usr/bin/`. On Windows they become `.bat` shims in `C:\hab\bin\`, and the resource adds that
directory to the system PATH via `windows_path`.

The `:remove` action on the binlinks resource is a no-op that logs a warning. Habitat does not
provide a bulk unbinlink command. Manual symlink cleanup is required if binlinks need to be removed.

The `:create` action's `execute` resource MUST be idempotent on every platform — it is otherwise
harmless if it reports a change on every converge, since (per the "Scheduler Resource
Reconvergence" section above) the reconvergence `ruby_block` now runs unconditionally every
converge and no longer depends on any notification from `binlinks`. It remains idempotent
regardless: `migrate-ice apply airgap` already creates the
binlink as a side effect of install, so this resource's own `not_if` (`binlink_current?`/
`binlink_current_windows?`) is satisfied immediately and it never actually re-runs `hab pkg
binlink` in practice. On Linux/macOS,
idempotency uses `File.symlink?`/`File.readlink`. On Windows, binlinks are generated `.bat` shim
files rather than true symlinks (`File.symlink?` is always false), so idempotency instead checks
whether the shim's script content already references the resolved package's install path
(`binlink_current_windows?` in `resources/binlinks.rb`). Do not remove either `not_if` guard.

## migrate-ice: `--fresh-install` is now conditional (see section above), not unconditional

**This section previously documented "always pass `--fresh-install`" — that guidance was wrong and
has been superseded by the "`migrate-ice apply airgap`'s `--fresh-install` Flag Is Conditional, Not
Unconditional" section above.** Kept here (condensed) only to explain what changed and why, since
the original reasoning below was based on incomplete testing at the time (Dokken-only, never
confirmed against a live EC2/native-VM run where `chef-client` really is on `$PATH`).

The original reasoning: `migrate-ice`'s non-fresh-install path decides whether an existing Chef
Client installation exists by shelling out to `chef-client -v` via `$PATH`
(`IsChefClientInstalled` in `lib/chef_package/chef_client_install.go`, part of
`chef/migration-tools`, the private source-available repo for the `migrate-ice` binary). On Dokken,
where `chef-client` is invoked by full path and never added to `$PATH`, that check returns false,
so the non-fresh path just no-ops harmlessly — meaning `--fresh-install` really was required there.

**What was missed:** on EC2/native VMs, `chef-client` genuinely IS on `$PATH` (native package
installs put it there), so the non-fresh-install path's `IsChefClientInstalled` check succeeds and
the migration proceeds *correctly*, extracting the bundle and fully respecting
`--preserve-omnibus true` by gracefully skipping fstab handling when `/opt/chef` isn't its own
mount (logged as `/opt/chef is not mounted. Skipping --fstab flag handling.`) — confirmed live via
direct manual invocation on a real EC2 instance. The mount-remount failure this section originally
warned about is real but only triggers when `/opt/chef` genuinely is a dedicated mount, which is a
supported-but-uncommon customer configuration, not the default case this section implied.

Passing `--fresh-install` unconditionally instead causes the OPPOSITE problem on EC2/native VMs:
migrate-ice's fresh-install path detects `chef-client` IS installed (it checks this internally too)
and refuses to run at all — logging "chef-client has been detected on the system... run the tool
without the --fresh-install flag" and exiting 0 without extracting anything. `/hab/pkgs` is left
permanently empty, and `execute[migrate-ice apply airgap]`'s own `not_if` guard can never be
satisfied, so it looks like a never-idempotent resource re-running every converge — this is exactly
the `preserve-omnibus` EC2 `NOT_IDEMPOTENT` bug that led to root-causing this whole issue. See the
section above for the actual current (correct) behavior: `chef_client_on_path?` decides the flag.

## Local Dokken CI Testing (Apple Silicon / general)

`kitchen.dokken.yml`'s `provisioner.clean_dokken_sandbox: false` is a **required, permanent**
setting, not a testing convenience. kitchen-dokken's provisioner (`clean_dokken_sandbox` defaults to
`true` upstream) deletes the entire bind-mounted `/opt/kitchen` sandbox directory (which backs
`Chef::Config[:file_cache_path]`) after **every single converge**. Any resource whose idempotency
depends on that cache dir persisting across separate `kitchen converge` invocations — here,
`cookbook_file[mixlib-install.gem]` and `remote_file[chef-ice-*.rpm/.deb/.msi]` — can never be
idempotent under the default setting, on real GitHub Actions x86_64 runners just as much as locally.
This was the root cause of the CI "idempotency check" step failing; it is not a bug in
`cookbook_file`/`remote_file`, which were correctly detecting the (actually-absent, post-wipe)
on-disk state each time.

To test Dokken suites locally on Apple Silicon (arm64 host), kitchen-dokken's driver `platform`
config option must be used to force the container architecture — setting the `DOCKER_DEFAULT_PLATFORM`
environment variable does **not** work, because kitchen-dokken creates containers via the
`docker-api` Ruby gem (raw Docker socket API calls), not the `docker` CLI, and that env var is only
honored by the CLI. Temporarily add to `kitchen.dokken.yml`'s `driver:` block:

```yaml
driver:
  platform: linux/amd64
```

and revert it before committing — real GitHub Actions Linux runners are already native x86_64, so
this line is a local-only testing aid, never a permanent fix like `clean_dokken_sandbox: false`
above. `kitchen.local.yml` is normally auto-merged by Test Kitchen for exactly this kind of local
override, but this repo's workflow and local testing both set `KITCHEN_LOCAL_YAML=kitchen.dokken.yml`
explicitly, which replaces that lookup entirely — so temporary edits must go directly into
`kitchen.dokken.yml` since there is no other local-override mechanism available given that env var
usage.

`CHEF_LICENSE_KEY` is stored as a public GitHub Actions repository **variable** (not secret) on this
repo, retrievable for local reproduction via
`gh variable get CHEF_LICENSE_KEY --repo <owner>/<repo>` — no need to ask for a secret to test
locally.
