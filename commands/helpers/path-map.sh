#!/usr/bin/env bash
#ddev-generated
set -u

CONTAINER_ROOT="/var/www/html"
HOST_ROOT=""
DCQ_DOCROOT="web"
DCQ_COMPOSER_ROOT="."
COMPOSER_ROOT="$CONTAINER_ROOT"
COMPOSER_DOCROOT="web"

# Prefer the explicit DDEV_HOST_PROJECT_ROOT when available.
if [ -n "${DDEV_HOST_PROJECT_ROOT:-}" ]; then
  HOST_ROOT="${DDEV_HOST_PROJECT_ROOT%/}"
fi

# Prefer DDEV_COMPOSER_ROOT when DDEV provides it; otherwise read the value
# resolved by the installer because current DDEV releases do not document it.
if [ -n "${DDEV_COMPOSER_ROOT:-}" ]; then
  composer_root_value="$DDEV_COMPOSER_ROOT"
elif [ -f /mnt/ddev_config/.dcq-composer-root ]; then
  read -r composer_root_value </mnt/ddev_config/.dcq-composer-root || true
else
  composer_root_value="."
fi
if [ "$composer_root_value" = "$CONTAINER_ROOT" ]; then
  composer_root_value="."
elif [[ "$composer_root_value" == "${CONTAINER_ROOT}/"* ]]; then
  composer_root_value="${composer_root_value#${CONTAINER_ROOT}/}"
fi
composer_root_value="${composer_root_value#/}"
composer_root_value="${composer_root_value%/}"
if [ -n "$composer_root_value" ] && [ "$composer_root_value" != "." ]; then
  DCQ_COMPOSER_ROOT="$composer_root_value"
  COMPOSER_ROOT="${CONTAINER_ROOT}/${DCQ_COMPOSER_ROOT}"
fi

# Fall back to compose metadata when the env var is not set.
if [ -z "$HOST_ROOT" ] && [ -f /mnt/ddev_config/.ddev-docker-compose-full.yaml ]; then
  HOST_ROOT="$(awk -F': ' '/com\.ddev\.approot:/ {print $2; exit}' /mnt/ddev_config/.ddev-docker-compose-full.yaml)"
fi

# Prefer DDEV_DOCROOT so config overrides are reflected without reinstalling.
if [ -n "${DDEV_DOCROOT:-}" ]; then
  docroot_value="$DDEV_DOCROOT"
elif [ -f /mnt/ddev_config/.dcq-docroot ]; then
  read -r docroot_value </mnt/ddev_config/.dcq-docroot || true
else
  docroot_value="web"
fi
docroot_value="${docroot_value#/}"
docroot_value="${docroot_value%/}"
if [ -n "$docroot_value" ]; then
  DCQ_DOCROOT="$docroot_value"
fi

if [ "$DCQ_COMPOSER_ROOT" = "." ]; then
  COMPOSER_DOCROOT="$DCQ_DOCROOT"
else
  COMPOSER_DOCROOT="${DCQ_DOCROOT#${DCQ_COMPOSER_ROOT}/}"
fi
if [ "$COMPOSER_DOCROOT" = "$DCQ_DOCROOT" ]; then
  # DDEV's documented DDEV_DOCROOT is relative to the DDEV app root. When
  # commands run from a nested Composer root, make it relative to that root.
  COMPOSER_DOCROOT="${DCQ_DOCROOT#*/}"
fi

map_path() {
  local path="$1"
  if [ -z "$path" ]; then
    echo "$path"
    return
  fi
  # If the path is already a container path, keep it unchanged.
  if [ "${path#${CONTAINER_ROOT}/}" != "$path" ]; then
    echo "$path"
    return
  fi
  # If the path is a host path under the project root, map it into the container.
  if [ -n "$HOST_ROOT" ] && [ "${path#${HOST_ROOT}/}" != "$path" ]; then
    echo "${CONTAINER_ROOT}${path#${HOST_ROOT}}"
    return
  fi
  # Unknown path; return as-is to avoid breaking user inputs.
  echo "$path"
}

map_composer_path() {
  local path
  path="$(map_path "$1")"
  if [ "$DCQ_COMPOSER_ROOT" != "." ] && [[ "$path" == "${DCQ_COMPOSER_ROOT}/"* ]]; then
    printf '%s\n' "${path#${DCQ_COMPOSER_ROOT}/}"
    return
  fi
  printf '%s\n' "$path"
}
