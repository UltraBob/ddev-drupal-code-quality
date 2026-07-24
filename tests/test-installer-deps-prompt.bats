#!/usr/bin/env bats

setup() {
  set -euo pipefail

  export ADDON_ROOT
  ADDON_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export TEST_ROOT
  TEST_ROOT="$(mktemp -d /tmp/dcq-installer-deps.XXXXXX)"
  export APP_ROOT="${TEST_ROOT}/app"
  export STUB_BIN="${TEST_ROOT}/bin"
  export DDEV_STUB_LOG="${TEST_ROOT}/ddev.log"

  mkdir -p "${APP_ROOT}/.ddev" "${APP_ROOT}/vendor/bin" "${STUB_BIN}"
  cat > "${APP_ROOT}/.ddev/config.yaml" <<'YAML'
name: dcq-test
docroot: web
YAML
  cat > "${APP_ROOT}/composer.json" <<'JSON'
{
  "name": "dcq/test-project",
  "type": "project"
}
JSON

  cat > "${STUB_BIN}/ddev" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

log_file="${DDEV_STUB_LOG:?missing DDEV_STUB_LOG}"
printf '%s\n' "$*" >> "${log_file}"

if [ "${1:-}" = "exec" ] && [ "${2:-}" = "true" ]; then
  exit 0
fi

if [ "${1:-}" = "exec" ] && [ "${2:-}" = "test" ] && [ "${3:-}" = "-f" ]; then
  exit 1
fi

if [ "${1:-}" = "composer" ] && [ "${2:-}" = "require" ]; then
  exit 0
fi

if [ "${1:-}" = "composer" ] && [ "${2:-}" = "install" ]; then
  exit 0
fi

exit 0
SH
  chmod +x "${STUB_BIN}/ddev"
}

teardown() {
  rm -rf "${TEST_ROOT}"
}

run_search() {
  local pattern="$1"
  local file="$2"
  if command -v rg >/dev/null 2>&1; then
    run rg -n -- "$pattern" "$file"
  else
    run grep -E -n -- "$pattern" "$file"
  fi
}

@test "interactive unset DCQ_INSTALL_DEPS prompts before installing core-dev" {
  unset DCQ_INSTALL_DEPS
  unset DCQ_NONINTERACTIVE
  unset DDEV_NONINTERACTIVE

  run python3 - <<'PY'
import os
import pty
import select
import signal
import sys

addon_root = os.environ["ADDON_ROOT"]
app_root = os.environ["APP_ROOT"]
stub_bin = os.environ["STUB_BIN"]
env = os.environ.copy()
env["PATH"] = f"{stub_bin}:{env['PATH']}"
env["DDEV_APPROOT"] = app_root
env["DCQ_INSTALL_NODE_DEPS"] = "skip"
env["DCQ_INSTALL_IDE_SETTINGS"] = "skip"
env["DCQ_INSTALL_GITIGNORE"] = "skip"
env["DCQ_PHPSTAN_LEVEL"] = "0"
env.pop("DCQ_INSTALL_DEPS", None)
env.pop("DCQ_NONINTERACTIVE", None)
env.pop("DDEV_NONINTERACTIVE", None)

cmd = ["bash", os.path.join(addon_root, "dcq-install.sh")]
prompts = {
    b"Accept recommended settings for this install? [Y/n]": b"n\n",
    b"Install drupal/core-dev now to provide PHP code quality tools": b"n\n",
}

seen = set()
buf = b""
idle_ticks = 0
timed_out = False

pid, fd = pty.fork()
if pid == 0:
    os.chdir(addon_root)
    os.execvpe(cmd[0], cmd, env)

try:
    while True:
        r, _, _ = select.select([fd], [], [], 2)
        if fd in r:
            data = os.read(fd, 1024)
            if not data:
                break
            idle_ticks = 0
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
            buf = (buf + data)[-16384:]
            for prompt, response in prompts.items():
                if prompt in buf and prompt not in seen:
                    os.write(fd, response)
                    seen.add(prompt)
        else:
            idle_ticks += 1
            if idle_ticks > 30:
                timed_out = True
                break
except OSError:
    pass

if timed_out:
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass

_, status = os.waitpid(pid, 0)
code = os.waitstatus_to_exitcode(status)
sys.exit(code)
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"Accept recommended settings for this install? [Y/n]"* ]]
  [[ "$output" == *"Install drupal/core-dev now to provide PHP code quality tools"* ]]
  [[ "$output" == *"Project root tooling configs updated"* ]]

  run_search "^composer require --dev drupal/core-dev --with-all-dependencies$" "${DDEV_STUB_LOG}"
  [ "$status" -ne 0 ]
  run_search "^composer config --no-plugins allow-plugins\\.tbachert/spi false$" "${DDEV_STUB_LOG}"
  [ "$status" -ne 0 ]
}

@test "interactive recommended settings preseed tbachert/spi policy before core-dev install" {
  unset DCQ_INSTALL_DEPS
  unset DCQ_NONINTERACTIVE
  unset DDEV_NONINTERACTIVE

  run python3 - <<'PY'
import os
import pty
import select
import signal
import sys

addon_root = os.environ["ADDON_ROOT"]
app_root = os.environ["APP_ROOT"]
stub_bin = os.environ["STUB_BIN"]
env = os.environ.copy()
env["PATH"] = f"{stub_bin}:{env['PATH']}"
env["DDEV_APPROOT"] = app_root
env["DCQ_INSTALL_NODE_DEPS"] = "skip"
env["DCQ_INSTALL_IDE_SETTINGS"] = "skip"
env["DCQ_INSTALL_GITIGNORE"] = "skip"
env["DCQ_PHPSTAN_LEVEL"] = "0"
env.pop("DCQ_INSTALL_DEPS", None)
env.pop("DCQ_NONINTERACTIVE", None)
env.pop("DDEV_NONINTERACTIVE", None)

cmd = ["bash", os.path.join(addon_root, "dcq-install.sh")]
prompts = {
    b"Accept recommended settings for this install? [Y/n]": b"y\n",
}

seen = set()
buf = b""
idle_ticks = 0
timed_out = False

pid, fd = pty.fork()
if pid == 0:
    os.chdir(addon_root)
    os.execvpe(cmd[0], cmd, env)

try:
    while True:
        r, _, _ = select.select([fd], [], [], 2)
        if fd in r:
            data = os.read(fd, 1024)
            if not data:
                break
            idle_ticks = 0
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
            buf = (buf + data)[-16384:]
            for prompt, response in prompts.items():
                if prompt in buf and prompt not in seen:
                    os.write(fd, response)
                    seen.add(prompt)
        else:
            idle_ticks += 1
            if idle_ticks > 30:
                timed_out = True
                break
except OSError:
    pass

if timed_out:
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass

_, status = os.waitpid(pid, 0)
code = os.waitstatus_to_exitcode(status)
sys.exit(code)
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"Accept recommended settings for this install? [Y/n]"* ]]

  run_search "^composer config --no-plugins allow-plugins\\.tbachert/spi false$" "${DDEV_STUB_LOG}"
  [ "$status" -eq 0 ]
  run_search "^composer require --dev drupal/core-dev --with-all-dependencies$" "${DDEV_STUB_LOG}"
  [ "$status" -eq 0 ]
}

@test "non-interactive unset DCQ_INSTALL_DEPS auto-installs core-dev" {
  unset DCQ_INSTALL_DEPS
  export DCQ_NONINTERACTIVE=true
  unset DDEV_NONINTERACTIVE

  run env \
    "PATH=${STUB_BIN}:${PATH}" \
    "DDEV_APPROOT=${APP_ROOT}" \
    "DCQ_INSTALL_NODE_DEPS=skip" \
    "DCQ_INSTALL_IDE_SETTINGS=skip" \
    "DCQ_INSTALL_GITIGNORE=skip" \
    "DCQ_PHPSTAN_LEVEL=0" \
    bash "${ADDON_ROOT}/dcq-install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Project root tooling configs updated"* ]]

  run_search "^composer require --dev drupal/core-dev --with-all-dependencies --no-interaction$" "${DDEV_STUB_LOG}"
  [ "$status" -eq 0 ]
  run_search "^composer config --no-plugins allow-plugins\\.tbachert/spi false --no-interaction$" "${DDEV_STUB_LOG}"
  [ "$status" -ne 0 ]
}

@test "interactive unset DCQ_INSTALL_IDE_SETTINGS prompts and can skip" {
  export DCQ_INSTALL_DEPS=skip
  export DCQ_INSTALL_NODE_DEPS=skip
  export DCQ_INSTALL_GITIGNORE=skip
  export DCQ_PHPSTAN_LEVEL=0
  unset DCQ_INSTALL_IDE_SETTINGS
  unset DCQ_NONINTERACTIVE
  unset DDEV_NONINTERACTIVE

  run python3 - <<'PY'
import os
import pty
import select
import signal
import sys

addon_root = os.environ["ADDON_ROOT"]
app_root = os.environ["APP_ROOT"]
stub_bin = os.environ["STUB_BIN"]
env = os.environ.copy()
env["PATH"] = f"{stub_bin}:{env['PATH']}"
env["DDEV_APPROOT"] = app_root
env["DCQ_INSTALL_DEPS"] = "skip"
env["DCQ_INSTALL_NODE_DEPS"] = "skip"
env["DCQ_INSTALL_GITIGNORE"] = "skip"
env["DCQ_PHPSTAN_LEVEL"] = "0"
env.pop("DCQ_INSTALL_IDE_SETTINGS", None)
env.pop("DCQ_NONINTERACTIVE", None)
env.pop("DDEV_NONINTERACTIVE", None)

cmd = ["bash", os.path.join(addon_root, "dcq-install.sh")]
prompts = {
    b"Accept recommended settings for this install? [Y/n]": b"n\n",
    b"VS Code/Codium settings/extensions: choose merge, overwrite (with backup), or skip.": b"\n",
}

seen = set()
buf = b""
idle_ticks = 0
timed_out = False

pid, fd = pty.fork()
if pid == 0:
    os.chdir(addon_root)
    os.execvpe(cmd[0], cmd, env)

try:
    while True:
        r, _, _ = select.select([fd], [], [], 2)
        if fd in r:
            data = os.read(fd, 1024)
            if not data:
                break
            idle_ticks = 0
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
            buf = (buf + data)[-16384:]
            for prompt, response in prompts.items():
                if prompt in buf and prompt not in seen:
                    os.write(fd, response)
                    seen.add(prompt)
        else:
            idle_ticks += 1
            if idle_ticks > 30:
                timed_out = True
                break
except OSError:
    pass

if timed_out:
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass

_, status = os.waitpid(pid, 0)
code = os.waitstatus_to_exitcode(status)
sys.exit(code)
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"Accept recommended settings for this install? [Y/n]"* ]]
  [[ "$output" == *"VS Code/Codium settings/extensions: choose merge, overwrite (with backup), or skip."* ]]
  [[ "$output" == *"Skipping IDE settings/extensions install."* ]]
  [ ! -f "${APP_ROOT}/.vscode/settings.json" ]
}

@test "non-interactive unset DCQ_INSTALL_IDE_SETTINGS auto-installs" {
  export DCQ_INSTALL_DEPS=skip
  export DCQ_INSTALL_NODE_DEPS=skip
  export DCQ_INSTALL_GITIGNORE=skip
  export DCQ_PHPSTAN_LEVEL=0
  unset DCQ_INSTALL_IDE_SETTINGS
  export DCQ_NONINTERACTIVE=true
  unset DDEV_NONINTERACTIVE

  run env \
    "PATH=${STUB_BIN}:${PATH}" \
    "DDEV_APPROOT=${APP_ROOT}" \
    "DCQ_INSTALL_DEPS=skip" \
    "DCQ_INSTALL_NODE_DEPS=skip" \
    "DCQ_INSTALL_GITIGNORE=skip" \
    "DCQ_PHPSTAN_LEVEL=0" \
    "DCQ_NONINTERACTIVE=true" \
    bash "${ADDON_ROOT}/dcq-install.sh"
  [ "$status" -eq 0 ]
  [ -f "${APP_ROOT}/.vscode/settings.json" ]
  [ -f "${APP_ROOT}/.vscode/extensions.json" ]
}

@test "interactive unset vars respect user choices across installer phases" {
  unset DCQ_INSTALL_MODE
  unset DCQ_INSTALL_DEPS
  unset DCQ_INSTALL_NODE_DEPS
  unset DCQ_INSTALL_GITIGNORE
  unset DCQ_INSTALL_IDE_SETTINGS
  unset DCQ_PHPSTAN_LEVEL
  unset DCQ_NONINTERACTIVE
  unset DDEV_NONINTERACTIVE

  mkdir -p "${APP_ROOT}/web/core"
  cat > "${APP_ROOT}/web/core/package.json" <<'JSON'
{
  "name": "drupal/core",
  "devDependencies": {
    "eslint": "^8.0.0"
  }
}
JSON
  cat > "${APP_ROOT}/package.json" <<'JSON'
{
  "name": "dcq-root",
  "private": true
}
JSON
  cat > "${APP_ROOT}/.eslintrc.json" <<'JSON'
{"local":"keep-me"}
JSON

  run python3 - <<'PY'
import os
import pty
import select
import signal
import sys

addon_root = os.environ["ADDON_ROOT"]
app_root = os.environ["APP_ROOT"]
stub_bin = os.environ["STUB_BIN"]
env = os.environ.copy()
env["PATH"] = f"{stub_bin}:{env['PATH']}"
env["DDEV_APPROOT"] = app_root
for key in (
    "DCQ_INSTALL_MODE",
    "DCQ_INSTALL_DEPS",
    "DCQ_INSTALL_NODE_DEPS",
    "DCQ_INSTALL_GITIGNORE",
    "DCQ_INSTALL_IDE_SETTINGS",
    "DCQ_PHPSTAN_LEVEL",
    "DCQ_NONINTERACTIVE",
    "DDEV_NONINTERACTIVE",
):
    env.pop(key, None)

cmd = ["bash", os.path.join(addon_root, "dcq-install.sh")]
prompts = {
    b"Accept recommended settings for this install? [Y/n]": b"n\n",
    b"Install drupal/core-dev now to provide PHP code quality tools": b"n\n",
    b"Conflict at ": b"s\n",
    b"Set phpstan.neon level (0-10) (default: 0):": b"0\n",
    b"[i]nstall in the project root, [s]kip (default: install):": b"s\n",
    b"Add 'dcq-reports/' to .gitignore?": b"n\n",
    b"VS Code/Codium settings/extensions: choose merge, overwrite (with backup), or skip.": b"\n",
}

seen = set()
buf = b""
idle_ticks = 0
timed_out = False

pid, fd = pty.fork()
if pid == 0:
    os.chdir(addon_root)
    os.execvpe(cmd[0], cmd, env)

try:
    while True:
        r, _, _ = select.select([fd], [], [], 2)
        if fd in r:
            data = os.read(fd, 1024)
            if not data:
                break
            idle_ticks = 0
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
            buf = (buf + data)[-16384:]
            for prompt, response in prompts.items():
                if prompt in buf and prompt not in seen:
                    os.write(fd, response)
                    seen.add(prompt)
        else:
            idle_ticks += 1
            if idle_ticks > 30:
                timed_out = True
                break
except OSError:
    pass

if timed_out:
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass

_, status = os.waitpid(pid, 0)
code = os.waitstatus_to_exitcode(status)
sys.exit(code)
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"Install drupal/core-dev now to provide PHP code quality tools"* ]]
  [[ "$output" == *"Conflict at"* ]]
  [[ "$output" == *"ESLint, Prettier, and Stylelint require several packages to function properly."* ]]
  [[ "$output" == *"Add 'dcq-reports/' to .gitignore?"* ]]
  [[ "$output" == *"Skipping IDE settings/extensions install."* ]]

  run_search "^composer require --dev drupal/core-dev --with-all-dependencies$" "${DDEV_STUB_LOG}"
  [ "$status" -ne 0 ]
  [ ! -f "${APP_ROOT}/.vscode/settings.json" ]
  [ ! -f "${APP_ROOT}/.vscode/extensions.json" ]
  [ ! -f "${APP_ROOT}/.gitignore" ]
  run cat "${APP_ROOT}/.eslintrc.json"
  [[ "$output" == '{"local":"keep-me"}' ]]
}

write_node_deps_stub() {
  # ddev stub that reports missing JS deps (with semver ranges) from the
  # find_missing_node_deps PHP helper and logs every invocation verbatim.
  # DDEV_STUB_NPM_SAVE_DEV_EXIT controls the exit code of
  # `ddev npm install --save-dev ...` (default 0).
  cat > "${STUB_BIN}/ddev" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

log_file="${DDEV_STUB_LOG:?missing DDEV_STUB_LOG}"
printf '%s\n' "$*" >> "${log_file}"

if [[ "$*" == *"php -r"* ]]; then
  printf 'cspell@^9.8.0\neslint@^8.57.1\neslint-plugin-yml@^1.19.1\n'
  exit 0
fi

if [ "${1:-}" = "npm" ] && [ "${2:-}" = "install" ] && [ "${3:-}" = "--save-dev" ]; then
  if [ "${DDEV_STUB_NPM_SAVE_DEV_EXIT:-0}" -ne 0 ]; then
    echo 'npm error code EINVALIDTAGNAME (stub)' >&2
    exit "${DDEV_STUB_NPM_SAVE_DEV_EXIT}"
  fi
  exit 0
fi

exit 0
SH
  chmod +x "${STUB_BIN}/ddev"
}

write_root_package_json_without_deps() {
  cat > "${APP_ROOT}/package.json" <<'JSON'
{
  "name": "dcq-root",
  "private": true,
  "engines": {
    "node": ">= 20.0"
  }
}
JSON
}

@test "node dep install passes semver ranges to npm unescaped" {
  write_node_deps_stub
  write_root_package_json_without_deps

  run env \
    "PATH=${STUB_BIN}:${PATH}" \
    "DDEV_APPROOT=${APP_ROOT}" \
    "DCQ_NONINTERACTIVE=true" \
    "DCQ_INSTALL_DEPS=skip" \
    "DCQ_INSTALL_NODE_DEPS=root" \
    "DCQ_INSTALL_IDE_SETTINGS=skip" \
    "DCQ_INSTALL_GITIGNORE=skip" \
    "DCQ_PHPSTAN_LEVEL=0" \
    bash "${ADDON_ROOT}/dcq-install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Node toolchain installed (project root)."* ]]

  # The name@range tokens must reach npm exactly as resolved from core:
  # no backslash-escaped carets (npm rejects \^ as an invalid dist-tag).
  run_search '^npm install --save-dev --package-lock cspell@\^9\.8\.0 eslint@\^8\.57\.1 eslint-plugin-yml@\^1\.19\.1$' "${DDEV_STUB_LOG}"
  [ "$status" -eq 0 ]
  run grep -F 'cspell@\^' "${DDEV_STUB_LOG}"
  [ "$status" -ne 0 ]
}

@test "failed node dep install is reported as FAILED, not success" {
  write_node_deps_stub
  write_root_package_json_without_deps

  run env \
    "PATH=${STUB_BIN}:${PATH}" \
    "DDEV_APPROOT=${APP_ROOT}" \
    "DDEV_STUB_NPM_SAVE_DEV_EXIT=1" \
    "DCQ_NONINTERACTIVE=true" \
    "DCQ_INSTALL_DEPS=skip" \
    "DCQ_INSTALL_NODE_DEPS=root" \
    "DCQ_INSTALL_IDE_SETTINGS=skip" \
    "DCQ_INSTALL_GITIGNORE=skip" \
    "DCQ_PHPSTAN_LEVEL=0" \
    bash "${ADDON_ROOT}/dcq-install.sh"

  # The installer finishes (failure is non-fatal, matching the PHP deps
  # behavior) but must not claim the toolchain was installed.
  [ "$status" -eq 0 ]
  [[ "$output" == *"npm install --save-dev failed. You can retry manually."* ]]
  [[ "$output" == *"Node toolchain install FAILED (project root)."* ]]
  [[ "$output" == *"Node toolchain: FAILED"* ]]
  [[ "$output" == *"FIX: Node tooling failed to install."* ]]
  [[ "$output" != *"Node toolchain installed (project root)."* ]]
  [[ "$output" != *"- Node toolchain (ESLint, Prettier, Stylelint)"* ]]

  # The retry guidance must include the versioned tokens for every missing
  # package (displayed either raw or %q-escaped for copy-paste safety).
  for token in 'cspell@^9.8.0' 'eslint@^8.57.1' 'eslint-plugin-yml@^1.19.1'; do
    escaped="${token/@^/@\\^}"
    [[ "$output" == *"$token"* || "$output" == *"$escaped"* ]]
  done

  # The bare fallback install must not run after a failed dep add.
  run grep -x 'npm install' "${DDEV_STUB_LOG}"
  [ "$status" -ne 0 ]
  run grep -x 'npm install --package-lock' "${DDEV_STUB_LOG}"
  [ "$status" -ne 0 ]
}

@test "failed dep top-up on existing toolchain reports FAILED, not already present" {
  write_node_deps_stub
  write_root_package_json_without_deps

  # An existing root toolchain makes the installer skip the Node phase and
  # instead offer to top up newly-missing deps. A failed top-up must be
  # reported as FAILED, not masked by the pre-existing node_modules
  # reading as "already present".
  mkdir -p "${APP_ROOT}/node_modules/.bin"
  printf '#!/bin/sh\nexit 0\n' > "${APP_ROOT}/node_modules/.bin/eslint"
  chmod +x "${APP_ROOT}/node_modules/.bin/eslint"

  run python3 - <<'PY'
import os
import pty
import select
import signal
import sys

addon_root = os.environ["ADDON_ROOT"]
app_root = os.environ["APP_ROOT"]
stub_bin = os.environ["STUB_BIN"]
env = os.environ.copy()
env["PATH"] = f"{stub_bin}:{env['PATH']}"
env["DDEV_APPROOT"] = app_root
env["DDEV_STUB_NPM_SAVE_DEV_EXIT"] = "1"
env["DCQ_INSTALL_DEPS"] = "skip"
env["DCQ_INSTALL_IDE_SETTINGS"] = "skip"
env["DCQ_INSTALL_GITIGNORE"] = "skip"
env["DCQ_PHPSTAN_LEVEL"] = "0"
for key in ("DCQ_INSTALL_NODE_DEPS", "DCQ_NONINTERACTIVE", "DDEV_NONINTERACTIVE"):
    env.pop(key, None)

cmd = ["bash", os.path.join(addon_root, "dcq-install.sh")]
prompts = {
    b"Accept recommended settings for this install? [Y/n]": b"n\n",
    b"Add missing dependencies with 'npm install --save-dev' in the project root?": b"y\n",
}

seen = set()
buf = b""
idle_ticks = 0
timed_out = False

pid, fd = pty.fork()
if pid == 0:
    os.chdir(addon_root)
    os.execvpe(cmd[0], cmd, env)

try:
    while True:
        r, _, _ = select.select([fd], [], [], 2)
        if fd in r:
            data = os.read(fd, 1024)
            if not data:
                break
            idle_ticks = 0
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
            buf = (buf + data)[-16384:]
            for prompt, response in prompts.items():
                if prompt in buf and prompt not in seen:
                    os.write(fd, response)
                    seen.add(prompt)
        else:
            idle_ticks += 1
            if idle_ticks > 30:
                timed_out = True
                break
except OSError:
    pass

if timed_out:
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass

_, status = os.waitpid(pid, 0)
code = os.waitstatus_to_exitcode(status)
sys.exit(code)
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"Add missing dependencies with 'npm install --save-dev' in the project root?"* ]]
  [[ "$output" == *"npm install --save-dev failed. You can retry manually."* ]]
  [[ "$output" == *"Node toolchain: FAILED"* ]]
  [[ "$output" != *"Node toolchain: already present (skipped)"* ]]
}

@test "non-interactive unset vars apply recommended defaults across installer phases" {
  unset DCQ_INSTALL_MODE
  unset DCQ_INSTALL_DEPS
  unset DCQ_INSTALL_NODE_DEPS
  unset DCQ_INSTALL_GITIGNORE
  unset DCQ_INSTALL_IDE_SETTINGS
  unset DCQ_PHPSTAN_LEVEL
  export DCQ_NONINTERACTIVE=true
  unset DDEV_NONINTERACTIVE

  mkdir -p "${APP_ROOT}/web/core"
  cat > "${APP_ROOT}/web/core/package.json" <<'JSON'
{
  "name": "drupal/core",
  "devDependencies": {
    "eslint": "^8.0.0"
  }
}
JSON
  cat > "${APP_ROOT}/package.json" <<'JSON'
{
  "name": "dcq-root",
  "private": true
}
JSON
  cat > "${APP_ROOT}/.eslintrc.json" <<'JSON'
{"local":"replace-me"}
JSON

  run env \
    "PATH=${STUB_BIN}:${PATH}" \
    "DDEV_APPROOT=${APP_ROOT}" \
    "DCQ_NONINTERACTIVE=true" \
    bash "${ADDON_ROOT}/dcq-install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Using recommended default: DCQ_INSTALL_MODE=replace"* ]]
  [[ "$output" == *"Using recommended default: DCQ_INSTALL_DEPS=install"* ]]
  [[ "$output" == *"Using recommended default: DCQ_INSTALL_NODE_DEPS=root"* ]]
  [[ "$output" == *"Using recommended default: DCQ_INSTALL_IDE_SETTINGS=merge"* ]]
  [[ "$output" == *"Using recommended default: DCQ_INSTALL_GITIGNORE=add"* ]]

  run_search "^composer require --dev drupal/core-dev --with-all-dependencies --no-interaction$" "${DDEV_STUB_LOG}"
  [ "$status" -eq 0 ]
  run_search "npm install|yarn install|yarn add -D|npm install --save-dev" "${DDEV_STUB_LOG}"
  [ "$status" -eq 0 ]
  [ -f "${APP_ROOT}/.vscode/settings.json" ]
  [ -f "${APP_ROOT}/.vscode/extensions.json" ]
  [ -f "${APP_ROOT}/.gitignore" ]
  run_search "^dcq-reports/$" "${APP_ROOT}/.gitignore"
  [ "$status" -eq 0 ]
  run cat "${APP_ROOT}/.eslintrc.json"
  [[ "$output" != '{"local":"replace-me"}' ]]
}
