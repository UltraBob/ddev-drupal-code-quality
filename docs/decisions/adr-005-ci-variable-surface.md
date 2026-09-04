# ADR-005: CI variable surface

**Date:** 2026-08-18
**Status:** Accepted
**Review-order:** 5 of 10 (references ADR-001)

**Context:** ddev-module-developer reads `SKIP_*` and `_*_ALLOW_FAILURE` from
`.gitlab-ci.yml`. ddev-drupal-code-quality does not. The merge proposal
originally gated this on a project-type mode; ADR-001 replaces mode gating with
presence detection.

## Decision

Adopt `SKIP_*` and `_*_ALLOW_FAILURE` wholesale. Per-tool variables take
precedence over `_ALL_VALIDATE_ALLOW_FAILURE`.

Variables are honoured when the project's `.gitlab-ci.yml` contains Drupal
template variables (presence-detected). When no `.gitlab-ci.yml` exists or it
has no Drupal template references, the variables are ignored.

## Rationale

For contrib projects these are the sanctioned control surface.
ddev-module-developer's implementation already handles per-tool precedence over
the blanket allow-failure flag correctly; we adopt that behavior as-is.

Presence detection replaces mode gating because a site project's
`.gitlab-ci.yml` may exist for an entirely unrelated deploy pipeline with no
Drupal template anywhere in it. Silently honouring `SKIP_PHPCS` from a file the
team does not think of as controlling local checks would mean checks quietly
disabled. Checking for Drupal template variable patterns avoids this false
positive.

## Consequences

- Projects with a Drupal-template `.gitlab-ci.yml` get CI variable support
  automatically. No opt-in needed.
- Site projects with non-Drupal CI pipelines are unaffected.
- The detection heuristic (what counts as "Drupal template variables present")
  must be defined precisely during implementation. False negatives are safer than
  false positives: failing to read a variable means tools run unconditionally,
  which is the 1.x behavior.
