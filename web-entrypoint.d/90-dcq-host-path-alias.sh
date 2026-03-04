#!/usr/bin/env bash
#ddev-generated
set -eu

APPROOT_FILE="/mnt/ddev_config/.ddev-docker-compose-full.yaml"
TARGET_PATH="/var/www/html"

if [ ! -f "$APPROOT_FILE" ]; then
  return 0 2>/dev/null || exit 0
fi

APPROOT="$(awk -F': ' '/com\.ddev\.approot:/ {print $2; exit}' "$APPROOT_FILE" | tr -d '"')"
if [ -z "$APPROOT" ]; then
  return 0 2>/dev/null || exit 0
fi

ALT_APPROOT=""
case "$APPROOT" in
  /private/*)
    ALT_APPROOT="${APPROOT#/private}"
    ;;
esac

alias_disabled() {
  case "${DCQ_HOST_PATH_ALIAS:-1}" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off)
      return 0
      ;;
  esac
  return 1
}

cleanup_alias() {
  local alias_path="$1"
  local current_target=""
  if [ -z "$alias_path" ]; then
    return
  fi
  if ! sudo test -L "$alias_path"; then
    return
  fi
  current_target="$(sudo readlink "$alias_path" || true)"
  if [ "$current_target" = "$TARGET_PATH" ]; then
    sudo rm -f "$alias_path"
  fi
}

ensure_alias() {
  local alias_path="$1"
  if [ -z "$alias_path" ]; then
    return
  fi

  if sudo test -e "$alias_path" && ! sudo test -L "$alias_path"; then
    # Never replace real directories/files outside our managed symlink case.
    return
  fi

  sudo mkdir -p "$(dirname "$alias_path")"
  sudo ln -sfn "$TARGET_PATH" "$alias_path"
}

if alias_disabled; then
  cleanup_alias "$APPROOT"
  cleanup_alias "$ALT_APPROOT"
  return 0 2>/dev/null || exit 0
fi

ensure_alias "$APPROOT"
ensure_alias "$ALT_APPROOT"
