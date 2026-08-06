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

Chef's `use` directive auto-prepends an underscore when resolving partial filenames. The single
partial file on disk is named `_partials.rb`, but the reference in a resource must be
`use 'partials'`. Using `use '_partials'` would resolve to `__partials.rb` and raise a `NameError`
at converge time.

Correct — every resource in this cookbook opens with exactly this line:

```ruby
use 'partials'  # resolves to resources/_partials.rb
```

`_partials.rb` holds only the two properties genuinely shared by all four resources,
`habitat_package` and `version`. Everything else lives on the resource that owns it — notably
`license_key`, `channel` and `product_name`, which are `install`-only. Do not split this back into
several partials unless a property is actually shared; a partial used by one resource is just
indirection.

Both shared properties carry validation that the rest of the cookbook depends on:

- `habitat_package` is `regex`-constrained to a bare `origin/name` ident. `cleanup.rb` must still
  shell-escape it (see "Cleanup Removal Uses Direct `hab pkg uninstall`" below) — the regex is
  defense in depth and an early, actionable error, not the security control.
- `version` is `coerce`d so any casing of `latest` normalizes to lowercase `latest`. Several call
  sites compare it against that literal (`install.rb`, `binlinks.rb`,
  `Helpers#chef_client_hab_binary_path`). Before the coerce those comparisons disagreed:
  `install.rb` used a case-sensitive `== 'latest'` while `binlinks.rb` used `.downcase`, so
  `version 'Latest'` was treated as an explicitly pinned version named "Latest" by one resource and
  as "newest installed" by the other. Do not remove the coerce and do not reintroduce ad-hoc
  `.downcase` calls at the comparison sites.

The `use` partial DSL requires Chef Infra Client >= 17.0. This constraint is enforced in
`metadata.rb` via `chef_version '>= 17.0'`.

## Property `desired_state`

Properties that describe **how** to reach the desired state — credentials, download tuning,
behavior toggles — are marked `desired_state: false` so they stay out of
`state_for_resource_reporter` and why-run output: `license_key`, `download_dir`, `download_url`,
`checksum`, `download_retries`, `download_retry_delay`, `manage_binlinks`,
`update_scheduler_resources`, `preserve_omnibus`, `fstab_handling` (`install`); `force`
(`binlinks`); `remove_directories` (`remove_omnibus`).

Properties that describe **what** the system should look like stay in the default
`desired_state: true`: `product_name`, `version`, `channel`, `habitat_package`,
`legacy_omnibus_package`, `keep_versions`.

Note this is a semantics/reporting concern, not a secrets control — `sensitive: true` already
substitutes `"*sensitive value suppressed*"` in `Chef::Resource#state_for_resource_reporter`, and
`license_key` carries both. `spec/unit/resources/install_spec.rb` asserts the split so it cannot
silently drift.

## Package Identity

Two distinct package identities are used in this cookbook. Mixing them up will break installs:

- **`chef-ice`** — The `install` resource's `product_name` property. It is simultaneously the
  Commercial Download API product key and the native OS package name (rpm/deb/msi). Used only by
  the `install` resource. The `remove_omnibus` resource deliberately does NOT touch it — it acts on
  its own separate `legacy_omnibus_package` property (default `chef`).
- **`chef/chef-infra-client`** — The Habitat package identifier (the `habitat_package` property in
  `resources/_partials.rb`). Used by the `binlinks` resource for `hab pkg binlink`, and by the
  `cleanup` resource (via a filesystem glob under `/hab/pkgs/`, not the `hab` CLI, for listing;
  removal is driven directly via `hab pkg uninstall` with the full ident, not Chef's built-in
  `habitat_package` resource — see "Cleanup Removal Uses Direct `hab pkg uninstall`, Not
  `habitat_package`" below for why).

Do not use `chef/chef-ice` as a Habitat identifier. Do not use `chef/chef-infra-client` as a
Commercial Download API product key.

## Dependency Management

This cookbook has NO runtime gem dependencies and no metadata `depends` entries. Package metadata
is fetched straight from Chef's Commercial Download API (see below). Do not reintroduce
`mixlib-install` — neither as a `metadata.rb` dependency, a Gemfile entry, nor a vendored
`files/default/*.gem` installed via `chef_gem`.

Use `Policyfile.rb` for dependency resolution. Do not reintroduce Berkshelf files.

## Package Metadata Comes From the Commercial Download API, Not mixlib-install

`ChefClientUpdaterEnterprise::Helpers#commercial_artifact_metadata` (`libraries/helpers.rb`) does a
single GET against `https://chefdownload-commercial.chef.io/<channel>/<product>/metadata` and
returns the only three values this cookbook ever needed: `url`, `sha256` and the resolved
`version`. See <https://docs.chef.io/download/commercial/>.

This replaced the `mixlib-install` gem, which required vendoring a 51 KB binary
`files/default/mixlib-install.gem` into the cookbook and installing it via a compile-time
`chef_gem`. Do not go back to it.

**`direct=true` is required, not cosmetic.** Without it the API returns its `/download` handler URL,
whose path carries no package extension. `resources/install.rb` derives the package type from that
path (see "Package Type Comes From the Download URL" below) and hard-fails on a URL it cannot
derive one from, so a missing `direct=true` is now a loud error rather than a silent skip of
checksum verification. With `direct=true` the API returns the `/files/...` URL ending in the real
`.rpm`/`.deb`/`.msi` filename, and the advertised sha256 matches the response body byte-for-byte
(verified against a live 161 MB download).

**There is no client-side platform-version logic to reimplement, because `pv` is discarded.**
`DynamoServices#ProductMetadata` sets `params.PlatformVersion = ""` before the database lookup and
does not list it in its validation flags. Verified live: for `p=el`, omitting `pv` and sending `9`,
`9.4`, `7`, `99` or `garbage` all return the identical artifact. `pv` is still sent because the API
documents it, but `Helpers#download_api_platform_info` passes Ohai's raw `platform_version` through
untouched. Do not reintroduce derivation logic there (major-version truncation, `amazon 2` → `el 7`,
and so on) — it looks meaningful but cannot change the response. chef-ice also publishes exactly one
artifact per platform-family/architecture, so there is no compatibility fallback to reimplement.

**`pm` (package format) is deliberately NOT sent.** It is optional, and omnitruck-service derives
the package format from the platform (`p`) it is already being told about. A locally-guessed `pm`
could only ever agree with `p` redundantly or disagree with it harmfully, so there is nothing to
gain by sending one. Do not reintroduce a `package_manager:` argument to
`commercial_artifact_metadata`.

## Platform Names Sent to the Commercial Download API

`Helpers#download_api_platform_info` exists for exactly one reason: **the API rejects platform names
that are not in its own lookup table.** omnitruck-service derives the package format from `p` via
`clients/omnitruck/package_manager_mapping.go`, and a name missing from that map fails the request:

```text
HTTP 400 {"message":"Unable to derive package manager for platform 'almalinux'"}
```

Verified live against `chefdownload-commercial.chef.io`:

- **Rejected:** `almalinux`, `oracle`, `oracleserver`, `scientific`, `xenserver`, `opensuse`.
- **Accepted verbatim:** `el`, `redhat`, `centos`, `rocky`, `fedora`, `amazon`, `suse`, `sles`,
  `opensuseleap`, `debian`, `ubuntu`, `linuxmint`, `windows`.

So the helper is a small alias table (`DOWNLOAD_API_PLATFORM_ALIASES`) covering only the rejected
names; everything else is Ohai's `node['platform']` passed straight through. Keeping it minimal is
deliberate — remapping a name the API already accepts just creates a second source of truth that can
drift.

**This is not hypothetical.** `almalinux` is `kitchen.yml`'s primary RHEL proxy and `oracle` is in
the Dokken matrix; without the alias both fail with a 400 before anything is downloaded.

**Passing `pm` explicitly does not avoid the need for this.** Supplying `pm` skips the derivation
step, but the unrecognized platform name still reaches the database lookup, which then fails with
`{"message":"Product information not found."}` instead. Verified live with `p=almalinux&pm=rpm`.

`mac_os_x` is an accepted platform name but returns `Product information not found` because chef-ice
publishes no macOS artifact. That is the expected outcome, not a mapping bug.

`spec/unit/libraries/helpers_spec.rb` pins both lists, so a future edit that "simplifies" the alias
table fails there rather than in a live converge.

**The license key travels in the query string, so every error path must scrub it.** `license_id` is
also required on the `/files` URL itself (fetching it without one returns 403), which is why the
`remote_file` that downloads the package stays `sensitive true`. `commercial_api_get` routes all
failures through `scrub_license_key` before raising; keep it that way when touching this code.

**A new release is advertised by the API before it is downloadable everywhere.** The artifact has
to propagate to the caller's nearest CDN edge; until it does, that edge returns 403/404 or a short
error body with a 200. Windows MSIs are the most affected. `resources/install.rb` handles this with
`retries`/`retry_delay` on the `remote_file` (tunable via the `download_retries` /
`download_retry_delay` properties, default 5 x 30s) PLUS a `verify` block.

**Both halves are required — `remote_file`'s `checksum` property does NOT verify a download.** It
is only an idempotency short-circuit that compares an ALREADY-PRESENT local file
(`Chef::Provider::RemoteFile::Content#current_resource_matches_target_checksum?`); nothing checks
what actually came off the wire. Without the `verify` block, a CDN error page served with a 200
would be passed straight to rpm/dpkg/msiexec. Do not drop the `verify` block on the grounds that
`checksum` is already set.

## Package Type Comes From the Download URL, Not the Node's Platform

`Helpers#package_extension_from_url` parses the URL the artifact is actually fetched from and
returns its file extension (`rpm`/`deb`/`msi`/`dmg`/`pkg`, per `PACKAGE_EXTENSIONS`), which
`resources/install.rb` uses to build the local staging filename under `download_dir`.

Both code paths always have a full file URL to work from: the Commercial Download API is queried
with `direct=true` specifically so it returns the `/files/...` URL ending in the real artifact
filename, and a user-supplied `download_url` points at a package file on a local mirror.

**Do not reintroduce a platform-derived extension guess.** It duplicated knowledge the URL already
carries and could silently disagree with it — staging an `.msi` as `chef-ice-19.3.15.rpm` hands rpm
a file it cannot install, with a confusing error. `URI#path` excludes the query string and
fragment, so presigned/CDN URLs carrying `?X-Amz-...` or `?license_id=...` parameters resolve
correctly.

A URL whose path does not end in a known package extension raises
`Chef::Exceptions::ValidationFailed` naming the accepted extensions. The message is built from the
URL with its query string stripped, so a `license_id` parameter never reaches the log. Returning nil
for such a URL is also what detects an API `/download` handler URL, whose response body would not
match the advertised sha256.

Retrying is safe: verification runs on the staged tempfile before it is moved into place, so a
rejected body never becomes the cached artifact, and `CacheControlData.load_and_validate` discards
its saved etag/mtime whenever they don't match the local file — the retry re-downloads in full
instead of being answered with a 304.

**`license_key` is typed `[String, NilClass]`, not `String`.** Its default resolves to nil whenever
`CHEF_LICENSE_KEY` is unset, and the `download_url` path legitimately never needs a key — with a
bare `String` type, merely READING the property raised `Chef::Exceptions::ValidationFailed`, which
broke the documented airgapped/local-file-server workflow. Callers that do need a key go through
`validate_license!`.

**Requests go through `Chef::HTTP::Simple`, not `Net::HTTP` directly**, so they honor the same
`Chef::Config` proxy settings as `remote_file`. Transient network errors and 5xx responses are
retried (3 attempts); 4xx responses are not, since a bad license or unknown version will never
succeed on retry.

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

The `license_key` property on the `install` resource is marked `sensitive: true` (and
`desired_state: false`). The `remote_file` resource that downloads the package artifact, the
`execute[migrate-ice apply airgap]` resource, and the Windows `windows_env[CHEF_LICENSE_KEY ...]`
resource are all `sensitive: true` too. Together these keep key material out of Chef logs, resource
diffs, and `state_for_resource_reporter` output. `Helpers#scrub_license_key` covers the remaining
path — Commercial Download API failures, whose URLs carry `license_id` as a query parameter.

## Why These Resources Do Not Use `converge_if_changed` / `converge_by`

This has been evaluated against the Chef 19.3.15 source and deliberately rejected. Do not
re-propose it without re-reading this section.

Every action in this cookbook works by **declaring inner Chef resources** (`rpm_package`,
`execute`, `windows_package`, `file`, `windows_path`, `ruby_block`) rather than by performing
filesystem/shell work inline. That choice is what gives the cookbook per-step idempotency
reporting, why-run support and `not_if`/`only_if` guards for free — and it is fundamentally
incompatible with `converge_if_changed`/`converge_by`, because of an ordering asymmetry:

- `ConvergeActions#add_action` (`lib/chef/mixin/why_run.rb`) **yields immediately** unless
  `Chef::Config[:why_run]` is set. So a `converge_by`/`converge_if_changed` block body executes
  inline, at the point it appears in the action.
- `Chef::Provider#compile_and_converge_action` (`lib/chef/provider.rb`) builds a child
  `RunContext`, `instance_eval`s the *entire* action body to collect declared sub-resources, and
  only then calls `runner.converge`.

**Consequence: any plain Ruby in an action body — including everything inside `converge_by` — runs
BEFORE every sub-resource that action declares, regardless of source order.** Mixing the two
silently inverts the intended sequence.

Concretely, converting `binlinks`' `:create` to `converge_if_changed` would require rewriting the
whole action imperatively: the stale-file deletion, the `directory 'C:\hab\bin'` creation, the
`hab pkg binlink` `execute`, and a hand-rolled reimplementation of what `windows_path` does to the
Machine `PATH` registry value. That trades four well-tested, individually-reported, why-run-aware
built-in resources for one opaque block. It would make the resource less robust, not simpler.

`converge_by` is also redundant here for the same reason: the declared sub-resources already report
their own status, so wrapping them would double-report a single change.

`load_current_value` is likewise a poor fit. It runs once when the action starts, whereas this
cookbook's state checks (`binlink_current?`, `hab_pkg_dirs`, `current_native_version`) must be
evaluated at each sub-resource's own converge time — `install` can install a package *during* the
same converge, so a value loaded up front would already be stale. That is exactly why those checks
live in `not_if`/`only_if` guards and `lazy {}` blocks.

## Unified Mode

All resources set `unified_mode true`. This keeps resources declared inside an `action_class`
method or an action body evaluating in the correct converge order. Do not remove
`unified_mode true` from any resource.

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

**Keep that hook scoped to the `remove-omnibus` suite — never move it to `kitchen.yml`'s top
level.** Test Kitchen's lifecycle-hook `includes`/`excludes` match on PLATFORM name only
(`Kitchen::LifecycleHook::Base#should_run?`), so a top-level hook cannot skip a suite; it re-runs
every suite's recipe. That is fatal for `multi-version`, which installs an older version, then a
newer one, then lets `cleanup` remove the older: a second pass sees the older version missing,
reinstalls it over the newer one, and kills the chef-client process executing out of it
(`Docker Exec (135)`).

Two things keep every other suite from needing a second pass, and both must hold:

- **No suite except `remove-omnibus` may declare `chef_client_updater_enterprise_remove_omnibus`.**
  It defers deletion on the first converge, so any recipe declaring it needs a second pass to
  finish, and CI's own Habitat-backed second run would otherwise be the thing performing the
  deferred `/opt/chef` deletions — reporting resources as updated and failing the
  `Infra Phase complete, 0/N resources updated` assertion. The `default` recipe used to declare it
  and was moved off it for exactly this reason.
- **Nothing may install a gem at converge time.** The compile-time `chef_gem[mixlib-install]` used
  to be installed into the newly running chef-ice's own gem set on its first run there, so every
  suite reported `2/N resources updated` on the second run (the `chef_gem` plus its wrapping custom
  resource). Removing `mixlib-install` entirely removed that whole class of failure — do not
  reintroduce a runtime gem install (see "Dependency Management").

The hook's platform filters must list every Windows platform name in use across all kitchen
configs (`windows-2022`/`windows-11` in `kitchen.yml`, `windows-latest`/`localhost` in
`kitchen.proxy.yml`) — a Windows platform missing from the `excludes` list gets the Linux
`sh -c` variant.

**`remove-omnibus` is excluded from the CI idempotency check's second top-level `kitchen
converge`** — `kitchen-dokken` hardcodes `chef_binary: "/opt/chef/bin/chef-client"` for every
top-level converge, but this suite deletes `/opt/chef` by the end of the first one, so a second
top-level converge fails with `Errno::ENOENT`. This is expected, not a missed check: the suite's
own `post_converge` hook already re-exercises idempotency via the stable chef-ice binlink on every
converge. Do not remove this CI exclusion or try to make a second top-level converge work here.

## Platform Support

`metadata.rb` declares broad OS-family `supports`, but actual Kitchen-tested platforms are narrower
and differ per driver, because each driver has a different set of usable images:

- `kitchen.dokken.yml` — the broad Linux matrix (Amazon Linux 2023, AlmaLinux 8/9/10, Debian 12/13,
  Fedora latest, openSUSE Leap 15/16, Oracle Linux 8/9/10, Rocky Linux 8/9/10, Ubuntu
  22.04/24.04/26.04). No Windows.
- `kitchen.yml` (Vagrant, the default) — AlmaLinux 9/10, openSUSE Leap 15/16, Ubuntu 24.04/26.04,
  Windows Server 2022, Windows 11.
- `kitchen.ec2.yml` (`KITCHEN_LOCAL_YAML=kitchen.ec2.yml`) — RHEL 9/10, openSUSE Leap 16, Ubuntu
  24.04/26.04, Windows 11, Windows Server 2022/2025.

**Platform names are NOT identical across these files** — Vagrant uses `ubuntu-2404` while EC2 uses
`ubuntu-24.04`, and EC2 substitutes `rhel-9`/`-10` for Vagrant's AlmaLinux proxies. Only `suites:`
and `provisioner:` are inherited from `kitchen.yml` via Test Kitchen's recursive merge;
`platforms:` are matched by name, so a suite runs against whatever platform names the active file
declares.

**Consequence: any platform-name list inside `kitchen.yml` must cover the union of all three
files' names.** The `remove-omnibus` suite's `post_converge` lifecycle hook has one `remote:` for
Linux and one for Windows, discriminated by `excludes:`/`includes:` on platform name — a Windows
platform name present only in `kitchen.ec2.yml` but missing from those lists would silently run the
Linux `sh -c` variant and fail. Both lists must therefore enumerate every Windows platform name
used by any driver (`windows-2022`, `windows-2025`, `windows-11`, `windows-latest`, `localhost`).

Do not add a platform anywhere without confirming the Commercial Download API publishes `chef-ice`
artifacts for it (`GET /<channel>/chef-ice/metadata?p=&pv=&m=` returns HTTP 400 when it does not).
`chef-ice` currently publishes no macOS artifact, so the `mac_os_x` code paths in the resources are
declared-but-untested.

**`kitchen-ec2` has no built-in `opensuse` `Aws::StandardPlatform` support.** An unrecognized
platform name silently falls back to an Ubuntu AMI with no error — `kitchen.ec2.yml`'s
`opensuse-leap-16` entry therefore pins an explicit `image_id`. Any future non-standard platform
name added to `kitchen.ec2.yml` must do the same unless it's one of kitchen-ec2's registered
families (rhel/centos/alma/rocky/debian/ubuntu/amazon/amazon2/amazon2023/fedora/windows/macos/freebsd).

**openSUSE Leap 15.6 is EOL and its AWS AMI is delisted** — `opensuse-leap-15` has been removed
from `kitchen.ec2.yml`. It is still present in `kitchen.yml` (Vagrant) and `kitchen.dokken.yml`.

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
  (independently enforced by the `remote_file`'s `verify` block — NOT by its `checksum` property,
  which only decides whether to re-fetch an already-present file) or GPG verification (already
  skipped via `--noscripts`). Do not switch back to `package`/`dnf_package`/`yum_package` — those
  erase a previous NEVRA's entire file tree (including its Habitat directory) during an upgrade.
- **Debian family:** Drives `dpkg --unpack` then `dpkg --configure` directly, temporarily stubbing
  `migrate-ice` (and, on upgrades, the previous package's `postrm`, which can `rm -rf /hab`)
  between the two phases — `dpkg -i` has no `--noscripts` equivalent. The stub → `dpkg --configure`
  → restore sequence is one `ruby_block` with a `begin/ensure`, not three separate resources; see
  "Debian Stub/Restore Must Stay In One `ruby_block`" below.
- **Windows:** Uses `windows_package` (`installer_type :msi`). Each release has a distinct MSI
  `ProductCode`/`UpgradeCode` so side-by-side installs are already safe; only the
  `CHEF_PRESERVE_OMNIBUS=1` MSI property is needed (forwarded to `migrate-ice` by the package's
  `PostInstall.ps1`). Only present on `chef-ice` builds from ~2026-04-23 onward — older MSIs always
  migrate destructively. MSI installs can take 7-13 minutes, well past `windows_package`'s 600s
  default, so the resource hardcodes `timeout 1800`. This is not a cookbook property — there is no
  `timeout` property on `chef_client_updater_enterprise_install`.

Do not simplify any of this back to a plain `package`/`dnf_package`/`apt_package` resource without
re-verifying on a live multi-version Kitchen suite that a previous version's files survive an
upgrade.

## Debian Stub/Restore Must Stay In One `ruby_block`

On the Debian path, `resources/install.rb` stubs `/hab/migration/bin/migrate-ice`, runs
`dpkg --configure`, and restores the real binary inside a **single** `ruby_block` whose body wraps
the `shell_out!` in `begin/ensure`. Do not split this back into three separately declared Chef
resources.

Chef has no cross-resource `ensure`. When `dpkg --configure` fails the run aborts, and a
separately-declared "restore" resource never converges — leaving `migrate-ice` as a permanent
`#!/bin/sh\nexit 0` stub on disk. Every subsequent converge would then run
`execute[migrate-ice apply airgap]` against that stub, which exits 0 without extracting anything:
chef-ice would report a clean, successful install forever while `/hab/pkgs` stayed empty. The
`ensure` still re-raises, so a genuine dpkg failure continues to fail the converge.

A separate self-heal `ruby_block` reclaims a backup stranded by an even harder failure (reboot,
SIGKILL). It runs **before** `dpkg --unpack`, deliberately: restoring afterwards would overwrite
the newly unpacked release's `migrate-ice` with the previous release's copy. It is also
deliberately not guarded by `dpkg_already_current` — a stranded backup must be reclaimed whether or
not this converge goes on to install anything.

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

**`execute[migrate-ice apply airgap]` carries `retries 5` / `retry_delay 10`** to work around an
upstream migrate-ice/Go-runtime GC race (`fatal error: lfstack.push ... created by
runtime.gcBgMarkStartWorkers`, exit code 2) that occurs under CPU-constrained/virtualized/emulated
environments while extracting the ~160MB airgap tarball, regardless of flag values or
`GOMAXPROCS`. The retry is the correct fix — do not attempt to fix this by altering
fresh-install/preserve-omnibus logic or disabling GC tuning.

## Scheduler Resource Reconvergence (in-place, no process handoff, all platforms)

Whenever a converge actually installs a new chef-ice version, the `install` resource re-runs any
already-declared `chef_client_cron`/`chef_client_launchd`/`chef_client_systemd_timer`/
`chef_client_scheduled_task` resources, explicitly setting their `chef_binary_path` to the
resolved, fully-versioned Habitat path
(`ChefClientUpdaterEnterprise::Helpers#chef_client_hab_binary_path`) before re-running their
already-declared `action`. The sole purpose is to point an existing schedule at the
newly-installed client so its next *scheduled* run uses it. No process handoff (re-exec or exit) is
involved, on any platform.

**Do NOT point `chef_binary_path` at the mutable `/usr/bin/chef-client` binlink symlink.** The
scheduler resources re-resolve `chef_binary_path` at every *scheduled* invocation (not just at
converge time), running as root/SYSTEM — a writable, well-known symlink there is a standing local
privilege-escalation target between chef-client runs. The fully-versioned Habitat path points
directly at the immutable, Habitat-verified package payload instead.

This does not risk pointing at a version `cleanup` later removes: `install` and `cleanup` are
separate resources and Chef executes resources in declaration order. The delayed notification is
registered in `install`'s own child `RunContext`, so `Chef::Runner#converge` drains it at the end
of `install`'s action (not at the end of the whole chef-client run) — reconvergence always
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

The reconvergence `ruby_block` is declared `action :nothing` and is driven **only** by delayed
notifications from the resources that represent "chef-ice was actually installed or upgraded in
*this* converge". This is deliberate and is the entire intended scope of the feature: the schedule
only needs rewriting when a new chef-ice version actually landed. `migrate-ice apply airgap`
carries a `not_if` that is satisfied once `pkg_version` is present under `/hab/pkgs`, so a
steady-state converge does not run it, does not notify, and does not reconverge any schedule.

**The notification must be wired per platform, not just to `execute[migrate-ice apply airgap]`.**
That `execute` is guarded by `only_if { ::File.exist?('/hab/migration/bin/migrate-ice') }`, a
Linux-only path — on Windows it never runs, because the MSI's own embedded `PostInstall.ps1` custom
action invokes migrate-ice inside the msiexec transaction instead. The Windows `package`
(`windows_package`) resource and the generic non-RHEL/non-Debian `package` fallback therefore carry
the same `notifies :run, 'ruby_block[reconverge installed scheduler resources]', :delayed`. Both
are natively idempotent (a DisplayName/version registry lookup on Windows), so they only notify on a
real install and converge-twice idempotency is preserved. Chef de-duplicates delayed notifications
by resource+action, so a platform where both the package resource and the migrate-ice `execute`
fire still reconverges exactly once. Do not remove either notification — without the Windows one, a
`chef_client_scheduled_task`'s `chef_binary_path` is never repointed at the newly installed client.

Do not "fix" this by switching the block to an unconditional `action :run`. `ruby_block` reports
"updated" whenever its block runs — `Chef::Provider::RubyBlock` wraps the call in an unconditional
`converge_by` and discards the block's return value — so an unconditional `action :run` would
report a changed resource on every converge forever and break the CI converge-twice idempotency
check. For the same reason `reconverge_scheduler_resources` does not compute an
updated-or-not return value; there is nothing that could consume one.

This resource is not a general-purpose repair mechanism for a `chef_binary_path` that drifted for
some unrelated reason, and it does not re-assert the path on converges where nothing was installed.
The only other entry point is the early return at the top of `action :install` (an explicitly
pinned version that is already installed), which calls `reconverge_installed_scheduler_resources`
directly in Ruby because it returns before the `ruby_block` is ever declared.

**History**: an earlier design used `Kernel.exec`/`exit(213)` process handoff, which deadlocked on
Windows (MRI's `Kernel.exec` can't truly replace a process there, so the parent stays alive holding
Chef's run-lock). In-place reconvergence avoids the run-lock entirely and needs no second
chef-client run, on any platform.

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
interpolation into the `command` string. `new_resource.habitat_package` is `regex`-validated to a
bare `origin/name` ident in `resources/_partials.rb`, but that validation is defense in depth —
keep the escaping regardless.

`spec/unit/resources/cleanup_spec.rb` asserts against the declared `execute["remove Habitat
package <full-ident>"]` resources and their `command` content directly, not a ChefSpec
package-resource matcher.

## Windows PATH Repair Before `msiexec`

`resources/install.rb`'s Windows branch calls `repair_windows_path!` (`libraries/helpers.rb`)
immediately before the `windows_package` resource. Windows accounts that have never interactively
logged on — CI's `net user /add` test user driven over WinRM being the canonical case — can expose
a `PATH` that either contains literal, unexpanded `%SystemRoot%`-style tokens (inherited from the
default user profile template) or omits the Windows system directories entirely. `Mixlib::ShellOut`
does a literal PATH-directory search with no `%` expansion, so both break every bare-name OS
executable and the MSI install dies with `'msiexec' is not recognized as an internal or external
command` even though `msiexec.exe` is present on disk (this failed EVERY Windows suite, not just
one). The helper therefore does both: expands `%VAR%` tokens AND appends any missing
System32/Windows/Wbem/WindowsPowerShell directories (case-insensitively deduplicated). Expansion
alone is not sufficient — it can only repair entries that are actually present. Covered by
`spec/unit/libraries/helpers_spec.rb`.

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

`hab pkg binlink` creates symlinks for all package binaries. This cookbook always passes an
explicit `--dest` (`Helpers#chef_client_binlink_dir`) because Habitat's own default destination
does not match these paths: `/usr/bin` on Linux, `/usr/local/bin` on macOS, and `.bat` shims in
`C:\hab\bin\` on Windows (added to the system PATH via `windows_path`).

The `:remove` action is a no-op that logs a warning — Habitat has no bulk unbinlink command; manual
symlink cleanup is required.

The `:create` action's `execute` MUST stay idempotent on every platform: `migrate-ice apply airgap`
already creates the binlink as a side effect of install, so `binlink_current?`/
`binlink_current_windows?` (the resource's `not_if`) is satisfied immediately and `hab pkg binlink`
never actually re-runs in practice. Linux/macOS check via `File.symlink?`/`File.readlink`; Windows
binlinks are generated `.bat` shims (not true symlinks, so `File.symlink?` is always false) and
instead check whether the shim's content already references the resolved install path
(`binlink_current_windows?`). Do not remove either `not_if` guard.

Stale-destination cleanup on Linux/macOS uses a `file` resource with `action :delete`, not a
`ruby_block` calling `::File.unlink` — `file` is idempotent and why-run aware on its own and
correctly reports "up to date", whereas a `ruby_block` reports "updated" every time its block runs.
Its guard is still what discriminates a stale *regular file* (e.g. an old omnibus binary at
`/usr/bin/chef-client`) from a symlink or a directory: `file action :delete` would happily unlink a
correct, current symlink too, and `hab pkg binlink --force` already replaces a symlink whose target
changed. Deleting a correct symlink on every converge is exactly what previously made this resource
non-idempotent.

## Local Dokken CI Testing (Apple Silicon / general)

`kitchen.dokken.yml`'s `provisioner.clean_dokken_sandbox: false` is **required, permanent** —
kitchen-dokken defaults to wiping the bind-mounted `/opt/kitchen` sandbox (backing
`Chef::Config[:file_cache_path]`) after every converge, which breaks idempotency for
`remote_file[chef-ice-*]` on both local and GitHub Actions runners.

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
