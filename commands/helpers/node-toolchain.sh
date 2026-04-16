#!/usr/bin/env bash
#ddev-generated
# Root-only Node toolchain resolver shared by every Node wrapper.
#
# Policy: the add-on installs Node tooling at the project root only. No other
# locations are consulted. See docs/decisions/node-deps-root-only-2026-01-22.md.
#
# Usage:
#   source /mnt/ddev_config/commands/helpers/node-toolchain.sh
#   if ! resolve_node_tool "stylelint/bin/stylelint.mjs"; then
#     echo "Stylelint is not installed..." >&2
#     exit 127
#   fi
#   # TOOLCHAIN_BIN and NODE_PATH are now set.

resolve_node_tool() {
  local subpath="$1"
  if [ -z "$subpath" ]; then
    return 1
  fi
  # Compute at call time so the wrapper's PROJECT_ROOT assignment is respected.
  local nm_root="${PROJECT_ROOT:-/var/www/html}/node_modules"
  local candidate="${nm_root}/${subpath}"
  if [ -e "$candidate" ]; then
    TOOLCHAIN_BIN="$candidate"
    NODE_PATH="$nm_root"
    return 0
  fi
  return 1
}
