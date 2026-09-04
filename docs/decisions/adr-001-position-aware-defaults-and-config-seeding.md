# ADR-001: Position-aware defaults and config seeding

**Date:** 2026-08-18
**Status:** Accepted
**Review-order:** 1 of 10 (no dependencies)
**Supersedes:** The merge proposal's "project-type mode" and "config ownership
and seeding" concepts. No `DCQ_PROJECT_TYPE` variable.

**Context:** The merge of ddev-drupal-code-quality and ddev-module-developer
originally called for a `DCQ_PROJECT_TYPE` mode switch detected at install time,
with 6+ behaviors branching on it. Martin's contrib workflow turns out to use a
full Drupal site with modules at `web/modules/custom/`, not a standalone module
repo. Both workflows share a Drupal site as the project root. That makes runtime
behavior a question of where you are, not what mode you picked.

## Decision

Runtime defaults are position-aware via `HostWorkingDir: true`. At the project
root with no arguments, scan custom directories. Anywhere else, scan the current
directory. No runtime mode variable.

The installer asks whether the project is a site or for contrib development:

- **Site:** seed config files at the project root with custom-path directives
  (e.g. `<file>web/modules/custom</file>` in phpcs.xml, equivalent for
  eslint/stylelint/etc.). This is the default.
- **Contrib:** do not seed config files. Rely on the cascade (project root config,
  if any, then Drupal core config, then bundled defaults).

Contrib gets an explicit seed command or option for maintainers who want to pin
settings for their module. Seeding is opt-in, not default.

The config IS the mode. Wrappers check whether configs exist and what they
contain; they never check a mode variable.

## Rationale

The only install-time difference between site and contrib is whether to seed
configs. That is a question with two answers, not two modes with six behavior
switches.

A user who `cd`s into a module and runs `ddev phpcs` gets current-directory
scope regardless of what the installer chose, because that is where they are. A
user at the project root gets custom-directory scope because that is what 1.x
trained them on. No per-wrapper branching needed.

Committing configs is the ownership handoff either way. CI honours committed
configs; the Drupal.org templates log a message when no config is found and fall
back to their own defaults. A contrib maintainer who commits configs owns their
standard, and the cascade respects that.

## Consequences

- `DCQ_PROJECT_TYPE`, mode detection logic, and per-wrapper mode branching are
  not implemented. Instead of a mode switch, the installer seeds config for a
  whole site when the user indicates they intend to maintain a site, and offers
  to seed contrib config in one or more contrib module directories when the user
  indicates they are maintaining contrib.
- CI variable reading, PHPStan baseline offers, and other behaviors that the
  proposal gated on mode must find a different signal (presence detection,
  installer answer persisted in a dotfile, or config existence).
- If the list of install-time differences grows past about a dozen entries,
  revisit the design: either restore a mode variable or split into a shared core
  with two thin profile add-ons (install.yaml supports `dependencies:` for this).
