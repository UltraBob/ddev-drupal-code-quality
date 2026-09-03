# ADR-002: Tool provisioning via Dockerfile

**Date:** 2026-08-18 (revised 2026-09-03)
**Status:** Accepted
**Review-order:** 2 of 10 (no dependencies)

**Context:** ddev-module-developer provisions tools via `web-build/Dockerfile`
using `COMPOSER_HOME` isolation so binaries land in the container but not in the
project. ddev-drupal-code-quality provisions via project vendor
(`drupal/core-dev`, npm/yarn), which means tools follow the site into its
`composer.json` and `package.json`. Both approaches have tradeoffs.

Dockerfiles handle system-level provisioning well but do not compose across
add-ons as cleanly as composer resolves application-level dependencies.
Composer gives proper version resolution and lockfiles but requires every
project to carry the tools in its own dependency tree.

## Decision

Layer the two approaches. The Dockerfile is the floor; project-level
composer/npm is an optional ceiling.

**Dockerfile floor:** `web-build/Dockerfile` installs all code quality binaries
into an isolated `COMPOSER_HOME` directory and symlinks them to
`/usr/local/bin/`. Version constraints match what `drupal/core-dev` and Drupal
core's `package.json` use (caret ranges), so container tools float the same way
Drupal.org CI does. Tools are available at container build time, independent of
project vendor state.

**Optional project-level install:** The installer offers to add tools to the
project's `composer.json` and `package.json`. This is opt-in, not default. Two
cases make it worth doing:

1. **Mixed-tooling teams.** If some developers use DDEV and others run tools
   natively (Lando, bare metal, another container setup), the container versions
   and native versions will drift. Project-level lockfiles keep everyone on the
   same versions regardless of how they run the tools.
2. **Version pinning.** If an upstream tool release flags new issues and the team
   is not ready to fix them, pinning an older version in `composer.json` holds
   it steady while the container keeps updating.

For a team that is all-DDEV and happy with upstream's version ranges, there is
no reason to install tools into the project.

**Vendor-wins precedence** is unchanged. When project vendor binaries exist,
they take priority over the container-global install:

1. Project vendor binary (e.g. `vendor/bin/phpcs`)
2. Container-global binary (installed by Dockerfile)

This includes the isolated `phpcompat` install (phpcs 3.x, separate from the
main phpcs) and `phpunit` from ddev-module-developer's Dockerfile.

**Host-side shims** are unaffected. They already check for a binary and fall
back. Today the fallback is a dead end because nothing exists in the container
beyond what the project installs. With a Dockerfile floor, the fallback always
resolves. Shim logic does not change.

## Rationale

Each package manager does what it is good at. The Dockerfile handles "I just
want tools to work" (system-level provisioning). Composer and npm handle "I
need specific versions across my team" (application-level dependency
resolution). Most users never need the second layer.

The installer simplification follows from making the dependency prompts
optional. The current flow has mandatory prompts for `drupal/core-dev`, npm/yarn
toolchain selection, corepack handling, and the synthesised root `package.json`.
All of that becomes a single opt-in question. The edge-case handling around
those prompts is a large share of the installer's complexity.

## Consequences

- Container rebuild required. Existing installs need `ddev restart`. The 2.0
  release notes must say so prominently.
- The installer's dependency prompts go from required to optional, defaulting
  to skip. Users who need project-level installs opt in explicitly.
- Image size increases by the footprint of the globally installed tools.
- Dockerfile composition across add-ons is a known limitation. Code quality
  tools rarely conflict with what other add-ons install (database drivers,
  system libraries), but two add-ons installing the same binary at the same
  path would collide. DDEV's `Dockerfile.*` naming keeps the files separate.
