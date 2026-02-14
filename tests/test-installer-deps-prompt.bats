#!/usr/bin/env bats

setup() {
  set -euo pipefail

  export ADDON_ROOT="/Users/bob/ddev_projects/ddev_cq/addons/ddev-drupal-code-quality"
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

@test "interactive unset DCQ_INSTALL_DEPS prompts before installing core-dev" {
  unset DCQ_INSTALL_DEPS
  unset DCQ_NONINTERACTIVE
  unset DDEV_NONINTERACTIVE

  run python3 - <<'PY'
import os
import pty
import select
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
    b"Accept recommended settings? (y/N)": b"n\n",
    b"Recommend installing drupal/core-dev as a dev dependency": b"n\n",
}

seen = set()
buf = b""

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
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
            buf = (buf + data)[-16384:]
            for prompt, response in prompts.items():
                if prompt in buf and prompt not in seen:
                    os.write(fd, response)
                    seen.add(prompt)
except OSError:
    pass

_, status = os.waitpid(pid, 0)
code = os.waitstatus_to_exitcode(status)
sys.exit(code)
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"Accept recommended settings? (y/N)"* ]]
  [[ "$output" == *"Recommend installing drupal/core-dev as a dev dependency"* ]]
  [[ "$output" == *"Project root tooling configs updated"* ]]

  run rg -n "^composer require --dev drupal/core-dev --with-all-dependencies$" "${DDEV_STUB_LOG}"
  [ "$status" -ne 0 ]
}

@test "non-interactive unset DCQ_INSTALL_DEPS auto-installs core-dev" {
  unset DCQ_INSTALL_DEPS
  export DCQ_NONINTERACTIVE=true
  unset DDEV_NONINTERACTIVE

  run bash -lc 'PATH="${STUB_BIN}:${PATH}" DDEV_APPROOT="${APP_ROOT}" DCQ_INSTALL_NODE_DEPS=skip DCQ_INSTALL_IDE_SETTINGS=skip DCQ_INSTALL_GITIGNORE=skip DCQ_PHPSTAN_LEVEL=0 bash "${ADDON_ROOT}/dcq-install.sh"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Project root tooling configs updated"* ]]

  run rg -n "^composer require --dev drupal/core-dev --with-all-dependencies --no-interaction$" "${DDEV_STUB_LOG}"
  [ "$status" -eq 0 ]
}
