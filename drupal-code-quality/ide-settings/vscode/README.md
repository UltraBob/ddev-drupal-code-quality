#ddev-generated
# VS Code / VSCodium settings

This folder contains starter VS Code settings and extension recommendations.
The settings file points common linting tools at the `.ddev/drupal-code-quality/tooling/bin` shims
installed by this add-on.

## Install options

- Merge: add missing settings to `.vscode/settings.json`, and merge
  recommended extensions into `.vscode/extensions.json` if present.
- Overwrite: back up existing files and replace them.
- Manual: copy `settings.json` and `extensions.json` into `.vscode/` yourself.

## Recommended extensions

See `extensions.json` for the extension IDs. JS-focused extensions (ESLint,
Stylelint, Prettier, CSpell) use local `node_modules` paths. The installer uses
the Node toolchain choice (prompt or `DCQ_INSTALL_NODE_DEPS`) to configure those
paths when dependencies are available. Override the paths if you prefer a
different location. Run `ddev <tool>` in the terminal to use the containerized
CLI wrappers. The generated settings also set `eslint.quiet` by default to
match GitLab CI behavior; set `DCQ_ESLINT_QUIET=0` before install to disable.
To persist this in DDEV commands, add `DCQ_ESLINT_QUIET=0` under
`web_environment` in `.ddev/config.yaml`.
