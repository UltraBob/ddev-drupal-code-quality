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

ensure_alias() {
  local alias_path="$1"
  local current_target=""
  if [ -z "$alias_path" ]; then
    return
  fi

  if sudo test -L "$alias_path"; then
    current_target="$(sudo readlink "$alias_path" || true)"
    if [ "$current_target" = "$TARGET_PATH" ]; then
      return
    fi
    sudo ln -sfn "$TARGET_PATH" "$alias_path"
    return
  fi

  if sudo test -d "$alias_path"; then
    # Existing directories (for example user-managed bind mounts) already satisfy parity.
    return
  fi

  if sudo test -e "$alias_path"; then
    echo "DCQ host-path alias conflict at ${alias_path}: existing non-directory path cannot be replaced safely." >&2
    return 1
  fi

  sudo mkdir -p "$(dirname "$alias_path")"
  sudo ln -s "$TARGET_PATH" "$alias_path"
}

ensure_alias "$APPROOT"
ensure_alias "$ALT_APPROOT"
