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

## Preserving Multiple Installed Versions

`chef-ice` packages (rpm, deb, and MSI) each bundle a `migrate-ice` tool that the native package
manager's own install transaction invokes unconditionally, with no supported flag to add
`--preserve-omnibus` or avoid deleting a previously installed version's Habitat directory. The
`install` resource works around this per-platform so that installing a newer `chef-ice` version
never deletes an older one still on disk, and the legacy omnibus install (if present) is preserved
when `preserve_omnibus` is true:

- **RHEL family (RHEL, Amazon Linux, Fedora, SLES/SUSE):** Uses Chef's `rpm_package` resource
  directly (bypassing `dnf`/`yum`) with `--replacefiles --noscripts`. `--noscripts` suppresses the
  RPM's `%post` scriptlet (which always runs `migrate-ice` without `--preserve-omnibus`); the
  resource then runs `migrate-ice` itself via a separate `execute` resource. Do not switch this
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

## Scheduler Resource Reconvergence (in-place, no process handoff, all platforms)

After a successful install + binlink, the `install` resource re-runs any
`chef_client_cron`/`chef_client_launchd`/`chef_client_systemd_timer`/`chef_client_scheduled_task`
resources already declared in the run_list's resource collection, explicitly setting their
`chef_binary_path` property to the resolved stable binlink path (`chef_client_binlink_path`) before
re-running their already-declared `action`. No process handoff (re-exec or exit) of any kind is
involved, on any platform.

**The fix must explicitly set `chef_binary_path` — it cannot rely on resetting or re-reading
whatever default the resource would otherwise compute.** Confirmed via direct inspection of the
actual chef-client gem bootstrapping the converge (whatever Test Kitchen/production installs as a
starting point — e.g. the `stable` channel's 18.11.11): `chef_client_scheduled_task`'s
`chef_binary_path` there is a plain, non-lazy, **hardcoded legacy path**
(`"C:/#{LEGACY_CONF_DIR}/#{DIR_SUFFIX}/bin/#{CLIENT}"` — no `lazy {}` at all; the hab-aware, disk
sensitive `chef_client_hab_binary_path` lazy default is only present in newer Chef Infra Client
releases, e.g. whatever chef-ice itself ships). Since this cookbook's entire purpose is migrating
*from* an unknown, potentially old bootstrap chef-client, we cannot assume the resource's own
default is lazy or hab-aware at all — resetting a property (`Property#reset`) only forces a
*default* to re-evaluate, and if that default is a hardcoded string, resetting changes nothing.
Explicitly setting the property bypasses whatever default logic exists entirely, so it works
identically regardless of the bootstrap Chef version's implementation.

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

The reconvergence fires on **every** successful install/upgrade that changes chef-ice — not just the
initial omnibus-to-chef-ice migration. The `:immediately` notification to the `ruby_block` is wired
from the platform-specific package-install resource in `action :install` (`rpm_package`/the `dpkg
--configure` `execute`/`windows_package`/the generic `package` fallback), each of which is properly
idempotent and only reports a change when chef-ice was actually installed/upgraded in that converge;
the `ruby_block`'s own `only_if` checks `update_scheduler_enabled && File.exist?(handoff_bin)`.

**Do NOT wire this notification to `chef_client_updater_enterprise_binlinks` as the primary
trigger** — a prior version of this cookbook did exactly that, and it is silently, permanently
broken: `migrate-ice apply airgap` (the `execute` resource that runs right before `binlinks` in
`action :install`) already creates the correct `hab pkg binlink` symlink as a side effect of every
install. That means `binlinks`' own idempotency check (`binlink_current?`/
`binlink_current_windows?` in `resources/binlinks.rb`) is satisfied *immediately*, on every single
converge, including the very first install — so `binlinks` never reports "updated" and the
notification never fires. This was confirmed live: every `scheduler-fix` Test Kitchen suite run
baked the stale omnibus `chef_binary_path` (e.g. `/opt/chef/bin/chef-client`, old version) into
`chef_client_cron`/`chef_client_systemd_timer` because the reconvergence silently never executed. The
notification on `chef_client_updater_enterprise_binlinks` is still declared as a harmless redundant
backup, but it should never be relied on as the primary trigger.

Without reconvergence, a scheduler resource declared (and converged) while chef-ice hadn't yet been
binlinked bakes a stale/fallback path into its cron_d/plist/systemd-unit/scheduled-task permanently,
since nothing else would ever cause it to re-evaluate. Two concrete consequences if reconvergence is
disabled (`update_scheduler_resources false`):

1. A scheduler resource declared while chef-ice isn't yet binlinked bakes a stale path into its
   cron_d/plist/systemd-unit/scheduled-task, and nothing corrects it without a later reconverge.
2. `chef_client_updater_enterprise_cleanup` always excludes `running_hab_ident` from removal (see
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
Reconvergence" section above) the reconvergence's primary notification comes from the
package-install resources, not from `binlinks`. It remains idempotent regardless: `migrate-ice apply airgap` already creates the
binlink as a side effect of install, so this resource's own `not_if` (`binlink_current?`/
`binlink_current_windows?`) is satisfied immediately and it never actually re-runs `hab pkg
binlink` in practice. On Linux/macOS,
idempotency uses `File.symlink?`/`File.readlink`. On Windows, binlinks are generated `.bat` shim
files rather than true symlinks (`File.symlink?` is always false), so idempotency instead checks
whether the shim's script content already references the resolved package's install path
(`binlink_current_windows?` in `resources/binlinks.rb`). Do not remove either `not_if` guard.
