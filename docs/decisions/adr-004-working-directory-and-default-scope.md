# ADR-004: Working directory and default scope

**Date:** 2026-08-18 (revised 2026-09-03)
**Status:** Accepted
**Review-order:** 4 of 10 (references ADR-001)

**Context:** ddev-module-developer uses `HostWorkingDir: true` on all 14
commands; ddev-drupal-code-quality uses it on none. The merged add-on needs
consistent cwd behavior and a rule for what to scan when no paths are passed.
ADR-001 establishes position-aware behavior; this decision defines the
mechanics.

PR #21 (`feature/host-path-alias-parity`) prototyped a related approach: a
startup symlink that makes the host project path resolve inside the container,
so host-absolute paths work without translation. That PR bundles several
unrelated changes and has not been tested on Linux or Windows, but its core
idea (host-path alias via symlink) and several of its wrapper simplifications
are worth absorbing into the 2.x work.

## Decision

`HostWorkingDir: true` on every command. Config discovery follows each tool's
stock behavior: walk up from the current directory looking for config files. The
wrapper's job is DDEV plumbing, not different semantics.

Default scope when no positional paths are passed:

- **At the project root:** scan custom directories (the site developer's trained
  expectation from 1.x).
- **Anywhere else:** scan the current directory.

Default path injection is gated on **no positional paths AND not stdin mode**.
`--stdin-path` is how IDEs lint an unsaved buffer; it carries no positional
path. Without the stdin gate, a "no arguments" rule would inject the default
scope and scan the entire project on every keystroke.

### Host-path alias

Adopt the startup symlink from PR #21: a `web-entrypoint.d/` hook creates a
symlink from the host project path to `/var/www/html` inside the container. On
macOS it also creates a `/private/`-stripped companion. This makes host-absolute
paths resolve inside the container without per-wrapper translation.

The existing `path-map.sh` translation layer stays in place as a fallback until
the alias is proven on all three platforms (macOS, Linux, Windows/WSL2). Once
verified, the translation logic can be simplified or removed in a follow-up.

Users can opt out via `DCQ_HOST_PATH_ALIAS=0` in `web_environment`.

### What to absorb from PR #21

- **The entrypoint hook** (`90-dcq-host-path-alias.sh`): land as its own change
  after cross-platform testing.
- **The `checks`/`checks-full` simplification** (removing `CUSTOM_PATHS` and
  the phpcs special-case): absorb into the `HostWorkingDir` enablement work,
  since both changes serve position-aware scope.
- **Missing-config error messages** (phpstan, stylelint, prettier): land as
  independent improvements, not gated on the alias.
- **The `path-map.sh` rewrite** (returning host paths as-is instead of
  translating): defer until the alias is verified cross-platform.

### Risks of the alias approach

- **Platform coverage.** PR #21 was stalled because Linux and Windows/WSL2
  behavior was never tested. The symlink uses `sudo` inside the container; that
  works in DDEV's default image, but non-standard container configs or
  hardened images may not grant it.
- **One-way door on path-map.sh.** If the alias fails to create (conflict,
  permissions, non-standard container), wrappers that stopped translating paths
  would get host paths that do not resolve. Keeping path-map.sh as a fallback
  until the alias is proven avoids this.
- **Startup conflicts.** If something already exists at the host path inside the
  container (a bind mount, a stale directory), the symlink cannot be created.
  PR #21 handles this (logs an error, does not overwrite directories), but it
  means the alias is best-effort, not guaranteed.
- **Container restart required.** The symlink is created at startup, so a
  `ddev restart` is needed after install. This is the same requirement as
  ADR-002's Dockerfile changes, so the 2.0 release notes already cover it.

## Prerequisites

These must land before or alongside `HostWorkingDir` enablement:

1. **Fix `COMMANDS_DIR`** in `checks` and `checks-full`. They resolve tools as
   `./.ddev/commands/web/<tool>`, which works only at the project root. With
   `HostWorkingDir` live, running from any other directory makes every check
   report SKIP and pass silently. ddev-module-developer's `COMMANDS_DIR` pattern
   is the fix.
2. **Re-anchor all default scopes** to `$DDEV_APPROOT`. Relative defaults would
   resolve against the mapped cwd, not the project root.
3. **Anchor `dcq-reports/`** to the project root so reports land in a
   predictable location regardless of cwd.
4. **Cross-platform alias testing.** Verify the startup symlink on macOS, Linux,
   and Windows/WSL2 before removing the path-map.sh translation fallback.

## Rationale

Every tool this add-on wraps is cwd-centric: phpcs walks up looking for
`{.,}phpcs.xml{.dist,}`, eslint for `.eslintrc*`, stylelint and prettier for
their own dotfiles, phpstan for `phpstan.neon`. `HostWorkingDir` gives native
behavior for free. Upward config discovery IS the cascade.

The project-root carve-out preserves the trained `ddev phpcs` meaning for site
developers. In a contrib workflow the project root is the site, not the module,
so the position-aware rule handles both cases without branching.

The host-path alias simplifies wrappers further by eliminating the need to
translate every path argument. IDEs pass host-absolute paths; if those paths
resolve inside the container, the wrappers do not need to rewrite them.

## Consequences

- All 15+ commands gain `HostWorkingDir: true`.
- `checks` and `checks-full` must be fixed before enablement, or they silently
  pass from non-root directories.
- IDE integrations (shims, editor configs) must make sure `--stdin-path` does
  not accidentally trigger default scope injection.
- The host-path alias adds a startup hook and a `ddev restart` requirement.
- PR #21 should not merge as-is. Its ideas are absorbed into the 2.x work as
  separate changes. The PR can be closed with a reference to this ADR, or left
  open as a reference until the pieces land.
