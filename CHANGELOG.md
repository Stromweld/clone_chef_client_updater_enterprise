# chef_client_updater_enterprise CHANGELOG

This file is used to list changes made in each version of the chef_client_updater_enterprise cookbook.

## Unreleased

### Added

- `helpers.rb`: shared `chef_client_binlink_dir`/`chef_client_binlink_path` helpers, reused by
  `binlinks.rb` and `install.rb`'s scheduler reconvergence logic.
- `scheduler_fix` named run list, test recipe, and InSpec suite covering `chef_client_cron` +
  `chef_client_systemd_timer` (Linux) and `chef_client_scheduled_task` (Windows), verifying the
  built-in scheduler resources' `chef_binary_path` resolves to the stable binlink path after
  migration on both platforms — on Linux/macOS by checking the cron/systemd file content plus
  resolving the binlink symlink itself to the expected version; on Windows by checking the
  scheduled task's command against either the stable shim or a versioned hab pkgs path, and (when
  it's the stable shim) reading that file's own content for the expected version. macOS/`launchd`
  coverage is not yet automated — see AGENTS.md.

### Changed

- `install.rb`: replaced the `handoff` process-handoff mechanism (`Kernel.exec` on Linux/macOS,
  `exit(213)` plus a Windows self-heal scheduled task) entirely with in-place reconvergence of any
  `chef_client_cron`/`chef_client_launchd`/`chef_client_systemd_timer`/`chef_client_scheduled_task`
  resources already declared in the run's resource collection. `handoff` is renamed to
  `update_scheduler_resources`; the `scheduled_task_name` property is removed. Each found
  resource's `chef_binary_path` is explicitly set to the resolved binlink path before re-running
  its own previously-declared `action`(s) — the resource's own default cannot be relied on, since
  older bootstrap chef-client releases (e.g. the `stable` channel's 18.11.11) default
  `chef_binary_path` to a plain, non-lazy, hardcoded legacy path with no hab-awareness at all. No
  second chef-client run, no dependency on Test Kitchen's `retry_on_exit_code` convention, and no
  Windows run-lock deadlock risk. See AGENTS.md's "Scheduler Resource Reconvergence" section for
  the full rationale.
- `install.rb`: the `handoff` re-exec now fires on **every** successful install/upgrade that
  changes the binlinked package, not just the initial omnibus-to-chef-ice migration. Keeps the
  built-in `chef_client_cron`/`chef_client_launchd`/`chef_client_systemd_timer`/
  `chef_client_scheduled_task` resources' own unmodified `chef_binary_path` default (which resolves
  the currently running process) permanently accurate, and in sync with
  `chef_client_updater_enterprise_cleanup`'s protection of the running version — without
  overriding those resources' properties, a declaration-order requirement, or a separate fixup
  mechanism. See AGENTS.md's "Scheduler Resource Reconvergence" section for the full rationale.
  (Superseded an earlier `fix_scheduler_paths` resource-collection-scanning approach that forced
  `chef_binary_path` to a stable binlink path — removed, since it diverged from the built-in
  resources' documented default and required a declaration-order convention to avoid churn.)

### Fixed

- `install.rb`: **critical** — `Kernel.exec` cannot truly replace a process on Windows (no
  `execve()`) — MRI spawns the new process and blocks waiting for it before the parent exits, so
  the parent never releases Chef's own Windows named-mutex run-lock (`Chef::RunLock#wait` in
  `lib/chef/run_lock.rb`), and the freshly spawned child deadlocks acquiring its own run-lock
  against its still-running parent. Confirmed live: `scheduler-fix-windows-2022` and
  `remove-omnibus-windows-2022` both hung indefinitely (45+ minutes) the moment the handoff fired
  for the first time on Windows (previously always dead code there too, for the unrelated reason
  below). The established `chef_client_updater` cookbook hits this same class of problem and
  explicitly forces `exit`/`kill` instead of `exec` on Windows for exactly this reason. Fixed by
  calling `exit(213)` instead of `Kernel.exec` on Windows — `213` is Test Kitchen's own documented
  exit code for "exit due to a chef-client upgrade" (`retry_on_exit_code` defaults to `[35, 213]`
  in the `chef_infra` provisioner, no `kitchen.yml` changes needed), so Test Kitchen automatically
  reruns chef-client, and that fresh run resolves `chef_client_scheduled_task`'s `chef_binary_path`
  against the newly installed binary — confirmed live, no deadlock, no staleness.
- `install.rb`: **critical** — the `handoff` re-exec notification was wired to
  `chef_client_updater_enterprise_binlinks`, but `migrate-ice apply airgap` already creates the
  binlink symlink as a side effect of every install, so `binlinks`' own idempotency check was
  satisfied immediately on every converge (including the first) and it never reported a change —
  silently making the handoff permanent dead code on every platform/scenario, confirmed live via
  `scheduler-fix` and `remove-omnibus` Test Kitchen suite failures (stale omnibus
  `chef_binary_path` baked into `chef_client_cron`/`chef_client_systemd_timer`). Fixed by notifying
  the handoff `:immediately` from the platform-specific package-install resource instead
  (`rpm_package`/the `dpkg --configure` `execute`/`windows_package`/the generic `package`
  fallback), which are properly idempotent and only report a change when chef-ice was actually
  installed/upgraded. The `binlinks` notification is kept as a harmless redundant backup only.
- `install.rb`: **critical** — the debian-family `dpkg --unpack`/`dpkg --configure` `execute`
  resources have no native idempotency check the way `rpm_package`/`windows_package` do, so once
  the handoff notification (above) was wired to `execute[dpkg --configure ...]`, it fired on
  **every** converge where `version` is `'latest'` (the top-level version guard only short-circuits
  for an explicitly pinned, already-installed version) — including converges where chef-ice was
  already at the target version — producing an infinite handoff re-exec loop. Confirmed live on
  Debian-family `scheduler-fix` suites. Fixed by adding a `dpkg_already_current` guard (comparing
  `current_native_version` against the target `pkg_version`) to the `dpkg --unpack`/`--configure`
  executes and their surrounding `ruby_block` stub/neutralize steps, matching the native
  idempotency `rpm_package`/`windows_package` already provide.
- `install.rb`: replace `hab_pkg_dirs`-based migration guard with bundle-existence guard; migration is now idempotent — runs only while the bundle file exists on disk
- `cleanup.rb`: remove old Habitat versions via direct `hab pkg uninstall <full ident>` (through an `execute` resource), not Chef's built-in `habitat_package` resource. `habitat_package`'s own idempotency check (`Chef::Provider::Package::Habitat#installed_version`) resolves `hab pkg path <bare origin/name>`, which reports whatever Habitat considers the current/active package for that name — not the specific, possibly-older version being removed. With multiple versions coexisting on disk (the normal case this cookbook supports), that check can silently report an older version as "not installed" and skip its removal even though its directory is still present. See AGENTS.md's "Cleanup Removal Uses Direct `hab pkg uninstall`, Not `habitat_package`" for the full rationale.
- `binlinks.rb`: raise `Chef::Exceptions::ValidationFailed` when requested version is not found in the Habitat package store; remove unused `hab_pkg` local
- `remove_omnibus.rb`: gate omnibus directory deletion on hab binlink existence (`/usr/bin/chef-client` or `/usr/local/bin/chef-client`) so `/opt/chef` is never removed before the replacement binary is in place
- `preserve-omnibus` InSpec: remove hard assertion that `/opt/chef` exists post-migration (migrate-ice controls this); verify `/etc/chef` config preservation instead
- `test/integration/multi-version/default_test.rb`: fix `NameError: undefined local variable or method 'older_version'` — define `older_chef_ice_version = '19.2.12'` locally (matching the Linux branch of `older_chef_ice_version` in the `multi_version.rb` test recipe, which is not itself visible to InSpec's separate process) instead of referencing the never-defined `older_version`.

## 0.1.0 - *2026-07-09*

### Added

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
