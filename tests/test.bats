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
# To run node package manager selection tests:
#   bats ./tests/test.bats --filter-tags 'node'
# For debugging:
#   bats ./tests/test.bats --show-output-of-passing-tests --verbose-run --print-output-on-failure
# For parallel execution (faster):
#   bats ./tests/test.bats --jobs 4

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

  assert_file_not_exist() {
    if [ -e "${1:-}" ]; then
      echo "Expected file to be absent: ${1:-}"
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

setup_file() {
  # No setup needed - progressive backoff + staggered starts handle parallel conflicts
  :
}

# Retry helper for DDEV commands that may fail due to parallel execution conflicts
retry_ddev_command() {
  local max_attempts=8
  local attempts=0

  while [ "$attempts" -lt "$max_attempts" ]; do
    run "$@"
    if [ "$status" -eq 0 ]; then
      return 0
    fi

    # Check for known transient errors in parallel execution
    if echo "$output" | grep -qE "(container name.*already in use|global-cache|ddev-router|ddev-ssh-agent|unhealthy|FAILED phpstatus|FAILED mailpit|Permission denied|address already in use|removal.*already in progress|container exited|health check timed out|failed to become ready)"; then
      attempts=$((attempts + 1))
      if [ "$attempts" -lt "$max_attempts" ]; then
        # Progressive backoff: 3s, 6s, 9s, 12s, 15s, 18s, 21s
        # Quick retry for transient issues, longer waits for serious contention
        local sleep_time=$((3 * (attempts + 1)))
        echo "# DDEV conflict detected, retrying (attempt $((attempts + 1))/$max_attempts) in ${sleep_time}s..." >&3
        sleep "$sleep_time"
        continue
      fi
    fi

    # Non-transient error or max attempts reached, return failure
    return 1
  done
}

setup() {
  set -o pipefail

  # Start timing the full test lifecycle (setup + test + teardown)
  SECONDS=0

  # Override this variable for your add-on:
  export GITHUB_REPO=UltraBob/ddev-drupal-code-quality

  TEST_BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  export BATS_LIB_PATH="${BATS_LIB_PATH:-}:${TEST_BREW_PREFIX}/lib:/usr/lib/bats"
  load_bats_helpers

  export DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." >/dev/null 2>&1 && pwd)"

  # Show test progress indicator
  printf '[%2d/%d] Running: %s\n' "${BATS_TEST_NUMBER}" "${BATS_SUITE_TEST_NUMBER}" "${BATS_TEST_NAME}" >&3

  # Stagger parallel test starts to reduce shared resource contention
  # Only delay if running in parallel mode (bats --jobs N)
  if [ -n "${BATS_SEMAPHORE_NUMBER:-}" ]; then
    # Random delay 0-4 seconds to spread out simultaneous DDEV starts
    sleep $((RANDOM % 5))
  fi

  mkdir -p "${HOME}/tmp"
  local base_name="test-$(basename "${GITHUB_REPO}")"
  export TESTDIR="$(mktemp -d "${HOME}/tmp/${base_name}.XXXXXX")"
  # Extract unique suffix from TESTDIR for parallel-safe project naming
  local unique_suffix="$(basename "${TESTDIR}" | sed "s/^${base_name}\.//")"
  # Sanitize test name for project name: strip "test" prefix, lowercase, replace special chars, remove "test" words, truncate to 30 chars
  local test_slug="$(echo "${BATS_TEST_NAME}" | sed -E 's/^test[[:space:]]+//' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-test-/-/g; s/^test-//; s/-test$//' | sed 's/-\+/-/g' | sed 's/^-//' | sed 's/-$//' | cut -c1-30)"
  # Include test number for progress tracking in OrbStack
  local test_num="${BATS_TEST_NUMBER:-0}"
  export PROJNAME="dcq-${test_num}-${test_slug}-${unique_suffix}"
  export DDEV_NONINTERACTIVE=true
  export DDEV_NO_INSTRUMENTATION=true
  export DCQ_NONINTERACTIVE=true
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  cd "${TESTDIR}"
  docroot="${DCQ_TEST_DOCROOT:-web}"
  mkdir -p "$docroot"
  run ddev config --project-name="${PROJNAME}" --project-tld=ddev.site --project-type=drupal11 --docroot="$docroot"
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
  retry_ddev_command ddev start -y
  assert_success

  # Record setup time and start test body timer
  export SETUP_TIME=$SECONDS
  SECONDS=0
}

health_checks() {
  local commands=(phpstan phpcs phpcbf eslint stylelint prettier cspell)

  # Host-side checks
  for command in "${commands[@]}"; do
    assert_file_exist ".ddev/commands/web/${command}"
    assert_file_exist ".ddev/drupal-code-quality/tooling/bin/${command}"
  done

  # Batch all container checks into single ddev exec call
  local checks=""
  for command in "${commands[@]}"; do
    checks+="test -x /var/www/html/.ddev/commands/web/${command} && "
    checks+="test -x /mnt/ddev_config/drupal-code-quality/tooling/bin/${command} && "
  done
  checks="${checks% && }"  # Remove trailing &&

  run ddev exec bash -c "$checks"
  assert_success
}

assert_addon_installed() {
  assert_file_exist ".ddev/commands/web/phpstan"
  assert_file_exist ".ddev/drupal-code-quality/tooling/bin/phpstan"
  assert_file_exist "phpstan.neon"
  assert_file_exist ".eslintrc.json"
  assert_file_exist ".phpcs.xml"
  assert_file_not_exist "ide-settings"
}

assert_phpstan_level() {
  local expected="$1"

  if command -v rg >/dev/null 2>&1; then
    run rg -n "level:[[:space:]]*${expected}" "phpstan.neon"
  else
    run grep -E -n "level:[[:space:]]*${expected}" "phpstan.neon"
  fi
  assert_success
}

write_stub_package_json() {
  local path="$1"
  cat > "$path" <<'JSON'
{
  "name": "dcq-test",
  "private": true,
  "devDependencies": {
    "eslint-plugin-no-jquery": "^3.1.1",
    "stylelint-prettier": "^5.0.3"
  }
}
JSON
}

write_stub_package_lock() {
  local path="$1"
  cat > "$path" <<'JSON'
{
  "name": "dcq-test",
  "version": "1.0.0",
  "lockfileVersion": 3,
  "requires": true,
  "packages": {}
}
JSON
}

write_jsonc_settings() {
  local path="$1"
  cat > "$path" <<'JSONC'
// VS Code settings with JSONC features
{
  // Preserve this key
  "dcq.customSetting": "keep",
  "eslint.nodePath": "custom",
  "editor.formatOnSave": true,
  "files.exclude": {
    "**/.git": true,
  },
}
JSONC
}

write_jsonc_extensions() {
  local path="$1"
  cat > "$path" <<'JSONC'
// VS Code extensions with JSONC features
{
  "recommendations": [
    "example.extension",
    "dbaeumer.vscode-eslint",
  ],
  "unwantedRecommendations": [
    "example.unwanted",
  ],
}
JSONC
}

write_invalid_jsonc_settings() {
  local path="$1"
  cat > "$path" <<'JSONC'
// Invalid JSONC (missing closing brace)
{
  "dcq.customSetting": "keep",
  "editor.formatOnSave": true,
  "files.exclude": {
    "**/.git": true,
  },
JSONC
}

assert_container_file_exist() {
  local path="$1"

  run ddev exec test -f "$path"
  assert_success
}

restart_or_start_ddev() {
  retry_ddev_command ddev restart -y
  if [ "$status" -ne 0 ]; then
    retry_ddev_command ddev start -y
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

  while [ "$attempts" -lt 5 ]; do
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

run_with_prompt_yes() {
  local prompt="$1"
  shift

  local python_bin=""
  if command -v python3 >/dev/null 2>&1; then
    python_bin="python3"
  elif command -v python >/dev/null 2>&1; then
    python_bin="python"
  else
    skip "python not available for prompt automation"
  fi

  run "$python_bin" - "$prompt" "$@" <<'PY'
import os
import pty
import select
import sys

prompt = sys.argv[1].encode()
cmd = sys.argv[2:]
sent = False
buf = b""

pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)

try:
    while True:
        r, _, _ = select.select([fd], [], [], 1)
        if fd in r:
            data = os.read(fd, 1024)
            if not data:
                break
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
            if not sent:
                buf = (buf + data)[-4096:]
                if prompt in buf:
                    os.write(fd, b"y\n")
                    sent = True
except OSError:
    pass

_, status = os.waitpid(pid, 0)
code = os.waitstatus_to_exitcode(status)
sys.exit(code)
PY
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
  cat > "cspell-test.md" <<'MD'
This roottypo line should be flagged by CSpell.
MD

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

  # Record test body time and start teardown timer
  local test_time=$SECONDS
  local teardown_start=$SECONDS

  # Perform cleanup operations
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

  # Calculate complete timing breakdown
  local teardown_time=$((SECONDS - teardown_start))
  local total_time=$((${SETUP_TIME:-0} + test_time + teardown_time))

  # Report full test lifecycle timing
  echo "# ${BATS_TEST_NAME} completed in ${total_time}s (setup: ${SETUP_TIME:-0}s, test: ${test_time}s, teardown: ${teardown_time}s)" >&3
}

@test "install from directory" {
  set -u -o pipefail
  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${DIR}"
  assert_success
  assert_addon_installed
  assert_phpstan_level "3"
  if command -v rg >/dev/null 2>&1; then
    run rg -n "^dcq-reports/$" ".gitignore"
  else
    run grep -E -n "^dcq-reports/$" ".gitignore"
  fi
  assert_success
  health_checks
}

@test "installer prompt accepts recommended settings" {
  set -u -o pipefail
  unset DCQ_NONINTERACTIVE
  unset DDEV_NONINTERACTIVE
  unset DCQ_INSTALL_MODE
  unset DCQ_INSTALL_DEPS
  unset DCQ_INSTALL_NODE_DEPS
  unset DCQ_PHPSTAN_LEVEL
  unset DCQ_INSTALL_IDE_SETTINGS
  unset DCQ_INSTALL_GITIGNORE

  python_bin=""
  if command -v python3 >/dev/null 2>&1; then
    python_bin="python3"
  elif command -v python >/dev/null 2>&1; then
    python_bin="python"
  else
    skip "python not available for prompt automation"
  fi

  run "$python_bin" - <<PY
import os
import pty
import select
import sys

cmd = ["ddev", "add-on", "get", "${DIR}"]
prompt = b"Accept recommended settings? (y/N)"
sent = False
buf = b""

pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)

try:
    while True:
        r, _, _ = select.select([fd], [], [], 1)
        if fd in r:
            data = os.read(fd, 1024)
            if not data:
                break
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
            buf += data
            if (not sent) and (prompt in buf):
                os.write(fd, b"y\\n")
                sent = True
except OSError:
    pass

_, status = os.waitpid(pid, 0)
code = os.waitstatus_to_exitcode(status)
sys.exit(code)
PY
  assert_success
  assert_output --partial "Accept recommended settings? (y/N)"
  assert_phpstan_level "3"
  if command -v rg >/dev/null 2>&1; then
    run rg -n "^dcq-reports/$" ".gitignore"
  else
    run grep -E -n "^dcq-reports/$" ".gitignore"
  fi
  assert_success
}

@test "VS Code settings merge handles JSONC" {
  set -u -o pipefail
  export DCQ_INSTALL_DEPS=skip
  export DCQ_INSTALL_NODE_DEPS=skip
  export DCQ_INSTALL_IDE_SETTINGS=merge

  mkdir -p ".vscode"
  write_jsonc_settings ".vscode/settings.json"
  write_jsonc_extensions ".vscode/extensions.json"
  cp ".vscode/settings.json" ".vscode/settings.json.original"
  cp ".vscode/extensions.json" ".vscode/extensions.json.original"

  run bash -lc "ddev add-on get \"${DIR}\" 2>&1"
  assert_success
  assert_output --partial "MERGE: "
  assert_output --partial ".vscode/settings.json"
  assert_output --partial ".vscode/extensions.json"

  assert_file_exist ".vscode/settings.json.bak"
  assert_file_exist ".vscode/extensions.json.bak"
  run cmp -s ".vscode/settings.json.original" ".vscode/settings.json.bak"
  assert_success
  run cmp -s ".vscode/extensions.json.original" ".vscode/extensions.json.bak"
  assert_success

  run python3 - ".vscode/settings.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)

assert data.get("dcq.customSetting") == "keep"
assert data.get("eslint.nodePath") == "custom"
PY
  assert_success

  run python3 - ".vscode/extensions.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)

recs = data.get("recommendations", [])
assert "example.extension" in recs
assert "dbaeumer.vscode-eslint" in recs
PY
  assert_success
}

@test "VS Code settings merge skips backup when no changes" {
  set -u -o pipefail
  export DCQ_INSTALL_DEPS=skip
  export DCQ_INSTALL_NODE_DEPS=skip
  export DCQ_INSTALL_MODE=skip
  export DCQ_INSTALL_IDE_SETTINGS=overwrite

  run ddev add-on get "${DIR}"
  assert_success

  assert_file_exist ".vscode/settings.json"
  assert_file_exist ".vscode/extensions.json"
  cp ".vscode/settings.json" ".vscode/settings.json.original"
  cp ".vscode/extensions.json" ".vscode/extensions.json.original"

  export DCQ_INSTALL_IDE_SETTINGS=merge
  run bash -lc "ddev add-on get \"${DIR}\" 2>&1"
  assert_success

  run bash -lc 'compgen -G ".vscode/settings.json.bak*"'
  assert_failure
  run bash -lc 'compgen -G ".vscode/extensions.json.bak*"'
  assert_failure

  run cmp -s ".vscode/settings.json.original" ".vscode/settings.json"
  assert_success
  run cmp -s ".vscode/extensions.json.original" ".vscode/extensions.json"
  assert_success
}

@test "VS Code settings merge skips invalid JSONC with warning" {
  set -u -o pipefail
  export DCQ_INSTALL_DEPS=skip
  export DCQ_INSTALL_NODE_DEPS=skip
  export DCQ_INSTALL_IDE_SETTINGS=merge

  mkdir -p ".vscode"
  write_invalid_jsonc_settings ".vscode/settings.json"
  cp ".vscode/settings.json" ".vscode/settings.json.original"

  run bash -lc "ddev add-on get \"${DIR}\" 2>&1"
  assert_success
  assert_output --partial "Unable to merge IDE settings; install manually from"

  run cmp -s ".vscode/settings.json.original" ".vscode/settings.json"
  assert_success
}

@test "VS Code settings omit JS tool paths when node_modules missing" {
  set -u -o pipefail
  export DCQ_INSTALL_DEPS=skip
  export DCQ_INSTALL_NODE_DEPS=skip
  export DCQ_INSTALL_IDE_SETTINGS=overwrite

  run ddev add-on get "${DIR}"
  assert_success
  assert_output --partial "JS tool paths not configured (node_modules missing)."

  assert_file_exist ".vscode/settings.json"
  run grep -q '"eslint.nodePath"' ".vscode/settings.json"
  assert_failure
  run grep -q '"eslint.options"' ".vscode/settings.json"
  assert_failure
  run grep -q '"stylelint.stylelintPath"' ".vscode/settings.json"
  assert_failure
  run grep -q '"prettier.prettierPath"' ".vscode/settings.json"
  assert_failure
}

@test "path map prefers DDEV_HOST_PROJECT_ROOT" {
  set -u -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  run ddev exec bash -lc 'export DDEV_HOST_PROJECT_ROOT="/tmp/dcq-host-root"; source /mnt/ddev_config/commands/helpers/path-map.sh; map_path "/tmp/dcq-host-root/path/to/file.php"'
  assert_success
  assert_output "/var/www/html/path/to/file.php"
  run ddev exec bash -lc 'source /mnt/ddev_config/commands/helpers/path-map.sh; map_path "/var/www/html/web/index.php"'
  assert_success
  assert_output "/var/www/html/web/index.php"
}

@test "install from directory with non-web docroot" {
  set -u -o pipefail
  mkdir -p docroot
  run ddev config --docroot=docroot
  assert_success
  retry_ddev_command ddev restart -y
  assert_success
  run ddev add-on get "${DIR}"
  assert_success
  assert_addon_installed
  assert_file_exist ".ddev/.dcq-docroot"
  run cat ".ddev/.dcq-docroot"
  assert_output "docroot"
  run grep -n "docroot/core" ".cspell.json"
  assert_success
  run grep -n "web/core" ".cspell.json"
  assert_failure
  run grep -n "docroot/sites" ".phpcs.xml"
  assert_success

  # Verify PHPStan config uses custom docroot
  run grep -q "docroot/modules/custom" phpstan.neon
  assert_success
  run grep -q "docroot/sites" phpstan.neon
  assert_success
  run grep -q "docroot/sites/\*/files" phpstan.neon
  assert_success
}

@test "install from directory with phpstan level override" {
  set -u -o pipefail
  export DCQ_PHPSTAN_LEVEL=3
  run ddev add-on get "${DIR}"
  assert_success
  assert_addon_installed
  assert_phpstan_level "3"
}

@test "install from directory with phpstan level 10" {
  set -u -o pipefail
  export DCQ_PHPSTAN_LEVEL=10
  run ddev add-on get "${DIR}"
  assert_success
  assert_addon_installed
  assert_phpstan_level "10"
}

@test "phpstan config includes default paths and excludes after install" {
  set -u -o pipefail
  run ddev add-on get "${DIR}"
  assert_success

  # Check that paths section exists
  run grep -q "paths:" phpstan.neon
  assert_success

  # Check for expected default paths
  run grep -q "web/modules/custom" phpstan.neon
  assert_success
  run grep -q "web/themes/custom" phpstan.neon
  assert_success
  run grep -q "web/sites" phpstan.neon
  assert_success

  # Check for excludePaths
  run grep -q "excludePaths:" phpstan.neon
  assert_success
  run grep -q "web/sites/\*/files" phpstan.neon
  assert_success
}

@test "cspell config is expanded during installation" {
  set -u -o pipefail
  run ddev add-on get "${DIR}"
  assert_success

  # Verify expanded dictionaries array includes Drupal and project-words
  run grep -q '"drupal"' .cspell.json
  assert_success
  run grep -q '"project-words"' .cspell.json
  assert_success

  # Verify dictionaryDefinitions were added
  run grep -q 'web/core/misc/cspell/drupal-dictionary.txt' .cspell.json
  assert_success
  run grep -q '.cspell-project-words.txt' .cspell.json
  assert_success

  # Verify expanded words array includes standard additions
  run grep -q '"lando"' .cspell.json
  assert_success
  run grep -q '"ddev"' .cspell.json
  assert_success
  run grep -q '"endapply"' .cspell.json
  assert_success

  # Verify expanded ignorePaths includes dcq-reports
  run grep -q 'dcq-reports' .cspell.json
  assert_success

  # Verify .cspell-project-words.txt was created
  assert_file_exist ".cspell-project-words.txt"
}

@test "remove cleans ddev assets and shims" {
  set -u -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  assert_addon_installed

  run ddev add-on remove "${DIR}"
  assert_success
  assert_file_not_exist ".ddev/drupal-code-quality"
  assert_file_not_exist ".ddev/drupal-code-quality/tooling/bin/phpstan"
}

# bats test_tags=release
@test "install from release" {
  set -u -o pipefail
  echo "# ddev add-on get ${GITHUB_REPO} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${GITHUB_REPO}"
  if [ "$status" -ne 0 ]; then
    case "$output" in
      *"no releases found"*)
        skip "No releases found for ${GITHUB_REPO}; skipping release install test."
        ;;
    esac
  fi
  assert_success
  assert_addon_installed
  health_checks
}

# bats test_tags=node
@test "node install uses npm when package-lock.json present" {
  set -u -o pipefail
  export DCQ_INSTALL_DEPS=skip
  export DCQ_INSTALL_NODE_DEPS=install
  mkdir -p web/core
  write_stub_package_json "web/core/package.json"
  write_stub_package_json "package.json"
  write_stub_package_lock "package-lock.json"

  run ddev add-on get "${DIR}"
  assert_success
  assert_output --partial "Node dependencies added (project root)."
  assert_container_file_exist "/var/www/html/package-lock.json"
  assert_container_file_exist "/var/www/html/node_modules/eslint-plugin-no-jquery/package.json"
  assert_container_file_exist "/var/www/html/node_modules/stylelint-prettier/package.json"
}

# bats test_tags=node
@test "node install uses yarn when yarn.lock present" {
  set -u -o pipefail
  export DCQ_INSTALL_DEPS=skip
  export DCQ_INSTALL_NODE_DEPS=install
  mkdir -p web/core
  write_stub_package_json "web/core/package.json"
  write_stub_package_json "package.json"
  printf '{}' > "yarn.lock"

  run ddev exec bash -lc "command -v yarn"
  if [ "$status" -ne 0 ]; then
    skip "Yarn not available in container."
  fi

  run ddev add-on get "${DIR}"
  assert_success
  assert_output --partial "Node dependencies added (project root)."
  assert_container_file_exist "/var/www/html/yarn.lock"
  assert_container_file_exist "/var/www/html/node_modules/eslint-plugin-no-jquery/package.json"
  assert_container_file_exist "/var/www/html/node_modules/stylelint-prettier/package.json"
}

# bats test_tags=node
@test "node install uses npm when no lockfile present" {
  set -u -o pipefail
  export DCQ_INSTALL_DEPS=skip
  export DCQ_INSTALL_NODE_DEPS=install
  mkdir -p web/core
  write_stub_package_json "web/core/package.json"
  write_stub_package_json "package.json"

  run ddev add-on get "${DIR}"
  assert_success
  assert_output --partial "Node dependencies added (project root)."
  assert_container_file_exist "/var/www/html/package-lock.json"
  assert_container_file_exist "/var/www/html/node_modules/eslint-plugin-no-jquery/package.json"
  assert_container_file_exist "/var/www/html/node_modules/stylelint-prettier/package.json"
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
  run ddev exec bash -lc $'mkdir -p /var/www/html/web/core/node_modules/.bin\ncat > /var/www/html/web/core/node_modules/.bin/cspell <<\'SH\'\n#!/bin/sh\necho \"core cspell should not be used\" >&2\nexit 99\nSH\nchmod +x /var/www/html/web/core/node_modules/.bin/cspell\nmkdir -p /var/www/html/web/core/node_modules/stylelint/bin\ncat > /var/www/html/web/core/node_modules/stylelint/bin/stylelint.mjs <<\'JS\'\nconsole.error(\"core stylelint should not be used\");\nprocess.exit(99);\nJS\ncat > /var/www/html/web/core/node_modules/.bin/prettier <<\'SH\'\n#!/bin/sh\necho \"core prettier should not be used\" >&2\nexit 99\nSH\nchmod +x /var/www/html/web/core/node_modules/.bin/prettier'
  assert_success
  run ./.ddev/drupal-code-quality/tooling/bin/cspell --version
  assert_success
  run ./.ddev/drupal-code-quality/tooling/bin/stylelint --version
  assert_success
  run ./.ddev/drupal-code-quality/tooling/bin/prettier --version
  assert_success
  assert_file_exist ".vscode/settings.json"
  assert_file_exist ".vscode/extensions.json"
  assert_log_contains '"php.validate.executablePath": ".ddev/drupal-code-quality/tooling/bin/php"' ".vscode/settings.json"
  assert_log_contains '"phpsab.executablePathCS": ".ddev/drupal-code-quality/tooling/bin/phpcs"' ".vscode/settings.json"
  assert_log_contains '"phpsab.executablePathCBF": ".ddev/drupal-code-quality/tooling/bin/phpcbf"' ".vscode/settings.json"
  assert_log_contains ".ddev/drupal-code-quality/tooling/bin/phpstan" ".vscode/settings.json"
  assert_log_contains '"stylelint.stylelintPath": "./node_modules/stylelint"' ".vscode/settings.json"
  assert_log_contains '"prettier.prettierPath": "./node_modules/prettier"' ".vscode/settings.json"
  assert_log_contains '"eslint.nodePath": "node_modules"' ".vscode/settings.json"
  assert_log_contains '"resolvePluginsRelativeTo": "."' ".vscode/settings.json"

  run ./.ddev/drupal-code-quality/tooling/bin/phpstan --version
  assert_success
  run ./.ddev/drupal-code-quality/tooling/bin/phpcs --version
  assert_success
  run ./.ddev/drupal-code-quality/tooling/bin/phpcbf --version
  assert_success

  create_fixture_code
  run wait_for_container_path "/var/www/html/web/cspell-test.json"
  assert_success
  run wait_for_container_path "/var/www/html/cspell-test.md"
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

  # Batch git setup commands into single exec call
  run ddev exec bash -lc "command -v git >/dev/null && cd /var/www/html && (git rev-parse --is-inside-work-tree >/dev/null 2>&1 || git init >/dev/null) && printf 'unrelated change' > unrelated.txt"
  assert_success

  run ./.ddev/drupal-code-quality/tooling/bin/checks
  assert_failure

  assert_output --partial "==> phpcs"
  assert_output --partial "==> phpstan"
  assert_output --partial "==> eslint"
  assert_output --partial "==> stylelint"
  assert_output --partial "==> prettier"
  assert_output --partial "==> cspell"
  assert_output --partial "Summary:"

  run ./.ddev/drupal-code-quality/tooling/bin/cspell lint --no-config-search -c web/cspell-test.json modules/custom/dcq_test/README.md
  assert_failure
  assert_output --partial "modlue"

  run ./.ddev/drupal-code-quality/tooling/bin/cspell
  assert_failure
  assert_output --partial "modlue"
  assert_output --partial "roottypo"

  before_phpcbf="$(read_container_file /var/www/html/web/modules/custom/dcq_test/dcq_fixable.php)"
  run ./.ddev/drupal-code-quality/tooling/bin/phpcbf web/modules/custom/dcq_test/dcq_fixable.php
  if [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; then
    echo "Expected PHPCBF to exit 0 or 1, got $status"
    return 1
  fi
  assert_output --partial "A TOTAL OF"
  after_phpcbf="$(read_container_file /var/www/html/web/modules/custom/dcq_test/dcq_fixable.php)"
  assert_not_equal "$before_phpcbf" "$after_phpcbf"

  before_eslint="$(read_container_file /var/www/html/web/themes/custom/dcq_theme/js/fixable.js)"
  run_with_prompt_yes "Apply these changes? [y/N]" ./.ddev/drupal-code-quality/tooling/bin/eslint-fix ./web/themes/custom/dcq_theme/js/fixable.js
  if [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; then
    echo "Expected ESLint-fix to exit 0 or 1, got $status"
    return 1
  fi
  assert_output --partial "Warning: unstaged changes detected outside target paths."
  assert_output --partial "Apply these changes? [y/N]"
  assert_output --partial "ESLint-fix summary:"
  after_eslint="$(read_container_file /var/www/html/web/themes/custom/dcq_theme/js/fixable.js)"
  assert_not_equal "$before_eslint" "$after_eslint"

  before_prettier="$(read_container_file /var/www/html/web/themes/custom/dcq_theme/js/prettier.js)"
  run_with_prompt_yes "Apply these changes? [y/N]" ./.ddev/drupal-code-quality/tooling/bin/prettier-fix web/themes/custom/dcq_theme/js/prettier.js
  assert_success
  assert_output --partial "Warning: unstaged changes detected outside target paths."
  assert_output --partial "Apply these changes? [y/N]"
  after_prettier="$(read_container_file /var/www/html/web/themes/custom/dcq_theme/js/prettier.js)"
  assert_not_equal "$before_prettier" "$after_prettier"

  before_stylelint="$(read_container_file /var/www/html/web/themes/custom/dcq_theme/css/fixable.css)"
  run_with_prompt_yes "Apply these changes? [y/N]" ./.ddev/drupal-code-quality/tooling/bin/stylelint-fix web/themes/custom/dcq_theme/css/fixable.css
  assert_success
  assert_output --partial "Warning: unstaged changes detected outside target paths."
  assert_output --partial "Apply these changes? [y/N]"
  after_stylelint="$(read_container_file /var/www/html/web/themes/custom/dcq_theme/css/fixable.css)"
  assert_not_equal "$before_stylelint" "$after_stylelint"
  assert_container_contains "display: block;" "/var/www/html/web/themes/custom/dcq_theme/css/fixable.css"
}
