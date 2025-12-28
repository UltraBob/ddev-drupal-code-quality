# ddev-drupal-code-quality

DDEV add-on that installs Drupal GitLab CI parity tooling (PHPStan, PHPCS, ESLint,
Stylelint, Prettier, CSpell) for local CLI/IDE usage.

## Repository structure

- `commands/`: DDEV web commands copied into the project `.ddev/commands` directory.
- `dcq-assets/`: project-root configs and host shims copied by the installer.
- `dcq-install.sh`: conflict-aware installer invoked by `install.yaml`.
- `install.yaml`: DDEV add-on install definition.

## Local testing

```bash
ddev add-on get /path/to/ddev-drupal-code-quality
ddev restart
```

See `README_ADDON.md` for end-user usage.
