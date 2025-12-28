#!/bin/bash
#ddev-generated
set -u

CONTAINER_ROOT="/var/www/html"
HOST_ROOT=""

if [ -f /mnt/ddev_config/.ddev-docker-compose-full.yaml ]; then
  HOST_ROOT="$(awk -F': ' '/com\.ddev\.approot:/ {print $2; exit}' /mnt/ddev_config/.ddev-docker-compose-full.yaml)"
fi

map_path() {
  local path="$1"
  if [ -z "$path" ]; then
    echo "$path"
    return
  fi
  if [ "${path#${CONTAINER_ROOT}/}" != "$path" ]; then
    echo "$path"
    return
  fi
  if [ -n "$HOST_ROOT" ] && [ "${path#${HOST_ROOT}/}" != "$path" ]; then
    echo "${CONTAINER_ROOT}${path#${HOST_ROOT}}"
    return
  fi
  echo "$path"
}
