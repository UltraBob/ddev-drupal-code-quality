#!/usr/bin/env bash
#ddev-generated
set -u

CONTAINER_ROOT="/var/www/html"
HOST_ROOT=""
DCQ_DOCROOT="web"

# Prefer the explicit DDEV_HOST_PROJECT_ROOT when available.
if [ -n "${DDEV_HOST_PROJECT_ROOT:-}" ]; then
  HOST_ROOT="${DDEV_HOST_PROJECT_ROOT%/}"
fi

# Fall back to compose metadata when the env var is not set.
if [ -z "$HOST_ROOT" ] && [ -f /mnt/ddev_config/.ddev-docker-compose-full.yaml ]; then
  HOST_ROOT="$(awk -F': ' '/com\.ddev\.approot:/ {print $2; exit}' /mnt/ddev_config/.ddev-docker-compose-full.yaml | tr -d '"')"
fi
HOST_ROOT="${HOST_ROOT%/}"

# Read the docroot detected during install for non-standard Drupal layouts.
if [ -f /mnt/ddev_config/.dcq-docroot ]; then
  read -r docroot_value </mnt/ddev_config/.dcq-docroot || true
  docroot_value="${docroot_value#/}"
  docroot_value="${docroot_value%/}"
  if [ -n "$docroot_value" ]; then
    DCQ_DOCROOT="$docroot_value"
  fi
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
    # Prefer direct host-path alias usage when it is available in the container.
    if [ -e "$path" ] || [ -L "$path" ]; then
      echo "$path"
      return
    fi
    echo "${CONTAINER_ROOT}${path#${HOST_ROOT}}"
    return
  fi
  # Unknown path; return as-is to avoid breaking user inputs.
  echo "$path"
}

map_to_project_relative() {
  local path="$1"
  path="$(map_path "$path")"
  if [ "${path#${CONTAINER_ROOT}/}" != "$path" ]; then
    echo "${path#${CONTAINER_ROOT}/}"
    return
  fi
  if [ -n "$HOST_ROOT" ] && [ "${path#${HOST_ROOT}/}" != "$path" ]; then
    echo "${path#${HOST_ROOT}/}"
    return
  fi
  echo "$path"
}
