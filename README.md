[![tests](https://github.com/UltraBob/ddev-drupal-code-quality/actions/workflows/tests.yml/badge.svg)](https://github.com/UltraBob/ddev-drupal-code-quality/actions/workflows/tests.yml)
[![add-on registry](https://img.shields.io/badge/DDEV-Add--on_Registry-blue)](https://addons.ddev.com)
[![last commit](https://img.shields.io/github/last-commit/UltraBob/ddev-drupal-code-quality)](https://github.com/UltraBob/ddev-drupal-code-quality/commits)
![GitHub Release](https://img.shields.io/github/v/release/UltraBob/ddev-drupal-code-quality?include_prereleases)

# ddev-drupal-code-quality

## Overview

This add-on installs a local code quality tool suite for Drupal projects and IDE usage,
starting from Drupal.org GitLab CI template defaults. It provides DDEV commands and
host shims so developers can run the same checks locally that GitLab CI runs on Drupal.org.

DDEV add-on that installs local code quality tooling based on Drupal.org GitLab CI template defaults
(PHPStan, PHPCS, ESLint, Stylelint, Prettier, CSpell) for local CLI and IDE usage.

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

## Repository structure

- `commands/`: DDEV web commands copied into project `.ddev/commands`.
- `drupal-code-quality/`: project-root configs and `.ddev` shims copied by the installer.
- `dcq-install.sh`: conflict-aware installer invoked by `install.yaml`.
- `install.yaml`: DDEV add-on install definition.

During installation, the add-on copies Drupal.org GitLab CI template default
config files into the project root. If conflicts are detected, you can choose to
back up and replace, skip, or abort. Skipping a config may diverge from the
Drupal.org GitLab CI template defaults. The installer will prompt for:
- Accept recommended settings (default: no). Choosing yes applies the
  recommended defaults without further prompts.
- Conflict handling (default: skip unless you choose replace/abort).
- PHP tooling dependencies (install `drupal/core-dev` or run `ddev composer install`).
- PHPStan default level (keep GitLab CI template level 0 or choose a local level 0-10; recommend 3).
- Node toolchain install in the project root and package manager selection.
- Missing Drupal JS dependencies when a root `package.json` exists.
- Optional `.gitignore` update for `dcq-reports/`.
- IDE settings (merge/overwrite/skip when templates are available).
The installer runs in bash so it does not require host PHP.

Recommended settings apply these defaults without further prompts:
replace conflicts (with backups), install PHP dev tools, install JS deps in the
project root, set PHPStan level 3, merge IDE settings, and add `dcq-reports/`
to `.gitignore`. Non-interactive runs with no overrides apply the recommended
settings automatically.

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
```

## Fix commands

`ddev eslint-fix`, `ddev prettier-fix`, and `ddev stylelint-fix` apply formatting changes directly, matching the behavior of their underlying tools (`eslint --fix`, `prettier --write`, `stylelint --fix`). All three commands support an optional `--preview` flag that builds a patch preview (saved to `dcq-reports/`), displays it, and prompts `Apply these changes? [y/N]` before applying. Use `--preview` when you want to review changes before committing them.

## IDE settings (VS Code/Codium)

Starter settings live in `.ddev/drupal-code-quality/ide-settings/vscode`. During install, you can
choose to merge them into `.vscode/settings.json` and
`.vscode/extensions.json`, back up and overwrite, or skip and handle them
manually.

The template points PHP tooling at `.ddev/drupal-code-quality/tooling/bin` and JS tooling at local
`node_modules`. Override the paths if you prefer a different location.

## Requirements

- DDEV project with Drupal core in the configured docroot (default `web/`).
  The installer records the docroot in `.ddev/.dcq-docroot` for wrappers.
- Composer dependencies installed (`ddev composer install`).
- Node toolchain for JS linting (npm or yarn; the installer selects based on
  lockfiles and can create a root `package.json` from Drupal core when missing).
  - If you use yarn, enable corepack in DDEV.

## Configuration notes

- Reports:
  - `dcq-reports/` is created at the project root when running `checks`
    or the `*-fix` commands (logs + patch previews).
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
  - `.cspell-project-words.txt` is created by the installer (empty) and updated
    by `ddev cspell-suggest` when you accept suggested words.
- PHPCS / PHPCBF default scope:
  - When a project `.phpcs.xml` is installed by the add-on, `ddev phpcs` and
    `ddev phpcbf` with no path default to scanning the configured docroot.
  - The generated ruleset excludes `__DOCROOT__/core/**`, `**/contrib/**`,
    `**/node_modules/**`, and `__DOCROOT__/sites/*/files/**`.
  - You can still pass explicit paths to narrow runs.
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
- GitLab CI template defaults use level 0. The installer can set a local default level (0-10).

## Installer environment variables

- `DCQ_INSTALL_MODE`: `replace`, `skip`, or `abort` for conflict handling.
- `DCQ_NONINTERACTIVE=true`: disable prompts; if no overrides are set, applies
  the recommended settings automatically.
- `DCQ_PHPSTAN_LEVEL`: set `phpstan.neon` level (0-10) without prompting.
- `DCQ_INSTALL_DEPS`: `install`/`true` to auto-install missing `drupal/core-dev`,
  `skip`/`false` to skip, or unset to prompt when interactive.
- `DCQ_INSTALL_NODE_DEPS`: `root` to install JS deps in the project root (creates
  a root `package.json` from core if missing; name uses the DDEV project name,
  and prompts to add missing Drupal deps when a root `package.json` already
  exists), `install`/`true` to auto-install in the project root, `skip`/`false`
  to skip, or unset to prompt (default: install in the project root). The
  installer selects npm/yarn based on existing lockfiles.
- `DCQ_INSTALL_GITIGNORE`: `add`/`true` to add `dcq-reports/` to `.gitignore`
  without prompting, `skip`/`false` to skip, or unset to prompt when interactive.
- `DCQ_INSTALL_IDE_SETTINGS`: `merge` to add missing VS Code settings and
  extension recommendations, `overwrite` to back up and replace, `skip` to
  handle manually, or unset to prompt.

## Uninstall

Removing the add-on cleans up the `.ddev` payload (commands, shims, assets,
manifest, and `dcq-install.sh`); project-root configs remain in place
intentionally. Remove them manually if desired.

## Credits

**Contributed and maintained by [@UltraBob](https://github.com/UltraBob)**
