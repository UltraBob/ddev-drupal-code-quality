[![add-on registry](https://img.shields.io/badge/DDEV-Add--on_Registry-blue)](https://addons.ddev.com)

# DDEV Drupal Code Quality

## Overview

This add-on installs Drupal GitLab CI parity tooling for local development and IDE usage.
It provides DDEV commands and host shims so developers can run the same checks
locally that GitLab CI runs on Drupal.org.

Tools covered:
- PHPStan
- PHPCS / PHPCBF
- ESLint
- Stylelint
- Prettier
- CSpell
- Composer validate
- php-parallel-lint (when installed)

## Installation

```bash
# Install from GitHub (current)
ddev add-on get UltraBob/ddev-drupal-code-quality

# If/when published to the add-on registry:
# ddev add-on get ddev-drupal-code-quality

# Or, for local development
ddev add-on get /path/to/ddev-drupal-code-quality

ddev restart
```

During installation, the add-on copies CI-parity config files into the project
root. If conflicts are detected, you can choose to back up and replace, skip,
or abort. Skipping a config may reduce CI parity. The installer will prompt for:
- Conflict handling (default: skip unless you choose replace/abort).
- PHP tooling dependencies (install `drupal/core-dev` or run `ddev composer install`).
- PHPStan default level (keep CI level 0 or choose a local level 0-9; recommend 3).
- Node toolchain location (project root or `web/core`) and package manager selection.
- Missing Drupal JS dependencies when a root `package.json` exists.
- Optional `.gitignore` update for `dcq-reports/`.
- IDE settings (merge/overwrite/skip when templates are available).
The installer runs in bash so it does not require host PHP.

If PHPStan/PHPCS/PHPCBF binaries are missing, the installer prompts to add
`drupal/core-dev` (or to run `ddev composer install` if it is already required).
It uses `ddev composer require --with-all-dependencies` to avoid lockfile
conflicts.

## Usage

For CLI usage, prefer the DDEV commands:

```bash
ddev phpstan
ddev phpcs
ddev phpcbf
ddev eslint
ddev stylelint
ddev prettier
ddev cspell
ddev composer-validate
ddev checks
ddev checks-full
```

Host shims are installed under `.ddev/drupal-code-quality/tooling/bin`. These are intended for
IDE tool paths or tools that require a local binary path:

```bash
./.ddev/drupal-code-quality/tooling/bin/phpstan
./.ddev/drupal-code-quality/tooling/bin/phpcs
./.ddev/drupal-code-quality/tooling/bin/eslint
./.ddev/drupal-code-quality/tooling/bin/stylelint
./.ddev/drupal-code-quality/tooling/bin/prettier
./.ddev/drupal-code-quality/tooling/bin/cspell
./.ddev/drupal-code-quality/tooling/bin/checks
./.ddev/drupal-code-quality/tooling/bin/checks-full
```

## IDE settings (VS Code/Codium)

Starter settings live in `.ddev/drupal-code-quality/ide-settings/vscode`. During install, you can
choose to merge them into `.vscode/settings.json` and
`.vscode/extensions.json`, back up and overwrite, or skip and handle them
manually.

The template points PHP tooling at `.ddev/drupal-code-quality/tooling/bin` and JS tooling at local
`node_modules`. The installer uses the Node toolchain choice (prompt or
`DCQ_INSTALL_NODE_DEPS`) to set JS paths to root or `web/core`. Override the
paths if you prefer a different location.

## Requirements

- DDEV project with Drupal core under `web/`.
- Composer dependencies installed (`ddev composer install`).
- Node toolchain for JS linting (npm or yarn; the installer selects based on
  lockfiles and can create a root `package.json` from Drupal core when missing).
  - If you use yarn, enable corepack in DDEV.
  - Note: current installer uses Yarn; future updates may select npm/yarn based
    on existing lockfiles.

## Configuration notes

- Reports:
  - `dcq-reports/` is created at the project root when running `checks`,
    `checks-full`, or the `*-fix` commands (logs + patch previews).
  - Add `dcq-reports/` to `.gitignore` if you do not want to track it.
- ESLint toolchain selection:
  - `ESLINT_TOOLCHAIN=auto` (default) prefers root toolchain when root configs exist.
  - `ESLINT_TOOLCHAIN=core` forces Drupal core JS toolchain.
  - `ESLINT_TOOLCHAIN=root` forces project root toolchain.
- ESLint config mode:
  - `ESLINT_CONFIG_MODE=nearest` (default) groups by nearest config file.
  - `ESLINT_CONFIG_MODE=fixed` forces `.eslintrc.passing.json`.
- CSpell parity:
  - Run `ddev exec php /mnt/ddev_config/drupal-code-quality/tooling/scripts/prepare-cspell.php -s .prepared` once and
    replace `.cspell.json` after reviewing the diff.
  - `ddev cspell` runs from the repo root (`.`) by default; scope is controlled
    by `.cspell.json` `ignorePaths`. Narrow the scan by passing explicit paths.
- PHPStan baseline:
  - Generate a baseline with `ddev phpstan --generate-baseline`.
  - This writes `phpstan-baseline.neon` at the project root; the wrapper will
    include it automatically when present.
  - Use a baseline to suppress known issues in legacy code or core defaults
    (for example, the shipped `settings.php` files), then work it down over
    time. Avoid using it to hide new regressions.
- PHPStan config fallback:
  - If no project `phpstan.neon*` exists, the wrapper uses the GitLab template
    config shipped with the add-on.
- PHPStan level:
  - CI parity uses level 0. The installer can set a local default level (0-9).

## Installer environment variables

- `DCQ_INSTALL_MODE`: `replace`, `skip`, or `abort` for conflict handling.
- `DCQ_NONINTERACTIVE=true`: behave like `DCQ_INSTALL_MODE=replace`.
- `DCQ_PHPSTAN_LEVEL`: set `phpstan.neon` level (0-9) without prompting.
- `DCQ_INSTALL_DEPS`: `install`/`true` to auto-install missing `drupal/core-dev`,
  `skip`/`false` to skip, or unset to prompt when interactive.
- `DCQ_INSTALL_NODE_DEPS`: `root` to install JS deps in the project root (creates
  a root `package.json` from core if missing; name uses the DDEV project name,
  and prompts to add missing Drupal deps when a root `package.json` already
  exists), `core` to install in `web/core`,
  `install`/`true` to auto-install in the project root, `skip`/`false` to skip,
  or unset to prompt (default: root). The installer selects npm/yarn based on
  existing lockfiles.
- `DCQ_INSTALL_IDE_SETTINGS`: `merge` to add missing VS Code settings and
  extension recommendations, `overwrite` to back up and replace, `skip` to
  handle manually, or unset to prompt.

## Uninstall

Removing the add-on cleans up `.ddev` commands and shims; project-root configs
remain in place intentionally. Remove them manually if desired.

## Credits

**Contributed and maintained by @CONTRIBUTOR**
