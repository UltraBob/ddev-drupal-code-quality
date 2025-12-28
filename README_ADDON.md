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
ddev add-on get ddev-drupal-code-quality
# or, for local development
ddev add-on get /path/to/ddev-drupal-code-quality

ddev restart
```

During installation, the add-on copies CI-parity config files into the project
root. If conflicts are detected, you can choose to back up and replace, skip,
or abort. Skipping a config may reduce CI parity.

If PHPStan/PHPCS/PHPCBF binaries are missing, the installer prompts to add
`drupal/core-dev` (or to run `composer install` if it is already required).

## Usage

Host shims are installed under `tooling/bin` by default (set `DCQ_SHIM_DIR` to
change this within the project root). Point IDE tool paths at these shims:

```bash
./tooling/bin/phpstan
./tooling/bin/phpcs
./tooling/bin/eslint
./tooling/bin/stylelint
./tooling/bin/prettier
./tooling/bin/cspell
./tooling/bin/checks
./tooling/bin/checks-full
```

You can also use the DDEV commands directly:

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

## Requirements

- DDEV project with Drupal core under `web/`.
- Composer dependencies installed (`composer install`).
- Node toolchain for JS linting (recommended: enable corepack in DDEV and run
  `yarn install` in `web/core`).

## Configuration notes

- ESLint toolchain selection:
  - `ESLINT_TOOLCHAIN=auto` (default) prefers root toolchain when root configs exist.
  - `ESLINT_TOOLCHAIN=core` forces Drupal core JS toolchain.
  - `ESLINT_TOOLCHAIN=root` forces project root toolchain.
- ESLint config mode:
  - `ESLINT_CONFIG_MODE=nearest` (default) groups by nearest config file.
  - `ESLINT_CONFIG_MODE=fixed` forces `.eslintrc.passing.json`.
- CSpell parity:
  - Run `php tooling/scripts/prepare-cspell.php -s .prepared` once and replace
    `.cspell.json` after reviewing the diff.

## Installer environment variables

- `DCQ_SHIM_DIR`: override shim install path (must be within the project root).
- `DCQ_INSTALL_MODE`: `replace`, `skip`, or `abort` for conflict handling.
- `DCQ_NONINTERACTIVE=true`: behave like `DCQ_INSTALL_MODE=replace`.
- `DCQ_INSTALL_DEPS`: `install`/`true` to auto-install missing `drupal/core-dev`,
  `skip`/`false` to skip, or unset to prompt when interactive.

## Uninstall

Removing the add-on cleans up `.ddev` commands and assets, but project-root
configs and `tooling/bin` shims are left in place intentionally. Remove them
manually if desired.

## Credits

**Contributed and maintained by @CONTRIBUTOR**
