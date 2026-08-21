
# chef_client_updater_enterprise_scheduler_reconvergence

[back to resource list](../../README.md#resources)

Repoints any `chef_client_cron`/`chef_client_launchd`/`chef_client_systemd_timer`/
`chef_client_scheduled_task` resources already declared in the run's resource collection at the
Habitat-managed chef-client binary resolved for `habitat_package`/`version`, and re-runs each one's
own previously-declared action(s) in place. No process handoff (re-exec or exit) of any kind is
involved, on any platform.

This resource is normally invoked automatically by
[`chef_client_updater_enterprise_install`](install.md#scheduler-resource-reconvergence) — see that
resource's documentation for when and why it fires (`update_scheduler_resources`, notification
wiring, the pinned-version early-return path). It is broken out as its own resource so it can be
declared and re-run independently of `:install` when needed, but most consumers never need to
declare it directly.

## Actions

- `:reconverge` — Resolve `habitat_package`/`version` to an installed Habitat binary path and
  repoint any scheduler resources found in the run's resource collection at it (default).

## Properties

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `habitat_package` | String | `'chef/chef-infra-client'` | Habitat package identifier to resolve. Must be a bare `origin/name` ident. |
| `version` | String | `'latest'` | Version to resolve. `'latest'` (any casing) resolves to the newest installed release; an explicit version resolves to that exact release, so an intentionally pinned/rolled-back version is not silently overridden by a newer one that happens to also be installed. |

## How the binary path is resolved

On Linux and macOS, the resolved path is the **fully-versioned Habitat path** (for example
`/hab/pkgs/chef/chef-infra-client/19.3.15/20260601120000/bin/chef-client`), not the
`/usr/bin/chef-client` binlink. Scheduler resources re-resolve `chef_binary_path` at every scheduled
invocation, running as root/SYSTEM, so a writable well-known symlink there would be a standing local
privilege-escalation target between chef-client runs.

**Windows is the exception**: the resolved path is `C:\hab\bin\chef-client.bat` when that shim's
*contents* already name the resolved package directory. `hab pkg binlink` does not create a symlink
on Windows — it generates a `.bat` shim whose contents name the resolved, fully-versioned package
path, so the version is pinned inside the file and there is no mutable indirection to hijack. This
is also exactly what Chef Infra Client's own `chef_binary_path` default resolves to on Windows;
using any other value would leave the scheduled task permanently out of sync with that default, so
every converge that re-evaluated it would report the task as updated. When the shim does not name
the resolved version (e.g. it's stale, or `manage_binlinks false` left nobody maintaining it), this
resource logs a warning and falls back to the fully-versioned Habitat path instead.

If no installed package resolves to a binary path at all (or the resolved path does not exist on
disk), the action logs a warning and returns without touching any scheduler resource.

## Idempotency

This action only touches a scheduler resource whose `chef_binary_path` does not already equal the
resolved path — a resource already pointing at the correct binary is left completely untouched
(neither the property nor its declared action(s) are re-run), and the resource itself reports
`updated_by_last_action` only when at least one scheduler resource was actually changed. A
steady-state converge (this resource declared and run, but every scheduler resource already points
at the right binary) therefore reports zero resources updated, consistent with every other resource
in this cookbook. See `chef_client_updater_enterprise_install`'s notification-driven wiring, which
additionally only invokes this resource at all when chef-ice was actually installed or upgraded in
the current converge — the two together mean reconvergence work happens only when something
genuinely needs to change.

## Examples

Reconverge scheduler resources against whatever chef-ice version is currently installed:

```ruby
chef_client_updater_enterprise_scheduler_reconvergence 'default'
```

Reconverge against a specific pinned version:

```ruby
chef_client_updater_enterprise_scheduler_reconvergence 'default' do
  version '19.3.15'
end
```
