# ddev-drupal-code-quality

[![tests](https://github.com/UltraBob/ddev-drupal-code-quality/actions/workflows/tests.yml/badge.svg)](https://github.com/UltraBob/ddev-drupal-code-quality/actions/workflows/tests.yml) [![add-on registry](https://img.shields.io/badge/DDEV-Add--on_Registry-blue)](https://addons.ddev.com)
[![last commit](https://img.shields.io/github/last-commit/UltraBob/ddev-drupal-code-quality)](https://github.com/UltraBob/ddev-drupal-code-quality/commits)
![GitHub Release](https://img.shields.io/github/v/release/UltraBob/ddev-drupal-code-quality?include_prereleases)


DDEV add-on that installs local code quality tooling based on Drupal.org GitLab CI template defaults (PHPStan, PHPCS, ESLint,
Stylelint, Prettier, CSpell) for local CLI/IDE usage.

## Installation

```bash
ddev add-on get UltraBob/ddev-drupal-code-quality
```

See `README_ADDON.md` for complete usage documentation.

## Repository structure

- `commands/`: DDEV web commands copied into the project `.ddev/commands` directory.
- `drupal-code-quality/`: project-root configs and `.ddev` shims copied by the installer.
- `dcq-install.sh`: conflict-aware installer invoked by `install.yaml`.
- `install.yaml`: DDEV add-on install definition.
