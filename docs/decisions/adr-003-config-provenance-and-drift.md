# ADR-003: Config provenance and drift checking

**Date:** 2026-08-18
**Status:** Accepted
**Review-order:** 3 of 10 (no dependencies)

**Context:** ddev-drupal-code-quality vendors upstream Drupal.org GitLab CI
template configs verbatim and drift-checks weekly. ddev-module-developer bundles
hand-authored configs that have drifted from upstream, and its phpcs command
downloads `phpcs.xml.dist` at runtime via curl.

## Decision

Vendor the upstream Drupal.org GitLab CI template configs verbatim. Keep
`sync-upstream-configs.sh` and the weekly drift-check PR to stay current. Drop
the runtime `curl` that downloads `phpcs.xml.dist` into the working tree at
lint time.

Seeded configs carry no `#ddev-generated` marker. That marker stays only on the
`.ddev/` payload, where DDEV's hygiene checker requires it and
`ddev add-on remove` needs it to delete safely. Nothing written to a project
root carries it, so the ownership handoff to the user is total.

## Rationale

The hand-authored configs in ddev-module-developer have drifted from upstream:

- **eslint:** missing `airbnb-base`, the yml plugin, all Drupal globals, and the
  entire jsdoc rule block.
- **stylelint:** missing `ignoreFiles`, stale `unit-allowed-list`.

Local runs are more permissive than real CI. Code passes locally and fails in
the pipeline.

The runtime `curl` in ddev-module-developer's phpcs command writes to the user's
git working tree from inside a lint command, requires network access to lint, and
conflicts with the no-runtime-install principle. A vendored asset plus drift
check gives the same currency without either cost.

## Consequences

- Upstream configs are the source of truth. Local behavior matches CI for
  projects that have not committed their own configs.
- The weekly drift PR surfaces upstream changes for review rather than silently
  adopting them at runtime.
- ddev-module-developer's existing test fixtures (e.g. `clean_module/js/good.js`)
  fail against the verbatim upstream configs because they were written against
  the more permissive bundled versions. Fixture recalibration is required before
  the config swap.
