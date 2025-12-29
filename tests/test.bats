#!/usr/bin/env bats

# Bats is a testing framework for Bash
# Documentation https://bats-core.readthedocs.io/en/stable/
# Bats libraries documentation https://github.com/ztombol/bats-docs

# For local tests, install bats-core, bats-assert, bats-file, bats-support
# And run this in the add-on root directory:
#   bats ./tests/test.bats
# To exclude release tests:
#   bats ./tests/test.bats --filter-tags '!release'
# To run the full Drupal install test:
#   DCQ_FULL_TESTS=1 bats ./tests/test.bats --filter-tags 'full'
# For debugging:
#   bats ./tests/test.bats --show-output-of-passing-tests --verbose-run --print-output-on-failure

load_bats_helpers() {
  local load_failed=0

  bats_library_available() {
    local lib="$1"
    local path
    IFS=':' read -r -a paths <<< "${BATS_LIB_PATH:-}"
    for path in "${paths[@]}"; do
      [ -z "$path" ] && continue
      if [ -f "${path%/}/${lib}/load.bash" ] || [ -f "${path%/}/${lib}/load.bats" ]; then
        return 0
      fi
    done
    return 1
  }

  if declare -F bats_load_library >/dev/null 2>&1; then
    if bats_library_available bats-support && bats_library_available bats-assert && bats_library_available bats-file; then
      if ! bats_load_library bats-support; then
        load_failed=1
      fi
      if ! bats_load_library bats-assert; then
        load_failed=1
      fi
      if ! bats_load_library bats-file; then
        load_failed=1
      fi
    else
      load_failed=1
    fi
  else
    load_failed=1
  fi

  if [ "$load_failed" -eq 0 ]; then
    return 0
  fi

  assert_success() {
    if [ "$status" -ne 0 ]; then
      echo "Expected success, got status $status"
      return 1
    fi
  }

  assert_failure() {
    if [ "$status" -eq 0 ]; then
      echo "Expected failure, got status $status"
      return 1
    fi
  }

  assert_output() {
    if [ "${1:-}" = "--partial" ]; then
      local expected="${2:-}"
      case "$output" in
        *"$expected"*) return 0 ;;
      esac
      echo "Expected output to contain: $expected"
      return 1
    fi
    if [ "${output:-}" != "${1:-}" ]; then
      echo "Expected output to equal: ${1:-}"
      return 1
    fi
  }

  assert_file_exist() {
    if [ ! -e "${1:-}" ]; then
      echo "Expected file to exist: ${1:-}"
      return 1
    fi
  }

  assert_not_equal() {
    if [ "${1:-}" = "${2:-}" ]; then
      echo "Expected values to differ"
      return 1
    fi
  }
}

setup() {
  set -o pipefail

  # Override this variable for your add-on:
  export GITHUB_REPO=UltraBob/ddev-drupal-code-quality

  TEST_BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  export BATS_LIB_PATH="${BATS_LIB_PATH:-}:${TEST_BREW_PREFIX}/lib:/usr/lib/bats"
  load_bats_helpers

  export DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." >/dev/null 2>&1 && pwd)"
  export PROJNAME="test-$(basename "${GITHUB_REPO}")"
  mkdir -p "${HOME}/tmp"
  export TESTDIR="$(mktemp -d "${HOME}/tmp/${PROJNAME}.XXXXXX")"
  export DDEV_NONINTERACTIVE=true
  export DDEV_NO_INSTRUMENTATION=true
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  cd "${TESTDIR}"
  run ddev config --project-name="${PROJNAME}" --project-tld=ddev.site --project-type=drupal11 --docroot=web
  assert_success
  python3 - <<'PY'
from pathlib import Path

path = Path(".ddev/config.yaml")
data = path.read_text(encoding="utf-8").splitlines()
found = False
for idx, line in enumerate(data):
    if line.strip().startswith("corepack_enable:"):
        data[idx] = "corepack_enable: true"
        found = True
        break
if not found:
    data.append("corepack_enable: true")
path.write_text("\n".join(data) + "\n", encoding="utf-8")
PY
  run ddev start -y
  assert_success
}

health_checks() {
  local commands=(phpstan phpcs phpcbf eslint stylelint prettier cspell)

  for command in "${commands[@]}"; do
    assert_file_exist ".ddev/commands/web/${command}"
    assert_file_exist "dcq-tooling/bin/${command}"
    run ddev exec test -x "/var/www/html/.ddev/commands/web/${command}"
    assert_success
    run ddev exec test -x "/var/www/html/dcq-tooling/bin/${command}"
    assert_success
  done
}

assert_addon_installed() {
  assert_file_exist ".ddev/commands/web/phpstan"
  assert_file_exist "dcq-tooling/bin/phpstan"
  assert_file_exist "tooling/ci-config/phpstan.neon"
  assert_file_exist ".eslintrc.json"
  assert_file_exist ".phpcs.xml"
}

restart_or_start_ddev() {
  run ddev restart -y
  if [ "$status" -ne 0 ]; then
    run ddev start -y
  fi
  assert_success
}

wait_for_ddev() {
  local attempts=0
  while [ "$attempts" -lt 15 ]; do
    if ddev exec true >/dev/null 2>&1; then
      return 0
    fi
    attempts=$((attempts + 1))
    sleep 2
  done
  return 1
}

wait_for_container_path() {
  local path="$1"
  local attempts=0

  while [ "$attempts" -lt 15 ]; do
    if ddev exec test -r "$path" >/dev/null 2>&1; then
      return 0
    fi
    attempts=$((attempts + 1))
    sleep 1
  done
  echo "Timed out waiting for $path to sync into the container."
  return 1
}

ensure_node_toolchain() {
  if ddev exec test -x /var/www/html/web/core/node_modules/.bin/cspell >/dev/null 2>&1; then
    return 0
  fi
  if ddev exec test -x /var/www/html/node_modules/.bin/cspell >/dev/null 2>&1; then
    return 0
  fi

  if ddev exec test -f /var/www/html/web/core/package.json >/dev/null 2>&1; then
    run ddev exec bash -lc "corepack enable && cd /var/www/html/web/core && yarn install"
    assert_success
    return 0
  fi

  if ddev exec test -f /var/www/html/package.json >/dev/null 2>&1; then
    run ddev exec bash -lc "corepack enable && cd /var/www/html && yarn install"
    assert_success
    return 0
  fi

  echo "Unable to locate a package.json to install Node toolchain."
  return 1
}

assert_log_contains() {
  local pattern="$1"
  local path="$2"

  if command -v rg >/dev/null 2>&1; then
    run rg -n "$pattern" "$path"
  else
    run grep -E -n "$pattern" "$path"
  fi
  assert_success
}

read_container_file() {
  local path="$1"

  run ddev exec cat "$path"
  assert_success || return 1
  echo "$output"
}

assert_container_contains() {
  local pattern="$1"
  local path="$2"

  run ddev exec cat "$path"
  assert_success || return 1
  case "$output" in
    *"$pattern"*) return 0 ;;
  esac
  echo "Expected container file to contain: $pattern"
  return 1
}

create_fixture_code() {
  local module_dir="web/modules/custom/dcq_test"
  local theme_dir="web/themes/custom/dcq_theme"

  mkdir -p "${module_dir}"
  cat > "${module_dir}/dcq_test.info.yml" <<'YAML'
name: DCQ Test
type: module
description: 'Fixture module for DCQ checks.'
core_version_requirement: ^11
package: Testing
YAML
  cat > "${module_dir}/dcq_test.module" <<'PHP'
<?php

/**
 * @file
 * Fixture module for DCQ checks.
 */

function dcq_test_fixture() {
  // TODO: This comment triggers PHPCS.
  if ($undefined) {
    return $undefined;
  }
  return NULL;
}
PHP
  cat > "${module_dir}/dcq_fixable.php" <<'PHP'
<?php

/**
 * @file
 * Fixture file with fixable PHPCS issues.
 */

function dcq_test_spacing($value){
  if($value){
    return $value;
  }
  return NULL;
}
PHP
  cat > "${module_dir}/README.md" <<'MD'
This modlue has a deliberate speling mistake for CSpell.
MD

  if [ -f README.md ]; then
    printf '\nThis readmne line should be flagged by CSpell.\n' >> README.md
  else
    cat > "README.md" <<'MD'
This readmne line should be flagged by CSpell.
MD
  fi

  mkdir -p "${theme_dir}/js" "${theme_dir}/css"
  cat > "${theme_dir}/dcq_theme.info.yml" <<'YAML'
name: DCQ Theme
type: theme
core_version_requirement: ^11
base theme: classy
YAML
  cat > "${theme_dir}/.eslintrc.json" <<'JSON'
{
  "root": true,
  "env": {
    "browser": true,
    "es6": true
  },
  "parserOptions": {
    "ecmaVersion": 2020
  },
  "rules": {
    "quotes": ["error", "single"],
    "semi": ["error", "always"]
  }
}
JSON
  cat > "${theme_dir}/js/fixable.js" <<'JS'
const message = "hello"
function build(){ return message }
build()
JS
  cat > "${theme_dir}/js/prettier.js" <<'JS'
const list=[1,2,3];
function  build(){
  return {value:list[0]};
}
JS
  cat > "${theme_dir}/js/unfixable.js" <<'JS'
test == test;
JS
  cat > "${theme_dir}/css/fixable.css" <<'CSS'
a {
  display: block;
  color: RED;
}
CSS
  cat > "${theme_dir}/css/unfixable.css" <<'CSS'
a { color: #12; }
CSS

  cat > "web/cspell-test.json" <<'JSON'
{
  "version": "0.2",
  "language": "en",
  "ignorePaths": []
}
JSON
}

teardown() {
  set -u -o pipefail
  if [ -n "${PROJNAME:-}" ]; then
    ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1
  fi
  # Persist TESTDIR if running inside GitHub Actions. Useful for uploading test result artifacts
  # See example at https://github.com/ddev/github-action-add-on-test#preserving-artifacts
  if [ -n "${GITHUB_ENV:-}" ]; then
    [ -e "${GITHUB_ENV:-}" ] && echo "TESTDIR=${HOME}/tmp/${PROJNAME}" >> "${GITHUB_ENV}"
  else
    [ -n "${TESTDIR:-}" ] && rm -rf "${TESTDIR}"
  fi
}

@test "install from directory" {
  set -u -o pipefail
  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  assert_addon_installed
  health_checks
}

# bats test_tags=release
@test "install from release" {
  set -u -o pipefail
  if ! command -v gh >/dev/null 2>&1; then
    skip "GitHub CLI not available; skipping release install test."
  fi
  if ! gh release list --repo "${GITHUB_REPO}" >/dev/null 2>&1; then
    skip "GitHub CLI not available; skipping release install test."
  fi
  releases="$(gh release list --repo "${GITHUB_REPO}" --limit 1 --json tagName -q '.[].tagName' 2>/dev/null || true)"
  if [ -z "${releases:-}" ]; then
    skip "No releases found for ${GITHUB_REPO}; skipping release install test."
  fi
  echo "# ddev add-on get ${GITHUB_REPO} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${GITHUB_REPO}"
  assert_success
  run ddev restart -y
  assert_success
  assert_addon_installed
  health_checks
}

# bats test_tags=full
@test "fresh install (full)" {
  set -eu -o pipefail
  if [ "${DCQ_FULL_TESTS:-}" != "1" ]; then
    echo "# DCQ_FULL_TESTS=${DCQ_FULL_TESTS:-unset}" >&3
    skip "Set DCQ_FULL_TESTS=1 to run the full Drupal install test."
  fi

  run ddev composer create-project "drupal/recommended-project:^11" .
  assert_success
  restart_or_start_ddev
  run wait_for_ddev
  assert_success
  run ddev composer require drush/drush
  assert_success
  run wait_for_ddev
  assert_success
  run ddev drush site:install --account-name=admin --account-pass=admin -y
  assert_success

  export DCQ_INSTALL_DEPS=install
  export DCQ_INSTALL_NODE_DEPS=install
  export DCQ_INSTALL_IDE_SETTINGS=overwrite
  run ddev add-on get "${DIR}"
  assert_success
  restart_or_start_ddev
  assert_addon_installed
  ensure_node_toolchain
  run ddev exec bash -lc $'mkdir -p /var/www/html/web/core/node_modules/.bin\ncat > /var/www/html/web/core/node_modules/.bin/cspell <<\'SH\'\n#!/bin/sh\necho \"core cspell should not be used\" >&2\nexit 99\nSH\nchmod +x /var/www/html/web/core/node_modules/.bin/cspell'
  assert_success
  run ./dcq-tooling/bin/cspell --version
  assert_success
  assert_file_exist ".vscode/settings.json"
  assert_file_exist ".vscode/extensions.json"
  assert_log_contains '"php.validate.executablePath": "./dcq-tooling/bin/php"' ".vscode/settings.json"
  assert_log_contains '"phpsab.executablePathCS": "./dcq-tooling/bin/phpcs"' ".vscode/settings.json"
  assert_log_contains '"phpsab.executablePathCBF": "./dcq-tooling/bin/phpcbf"' ".vscode/settings.json"
  assert_log_contains "dcq-tooling/bin/phpstan" ".vscode/settings.json"
  assert_log_contains '"stylelint.stylelintPath": "./node_modules/stylelint"' ".vscode/settings.json"
  assert_log_contains '"prettier.prettierPath": "./node_modules/prettier"' ".vscode/settings.json"
  assert_log_contains '"cSpell.path": "./node_modules/cspell"' ".vscode/settings.json"
  assert_log_contains '"eslint.nodePath": "node_modules"' ".vscode/settings.json"
  assert_log_contains '"resolvePluginsRelativeTo": "."' ".vscode/settings.json"

  run bash -lc "cd \"${PWD}/.ddev\" && DCQ_INSTALL_IDE_SETTINGS=overwrite DCQ_INSTALL_NODE_DEPS=core DCQ_INSTALL_DEPS=skip DDEV_EXECUTABLE=true bash ./dcq-install.sh"
  assert_success
  assert_log_contains '"php.validate.executablePath": "./dcq-tooling/bin/php"' ".vscode/settings.json"
  assert_log_contains '"phpsab.executablePathCS": "./dcq-tooling/bin/phpcs"' ".vscode/settings.json"
  assert_log_contains '"phpsab.executablePathCBF": "./dcq-tooling/bin/phpcbf"' ".vscode/settings.json"
  assert_log_contains "dcq-tooling/bin/phpstan" ".vscode/settings.json"
  assert_log_contains '"stylelint.stylelintPath": "./web/core/node_modules/stylelint"' ".vscode/settings.json"
  assert_log_contains '"prettier.prettierPath": "./web/core/node_modules/prettier"' ".vscode/settings.json"
  assert_log_contains '"cSpell.path": "./web/core/node_modules/cspell"' ".vscode/settings.json"
  assert_log_contains '"eslint.nodePath": "web/core/node_modules"' ".vscode/settings.json"
  assert_log_contains '"resolvePluginsRelativeTo": "./web/core"' ".vscode/settings.json"

  run ./dcq-tooling/bin/phpstan --version
  assert_success
  run ./dcq-tooling/bin/phpcs --version
  assert_success
  run ./dcq-tooling/bin/phpcbf --version
  assert_success

  create_fixture_code
  run wait_for_container_path "/var/www/html/web/cspell-test.json"
  assert_success
  run wait_for_container_path "/var/www/html/README.md"
  assert_success
  run wait_for_container_path "/var/www/html/web/modules/custom/dcq_test/README.md"
  assert_success
  run wait_for_container_path "/var/www/html/web/modules/custom/dcq_test/dcq_fixable.php"
  assert_success
  run wait_for_container_path "/var/www/html/web/themes/custom/dcq_theme/js/fixable.js"
  assert_success
  run wait_for_container_path "/var/www/html/web/themes/custom/dcq_theme/js/prettier.js"
  assert_success
  run wait_for_container_path "/var/www/html/web/themes/custom/dcq_theme/css/fixable.css"
  assert_success

  run ./dcq-tooling/bin/checks
  assert_failure

  assert_output --partial "==> phpcs"
  assert_output --partial "==> phpstan"
  assert_output --partial "==> eslint"
  assert_output --partial "==> stylelint"
  assert_output --partial "==> prettier"
  assert_output --partial "==> cspell"
  assert_output --partial "Summary:"

  run ./dcq-tooling/bin/cspell lint --no-config-search -c cspell-test.json modules/custom/dcq_test/README.md
  assert_failure
  assert_output --partial "modlue"

  run ./dcq-tooling/bin/cspell
  assert_failure
  assert_output --partial "readmne"

  before_phpcbf="$(read_container_file /var/www/html/web/modules/custom/dcq_test/dcq_fixable.php)"
  run ./dcq-tooling/bin/phpcbf web/modules/custom/dcq_test/dcq_fixable.php
  if [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; then
    echo "Expected PHPCBF to exit 0 or 1, got $status"
    return 1
  fi
  assert_output --partial "A TOTAL OF"
  after_phpcbf="$(read_container_file /var/www/html/web/modules/custom/dcq_test/dcq_fixable.php)"
  assert_not_equal "$before_phpcbf" "$after_phpcbf"

  before_eslint="$(read_container_file /var/www/html/web/themes/custom/dcq_theme/js/fixable.js)"
  run ./dcq-tooling/bin/eslint-fix --yes --allow-dirty-outside-targets ./web/themes/custom/dcq_theme/js/fixable.js
  if [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; then
    echo "Expected ESLint-fix to exit 0 or 1, got $status"
    return 1
  fi
  assert_output --partial "ESLint-fix summary:"
  after_eslint="$(read_container_file /var/www/html/web/themes/custom/dcq_theme/js/fixable.js)"
  assert_not_equal "$before_eslint" "$after_eslint"

  before_prettier="$(read_container_file /var/www/html/web/themes/custom/dcq_theme/js/prettier.js)"
  run ./dcq-tooling/bin/prettier-fix --yes --allow-dirty-outside-targets web/themes/custom/dcq_theme/js/prettier.js
  assert_success
  after_prettier="$(read_container_file /var/www/html/web/themes/custom/dcq_theme/js/prettier.js)"
  assert_not_equal "$before_prettier" "$after_prettier"

  before_stylelint="$(read_container_file /var/www/html/web/themes/custom/dcq_theme/css/fixable.css)"
  run ./dcq-tooling/bin/stylelint-fix --yes --allow-dirty-outside-targets web/themes/custom/dcq_theme/css/fixable.css
  assert_success
  after_stylelint="$(read_container_file /var/www/html/web/themes/custom/dcq_theme/css/fixable.css)"
  assert_not_equal "$before_stylelint" "$after_stylelint"
  assert_container_contains "display: block;" "/var/www/html/web/themes/custom/dcq_theme/css/fixable.css"
}
