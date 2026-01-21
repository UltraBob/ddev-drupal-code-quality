#!/bin/bash
#ddev-generated
set -u

CONTAINER_ROOT="/var/www/html"
HOST_ROOT=""
DCQ_DOCROOT="web"

# Read the DDEV project root from compose metadata so host paths can be mapped.
if [ -f /mnt/ddev_config/.ddev-docker-compose-full.yaml ]; then
  HOST_ROOT="$(awk -F': ' '/com\.ddev\.approot:/ {print $2; exit}' /mnt/ddev_config/.ddev-docker-compose-full.yaml)"
fi

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
    echo "${CONTAINER_ROOT}${path#${HOST_ROOT}}"
    return
  fi
  # Unknown path; return as-is to avoid breaking user inputs.
  echo "$path"
}
