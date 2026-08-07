# Agentless (Target Mode) Support — Implementation Plan

Status: **not started**. Research complete, no code written.
Branch created for this work: `feature/agentless-target-mode` (currently empty, branched from `testing`).

This document is a self-contained brief. A future session should be able to implement from this
alone, without re-deriving the research. Every claim below was verified by reading Chef source, not
from documentation. **Do not trust docs.chef.io over this document** — several claims here directly
contradict the public docs, and the source was checked in both places listed under Reference Sources.

Read `AGENTS.md` first. It documents *why* the current agent-mode implementation is the way it is,
and several of its "do not do X because Y" rules constrain what a target-mode port is allowed to
change. This plan is written to preserve all of them.

---

## Reference Sources

Both were verified byte-identical for the entire `lib/chef/target_io/` tree, so findings are current.

- Installed client: `/opt/hab/pkgs/chef/chef-infra-client/19.3.60/20260721083015/vendor/gems/chef-19.3.60`
  (reachable via Chef Workstation 26.1.1 at `/opt/hab/pkgs/chef/chef-workstation/26.1.1/...`)
- Source checkout: `~/github/personal/chef/testing/chef` @ `main` (19.4.12)

The `chef` repo is indexed in `codebase-memory-mcp` as project **`chef-infra`** (22,666 nodes /
63,345 edges) if graph queries are useful.

Upstream docs (incomplete and partly wrong — see Corrections): <https://docs.chef.io/client/19/features/agentless/>

---

## Corrections to the public documentation

Worth stating up front, because these shaped the plan:

1. **Agentless is not Linux-only.** It is Train-based, so SSH covers Linux/macOS and WinRM covers
   Windows. The docs' "Supported platforms: Linux" is a statement about what Progress has verified,
   not a transport limitation. However, see Finding 3 — Windows targets are blocked by *missing
   resource registrations*, not by the transport.
2. **The "supported resources" table is not authoritative.** The ground truth is
   `grep -rn "target_mode: true" lib/chef/resource/` (94 files). The table lists resources that are
   not registered (e.g. `habitat_package` has no resource file at all in core), and omits registered
   ones. Always check the source.

---

## How target mode works (verified mechanics)

### Resource resolution

`Chef::NodeMap#set(key, klass, ..., target_mode: nil, agent_mode: true)`
(`lib/chef/node_map.rb:61`) with filtering at `:257-282`:

```ruby
def matches_target_mode?(filters)
  return true unless Chef::Config.target_mode?
  !!filters[:target_mode]
end

def matches_agent_mode?(filters)
  return true if Chef::Config.target_mode?
  !!filters[:agent_mode]
end
```

Consequences:

- In target mode, any resource whose `provides` lacks `target_mode: true` **will not resolve at
  all**. It is not a degraded path — the resource is invisible.
- `target_mode: true` is **completely inert in agent mode** (early return). Verified present in
  `v17.10.163` and `v18.7.10` `node_map.rb` as well, so adding it is backward compatible.
- `agent_mode:` is the only 19-only kwarg. **Do not pass `agent_mode:`** — it would raise
  `ArgumentError: unknown keyword` on Chef 17/18.
- **Therefore `metadata.rb`'s `chef_version '>= 17.0'` does NOT need to change.** This matters:
  the cookbook's whole purpose is being driven by an older bootstrap client mid-migration.
- `Chef::Resource.resource_name` is a bare setter that registers nothing
  (`lib/chef/resource.rb`, `def self.resource_name`). Only the explicit `provides` line registers,
  so there is no second registration that could shadow the target-mode one.

### IO abstraction

`TargetIO::File`, `::Dir`, `::FileUtils`, `::IO` are `method_missing` shims:

```ruby
backend = ChefConfig::Config.target_mode? ? TrainCompat::File : ::File
backend.send(m, *args, **kwargs, &block)
```

So **every `::File` → `TargetIO::File` conversion is a no-op in agent mode**. Agent-mode behavior
and the existing ChefSpec suite are preserved by construction. This is the single most useful
property for this port — conversions are safe to make broadly.

### shell_out

`Mixlib::ShellOut::Helper#__shell_out_command` branches on `__transport_connection` and, when
present, calls `__transport_connection.run_command(command, options)`, wrapping the result in
`FakeShellOut` (`stdout`, `stderr`, `exitstatus`, `status.success?`, `error?`, `error!`).

- `shell_out` / `shell_out!` are **fully target-aware on every platform**.
- `Mixlib::ShellOut.new(...)` called directly **bypasses the transport entirely** and executes on
  the workstation. This is the highest-value correctness fix in the port.
- `FakeShellOut` has **no `live_stream` and no `run_command`**. Any ported call must not use them.

---

## Findings that drive the design

### Finding 1 — `TrainCompat` has gaps that hit this cookbook's exact call sites

From `lib/chef/target_io/train/{file,dir,fileutils}.rb`:

| Call | Behavior in target mode | Impact |
| --- | --- | --- |
| `File.write` | **Raises `"Unsupported File method write"`** — not in `nonio`, `passthru`, or `redirect_utils` | `install.rb:414`, `install.rb:440` |
| `Dir.exist?`, `Dir.children` | **`NoMethodError`** — `TrainCompat::Dir` defines no `method_missing`; it only implements `[] delete directory? entries glob mkdir mktmpdir tmpdir unlink` | `remove_omnibus.rb:102,103,122` |
| `File.stat(p).dev` | `stat` → `transport_connection.file(p).stat` wrapped in `OpenStruct`. Train's stat has **no `dev`** key → returns `nil`. `nil != nil` → **always `false`** | `helpers.rb:470` `mount_point?` — silently reintroduces the `Errno::EBUSY` mount-point bug AGENTS.md documents |
| `Dir.glob` | Bash heredoc using `shopt -s globstar`. **Breaks on WinRM.** Also has no `nullglob`, so a non-matching pattern returns the **literal unexpanded pattern string** | `helpers.rb:149` `hab_pkg_dirs`, `install.rb:603,614` |
| `File.executable?` | `mode(f) & 0111`; `mode` → `stat[:mode]`. On a missing file this is `nil & 0111` → **raises** instead of returning false | `helpers.rb:67,75` `hab_binary` probes 4 candidate paths that usually do not exist |
| `File.read` | `readlines(f).join("\n")` — **drops trailing newline, mangles binary, collapses `\r\n`** | `binlinks.rb:94` (substring check, tolerable, but note it) |
| `File.readlink`, `File.realpath` | Shell out to POSIX `readlink` / `realpath` (coreutils; `realpath` is noted as not-macOS) | `binlinks.rb:83` |
| `FileUtils.mv` | Runs `mv` and **ignores exit status** — native raises `Errno::ENOENT`, this does not | `install.rb:407,439,446` |

`File.join/dirname/basename/extname/split` are handled locally as pure string ops (`nonio`) and are
safe. `File.exist?/directory?/symlink?/file?` are `passthru` to train and are safe on POSIX.

**Design consequence:** do not build the port on `TargetIO::File/Dir/FileUtils`. Build a thin
primitives layer on `shell_out` (which is reliable everywhere) and use `TargetIO::*` only where it
is known-good.

### Finding 2 — `remote_file` is unusable for a ~160MB artifact

`lib/chef/provider/remote_file/http.rb:63` `fetch` → `TargetIO::HTTP.new(uri)` →
`TrainCompat::HTTP#streaming_request`:

```ruby
def streaming_request(path, headers = {}, tempfile = nil)
  content = get(path, headers)   # runs `curl --request GET <url>` ON THE TARGET
  @last_response = content        # entire body captured as a Ruby String over the transport
  tempfile.write(content)         # written to a HOST-LOCAL tempfile
  tempfile.close
  tempfile
end
```

Then `Chef::Provider::File#update_file_contents` (`lib/chef/provider/file.rb:397`) calls
`deployment_strategy.deploy(tempfile.path, ...)`, and `TargetIO::Deploy#deploy` does
`::TargetIO::File.upload(src, dst)` — **uploading it back to the target**.

So one converge = download on target → whole body over the wire to host as a string → host disk →
whole body back over the wire to target. Plus:

- Entire artifact resident in host memory as a String (twice, counting the write).
- Binary content transits a **text** stdout channel. Corruption risk is severe over WinRM.
- The generated curl has **no `-L`** (no redirect following), **no `-f`** (HTTP error bodies become
  "content"), and **no `-s`**. See `TrainCompat::HTTP#request` / `#curl`.
- `which(cmd)` uses `which`, unavailable on Windows targets.

**Design consequence:** target mode must download **on the target** and never move the bytes.

### Finding 3 — Windows target mode has no usable resources

Verified by `grep -c "target_mode: true"` per resource file:

- **Not registered:** `windows_package`, `windows_env`, `windows_path`, `windows_service`,
  `powershell_script`, `batch`, `dnf_package`.
- **Not registered:** `chef_client_cron`, `chef_client_systemd_timer`, `chef_client_launchd`,
  `chef_client_scheduled_task` — **all four** scheduler resources.
- **Registered:** `execute`, `file`, `directory`, `link`, `template`, `service`, `package`,
  `rpm_package`, `dpkg_package`, `yum_package`, `zypper_package`, `remote_file`, `ruby_block`,
  `mount`, `reboot`, `habitat_install`, `habitat_service`, `habitat_config`, `chef_client_config`.

So on a Windows target the cookbook currently cannot install anything (`install.rb:506,530`
`windows_env`; the `windows_package`; `binlinks.rb:150` `windows_path`;
`remove_omnibus.rb:76` `windows_package`), and on **every** platform the scheduler reconvergence
feature is unavailable in target mode.

Note `rpm_package` IS registered but `dnf_package` is not — irrelevant here, since AGENTS.md already
mandates `rpm_package` for the RHEL path, but worth knowing the fallback does not exist.

### Finding 4 — `verify` blocks still work (no change needed)

Earlier concern was wrong. `lib/chef/provider/file.rb:350-351` calls `v.verify(tempfile.path)` and
`:412` guards with native `::File.exist?(tempfile.path)` — the tempfile is **host-local**. The
existing `Chef::Digester.checksum_for_file(path)` verify block in `install.rb` is correct as written
in both modes. If Phase 3 replaces `remote_file` in target mode, this protection must be
reimplemented target-side rather than deleted (AGENTS.md: `checksum` alone verifies nothing).

### Finding 5 — host-process introspection is meaningless against a target

- `helpers.rb:413` `chef_client_on_path?` reads the **host** `ENV['PATH']`. This drives the
  `--fresh-install` decision, and AGENTS.md warns **both branches exit 0** — getting it wrong leaves
  `/hab/pkgs` empty while reporting success. Highest-consequence single line in the port.
- `helpers.rb:406` `RbConfig::CONFIG['bindir']` → `running_chef_root` → `running_under_omnibus?`
  (`remove_omnibus` deferral guard) and `running_hab_ident` (**what stops `cleanup` deleting the
  live version**). All describe the host process.
- `helpers.rb:437-456` `repair_windows_path!` mutates the host's `ENV['PATH']`. Only meaningful in
  agent mode; it exists to fix `msiexec` resolution for the *local* `windows_package`.
- `binlinks.rb:162` reads `ENV['PATH']` as a fallback for the Machine PATH check.

---

## Complete change inventory

Line numbers are against `testing` @ `3c6dfa7`.

### `provides` (4 sites)

```text
resources/binlinks.rb:23        resources/cleanup.rb:25
resources/install.rb:25         resources/remove_omnibus.rb:23
```

Add `, target_mode: true`. Do **not** add `agent_mode:`.

### Raw `Mixlib::ShellOut.new` → `shell_out` (5 sites, all `libraries/helpers.rb`)

```text
:157  hab pkg list           (current_hab_ident)
:325  dpkg-query -W          (current_native_version)
:332  rpm -q --queryformat   (current_native_version)
:339  pkgutil --pkg-info     (current_native_version)
:355  (multi-line)           (current_native_version, Windows)
```

Watch for `.run_command` / `live_stream` usage — `FakeShellOut` has neither.

### `ENV[...]` (host env)

```text
libraries/helpers.rb:413        chef_client_on_path?      -> target-aware `command -v` / `where.exe`
libraries/helpers.rb:437-456    repair_windows_path!      -> skip entirely in target mode
resources/binlinks.rb:162       Machine PATH fallback     -> target-aware
```

### TrainCompat-unsupported calls

```text
resources/install.rb:414,440         ::File.write        -> primitive write
resources/remove_omnibus.rb:102,122  ::Dir.exist?        -> directory? primitive
resources/remove_omnibus.rb:103      ::Dir.children      -> entries primitive
libraries/helpers.rb:470             ::File.stat(..).dev -> `stat -c %d` primitive
libraries/helpers.rb:149             ::Dir.glob          -> glob_dirs primitive
resources/install.rb:603,614         ::Dir.glob          -> glob primitive
libraries/helpers.rb:67,75,414       ::File.executable?  -> `test -x` primitive (missing-file safe)
resources/binlinks.rb:81,83,112      symlink?/readlink   -> primitives (Windows-safe)
resources/remove_omnibus.rb:106      directory?/symlink? -> primitives
resources/binlinks.rb:94             ::File.read         -> primitive read (note newline mangling)
resources/install.rb:407,439,446     ::FileUtils.mv      -> primitive mv (must raise on failure)
```

### Windows-only resources (unavailable in target mode)

```text
resources/install.rb:506,530     windows_env    (CHEF_LICENSE_KEY bracketing the MSI)
resources/install.rb (~502-535)  windows_package + repair_windows_path!
resources/binlinks.rb:150        windows_path 'C:\hab\bin'
resources/remove_omnibus.rb:76   windows_package (display-name discovery already uses shell_out)
```

---

## Phased implementation

### Phase 1 — `libraries/target_io.rb` (new file)

Primitives that delegate to **native Ruby in agent mode** (fast, zero round trips, preserves current
behavior exactly) and to **`shell_out` in target mode**, dispatching POSIX-shell vs PowerShell on
the *target* OS:

```text
exist?  directory?  executable?  symlink?  readlink  entries  glob  glob_dirs
read  write(content, mode:)  mv  delete  mount_point?  sha256  command_on_path?
```

Rationale for bypassing `TargetIO::*`: Finding 1. This layer is what makes WinRM viable at all and
removes the bash-only `Dir.glob` dependency.

Two efficiency notes:

- `hab_pkg_dirs` currently does `Dir.glob(...).select { File.directory? }` — in target mode that is
  **one transport round trip per entry**. `glob_dirs` should return directories in a single command.
- Cache within a converge where safe; guards are evaluated repeatedly.

**Must add a per-file symlink** at `spec/fixtures/cookbooks/chef_client_updater_enterprise/libraries/`
— `spec/unit/fixture_sync_spec.rb` fails if the sets drift, and directory-level symlinks do not work
because `Dir.glob` does not recurse into symlinked directories (AGENTS.md).

Use `windows?` (node-based, resolves the **target** via target-mode Ohai), never `ChefUtils.windows?`
(host).

### Phase 2 — `libraries/helpers.rb`

- Port the 5 `Mixlib::ShellOut` sites.
- Rebuild `hab_pkg_dirs`, `hab_binary`, `chef_client_on_path?`, `mount_point?` on Phase 1 primitives.
- Target-mode semantics for host-introspection helpers:
  - `running_under_omnibus?` — in target mode no chef-client is executing on the target during the
    converge, so this is `false`. This is a genuine improvement: **`remove_omnibus` completes in one
    converge**, and the `kitchen.yml` `remove-omnibus` `post_converge` hook is unnecessary for
    target mode. Document it; do not delete the hook (agent mode still needs it).
  - `running_hab_ident` — must NOT simply return nil, or `cleanup` loses its protection against
    removing the active version. Resolve the ident that the **target's** chef-client binlink points
    at, preserving the intent of the guard.
- Leave `commercial_artifact_metadata` on host-side `Chef::HTTP::Simple`. It is a control-plane
  lookup; keeping it host-side keeps the license key off the target and works for airgapped targets.
  Do **not** switch it to `TargetIO::HTTP` (that would route it through curl/wget on the target).

### Phase 3 — downloads

Keep `remote_file` for agent mode unchanged. In target mode, download **on the target**
(`curl`/`wget`, `Invoke-WebRequest`/`certutil` on Windows) via `execute`, preserving all three
properties AGENTS.md calls load-bearing:

- **Idempotency** — `not_if` comparing target-side sha256 against the expected checksum.
- **Verification** — target-side sha256 check; on mismatch delete the artifact and fail so `retries`
  re-downloads. (`checksum` alone verifies nothing; a CDN error page served with a 200 must never
  reach rpm/dpkg/msiexec.)
- **CDN propagation** — keep `download_retries` / `download_retry_delay` (default 5 × 30s).

Also: `download_dir` defaults to `Chef::Config[:file_cache_path]` (`install.rb:47`), a **host** path.
Needs a target-appropriate default in target mode.

### Phase 4 — resource bodies

Add the four `provides` kwargs; port `install.rb`, `binlinks.rb`, `cleanup.rb`, `remove_omnibus.rb`
onto the primitives. Preserve every AGENTS.md invariant, especially:

- The Debian stub/restore must stay **one** `ruby_block` with `begin/ensure` (no cross-resource
  `ensure`). Note the `ensure` now spans a network hop — a dropped connection strands `migrate-ice`
  as a permanent `#!/bin/sh exit 0` stub. The existing pre-`dpkg --unpack` self-heal block is what
  recovers this; make sure it still runs first and stays ungated by `dpkg_already_current`.
- Conditional `--fresh-install` driven by `chef_client_on_path?` (now target-aware). Both branches
  exit 0, so a mistake here is silent.
- `--fstab ignore` when `preserve_omnibus`.
- `cleanup` keeps direct `hab pkg uninstall` with full idents + shell-escaping.
- Binlink guards must stay idempotent (`migrate-ice` already creates the binlink).

### Phase 5 — Windows target parity

`execute`-based replacements for the unavailable resources: msiexec invocation (keep the 1800s
timeout and `CHEF_PRESERVE_OMNIBUS`), Machine PATH manipulation, and pass the license via an MSI
property rather than `windows_env`. Idempotency guards must be rebuilt by hand since
`windows_package`'s registry lookup is gone.

`repair_windows_path!` is a host-side fix for local `msiexec` resolution and should be skipped in
target mode; if the same unexpanded-`%SystemRoot%` breakage appears on targets it must be solved
target-side instead.

### Phase 6 — scheduler resources

All four `chef_client_*` scheduler resources are unavailable in target mode, so users cannot declare
them and `reconverge_installed_scheduler_resources` will find none. Ensure it no-ops cleanly and
warn when `update_scheduler_resources` is true in target mode. Do not change the agent-mode design
(the `ruby_block` must stay `action :nothing`, notification-driven — see AGENTS.md).

### Phase 7 — specs, docs, CI

- Unit tests for Phase 1 primitives (both modes).
- Fixture symlink + `fixture_sync_spec` green.
- `chef exec rspec` and `chef exec cookstyle .` clean.
- README + a new AGENTS.md section recording the decisions above (especially: why not `TargetIO::*`,
  why not `remote_file` in target mode, why `chef_version` stays `>= 17.0`).
- Integration harness: **ChefSpec has no target-mode support**, so the entire port is otherwise
  unverified. Needs a host container + sshd target container running
  `chef-client -z -t <target> <cookbook>`. This does not map onto any of the five existing kitchen
  files and is net-new work.

---

## Open decisions

1. **Windows targets** — full `execute`-based parity (Phase 5), or ship Linux/macOS agentless first
   and raise a clear "unsupported in target mode" on Windows? Largest chunk, hardest to test.
2. **Download rework** — confirm the target-side download. The alternative is living with
   `remote_file`'s double transfer and likely WinRM binary corruption.
3. **Scope of `cleanup` / `remove_omnibus` in target mode** — full support (as planned here), or
   `target_mode: false` on those two for a v1 that avoids the riskiest host-introspection changes.

## Effort

Phases 1–4 ≈ 2–3 days. Phase 5 adds ≈ 2–3 days. Phase 7 depends on how far CI should go.

## Quick verification commands

```bash
CHEF=~/github/personal/chef/testing/chef

# ground truth for which resources work in target mode
grep -rn "target_mode: true" $CHEF/lib/chef/resource/ | wc -l   # 94

# check one resource
grep -n "target_mode" $CHEF/lib/chef/resource/windows_package.rb  # (no output = unavailable)

# the IO shims and their gaps
cat $CHEF/lib/chef/target_io/train/{file,dir,fileutils,http}.rb

# resolution filtering
sed -n '250,290p' $CHEF/lib/chef/node_map.rb

# backward-compat check
git -C $CHEF show v18.7.10:lib/chef/node_map.rb | grep -n "def set"
```
