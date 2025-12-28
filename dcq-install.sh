#!/usr/bin/env bash

set -euo pipefail

string_lower() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

truthy() {
  local value
  value="$(string_lower "${1:-}")"
  case "$value" in
    1|true|yes|on) return 0 ;;
  esac
  return 1
}

prompt_setup() {
  PROMPT_AVAILABLE=0
  PROMPT_IN_FD=
  PROMPT_OUT_FD=

  if [ -t 0 ] && [ -t 1 ]; then
    PROMPT_IN_FD=0
    PROMPT_OUT_FD=1
    PROMPT_AVAILABLE=1
    return
  fi

  if [ -e /dev/tty ]; then
    exec 3</dev/tty 4>/dev/tty
    PROMPT_IN_FD=3
    PROMPT_OUT_FD=4
    PROMPT_AVAILABLE=1
  fi
}

prompt_choice() {
  local path="$1"
  local warn_parity="$2"

  if [ "${PROMPT_AVAILABLE:-0}" -ne 1 ]; then
    printf 'No interactive terminal detected; skipping conflict prompt for %s.\n' "$path" >&2
    printf 's'
    return
  fi

  if [ "$warn_parity" = "true" ]; then
    printf 'Skipping this file may reduce CI parity for your local tooling.\n' >&"$PROMPT_OUT_FD"
  fi
  printf 'Conflict at %s. Choose: [r]eplace (backup), [s]kip, [a]bort, [ra] replace all, [sa] skip all: ' "$path" >&"$PROMPT_OUT_FD"
  local answer=""
  if ! IFS= read -r -u "$PROMPT_IN_FD" answer; then
    answer=""
  fi
  answer="$(printf '%s' "$answer" | tr -d '\r\n')"
  if [ -z "$answer" ]; then
    printf 's'
    return
  fi
  printf '%s' "$answer"
}

create_root_package_json() {
  local ddev_cmd="$1"
  local app_root="$2"
  local output
  local status
  local php_script="${cwd}/.dcq-create-package.php"
  local script_path="/var/www/html/.ddev/.dcq-create-package.php"
  local attempts=0
  local max_attempts=5

  cat > "$php_script" <<'PHP'
<?php
$path = "/var/www/html/web/core/package.json";
$data = json_decode(file_get_contents($path), true);
if (!is_array($data)) {
  fwrite(STDERR, "Failed to read core package.json\n");
  exit(1);
}
$projectName = null;
$configPath = "/var/www/html/.ddev/config.yaml";
if (is_readable($configPath)) {
  $lines = file($configPath, FILE_IGNORE_NEW_LINES);
  if ($lines !== false) {
    foreach ($lines as $line) {
      if (preg_match('/^\s*name:\s*(.+?)\s*$/', $line, $matches)) {
        $projectName = trim($matches[1], " \t\"'");
        break;
      }
    }
  }
}
$out = [
  "name" => $projectName ?: ($data["name"] ?? "drupal-project"),
  "private" => true,
];
if (isset($data["description"])) {
  $out["description"] = $data["description"];
}
if (isset($data["license"])) {
  $out["license"] = $data["license"];
}
if (isset($data["engines"])) {
  $out["engines"] = $data["engines"];
}
if (isset($data["packageManager"])) {
  $out["packageManager"] = $data["packageManager"];
}
if (isset($data["dependencies"])) {
  $out["dependencies"] = $data["dependencies"];
}
if (isset($data["devDependencies"])) {
  $out["devDependencies"] = $data["devDependencies"];
}
echo json_encode($out, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL;
PHP

  while [ "$attempts" -lt "$max_attempts" ]; do
    if "$ddev_cmd" exec test -f "$script_path" >/dev/null 2>&1; then
      break
    fi
    attempts=$((attempts + 1))
    sleep 0.2
  done

  output="$("$ddev_cmd" exec php "$script_path" 2>&1)"
  status=$?
  rm -f "$php_script"

  if [ "$status" -ne 0 ] || [ -z "$output" ]; then
    printf 'Unable to create project package.json from core.\n' >&2
    if [ -n "$output" ]; then
      printf '%s\n' "$output" >&2
    fi
    return 1
  fi

  if ! printf '%s' "$output" | grep -q '^{'; then
    printf 'Unable to create project package.json from core (invalid output).\n' >&2
    printf '%s\n' "$output" >&2
    return 1
  fi

  printf '%s\n' "$output" > "${app_root%/}/package.json"
  printf 'WRITE: %s\n' "${app_root%/}/package.json"

  if [ -f "${app_root%/}/web/core/.yarnrc.yml" ] && [ ! -f "${app_root%/}/.yarnrc.yml" ]; then
    cp "${app_root%/}/web/core/.yarnrc.yml" "${app_root%/}/.yarnrc.yml"
    printf 'WRITE: %s\n' "${app_root%/}/.yarnrc.yml"
  fi

  printf 'Created package.json from Drupal core devDependencies; review and customize as needed.\n'
  return 0
}

prompt_node_target() {
  local has_root="$1"
  local choice

  if [ "${PROMPT_AVAILABLE:-0}" -ne 1 ]; then
    printf 'skip'
    return
  fi

  if [ "$has_root" -eq 1 ]; then
    printf 'Choose JS toolchain target: [r]oot (project package.json), [c]ore (web/core), [s]kip (default: root): ' >&"$PROMPT_OUT_FD"
    if ! IFS= read -r -u "$PROMPT_IN_FD" choice; then
      choice=""
    fi
    choice="$(string_lower "$choice")"
    if [ -z "$choice" ]; then
      printf 'root'
      return
    fi
  else
    printf 'No project package.json found. Choose JS toolchain target: [r]oot (create from core), [c]ore (web/core), [s]kip (default: root): ' >&"$PROMPT_OUT_FD"
    if ! IFS= read -r -u "$PROMPT_IN_FD" choice; then
      choice=""
    fi
    choice="$(string_lower "$choice")"
    if [ -z "$choice" ]; then
      printf 'root'
      return
    fi
  fi

  case "$choice" in
    r|root) printf 'root' ;;
    c|core) printf 'core' ;;
    s|skip) printf 'skip' ;;
    *) printf 'skip' ;;
  esac
}

prompt_yes_no() {
  local question="$1"
  local default_no="$2"
  local suffix

  if [ "${PROMPT_AVAILABLE:-0}" -ne 1 ]; then
    printf 'No interactive terminal detected; skipping prompt. Use DCQ_INSTALL_DEPS=install or DCQ_INSTALL_NODE_DEPS=install to auto-approve.\n' >&2
    if [ "$default_no" -eq 1 ]; then
      return 1
    fi
    return 0
  fi

  if [ "$default_no" -eq 1 ]; then
    suffix='[y/N]'
  else
    suffix='[Y/n]'
  fi
  printf '%s %s ' "$question" "$suffix" >&"$PROMPT_OUT_FD"
  local answer=""
  if ! IFS= read -r -u "$PROMPT_IN_FD" answer; then
    answer=""
  fi
  answer="$(string_lower "$answer")"
  if [ -z "$answer" ]; then
    if [ "$default_no" -eq 1 ]; then
      return 1
    fi
    return 0
  fi
  case "$answer" in
    y|yes) return 0 ;;
  esac
  return 1
}

strip_generated_header() {
  local source="$1"
  local dest="$2"
  if [ "$(head -n 1 "$source")" = "#ddev-generated" ]; then
    tail -n +2 "$source" >"$dest"
  else
    cat "$source" >"$dest"
  fi
}

ensure_dir() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
  fi
}

show_diff() {
  local target="$1"
  local source="$2"
  if ! command -v diff >/dev/null 2>&1; then
    printf 'Diff not available on this system.\n'
    return
  fi
  diff -u "$target" "$source" || true
}

backup_file() {
  local path="$1"
  local backup="${path}.bak"
  local index=1
  while [ -e "$backup" ]; do
    backup="${path}.bak.${index}"
    index=$((index + 1))
  done
  cp "$path" "$backup"
  printf '%s' "$backup"
}

command_available() {
  command -v "$1" >/dev/null 2>&1
}

node_toolchain_present() {
  local app_root="$1"
  local paths=(
    "$app_root/web/core/node_modules/.bin/eslint"
    "$app_root/web/core/node_modules/eslint/bin/eslint.js"
    "$app_root/node_modules/.bin/eslint"
    "$app_root/node_modules/eslint/bin/eslint.js"
  )
  local path
  for path in "${paths[@]}"; do
    if [ -e "$path" ]; then
      return 0
    fi
  done
  return 1
}

run_command() {
  local arg
  printf 'Running:'
  for arg in "$@"; do
    printf ' %q' "$arg"
  done
  printf '\n'
  "$@"
}

prompt_setup

cwd="$(pwd)"
app_root="${DDEV_APPROOT:-}"
if [ -z "$app_root" ]; then
  app_root="$(cd "$cwd/.." && pwd)"
fi

assets_root="${cwd}/dcq-assets"
if [ ! -d "$assets_root" ]; then
  printf 'dcq-assets directory not found at %s.\n' "$assets_root" >&2
  exit 1
fi

shim_dir_env="${DCQ_SHIM_DIR:-dcq-tooling/bin}"
if [[ "$shim_dir_env" = /* ]]; then
  shim_dir="$shim_dir_env"
else
  shim_dir="${app_root%/}/${shim_dir_env}"
fi

app_root_check="${app_root%/}"
shim_dir_check="${shim_dir%/}"
case "$shim_dir_check" in
  "$app_root_check"|"$app_root_check"/*) ;;
  *)
    printf 'DCQ_SHIM_DIR must be inside the project root (%s).\n' "$app_root" >&2
    exit 1
    ;;
esac

non_interactive=0
if truthy "${DDEV_NONINTERACTIVE:-}"; then
  non_interactive=1
fi
if truthy "${DCQ_NONINTERACTIVE:-}"; then
  non_interactive=1
fi

install_mode="$(string_lower "${DCQ_INSTALL_MODE:-}")"
if [ "$non_interactive" -eq 1 ] && [ -z "$install_mode" ]; then
  install_mode="replace"
fi

replace_all=0
skip_all=0
abort_on_conflict=0
case "$install_mode" in
  replace) replace_all=1 ;;
  skip) skip_all=1 ;;
  abort) abort_on_conflict=1 ;;
esac

printf 'Installing Drupal CI parity assets...\n'

while IFS= read -r -d '' source; do
  rel="${source#$assets_root/}"
  if [[ "$rel" == tooling/bin/* ]]; then
    target="${shim_dir%/}/${rel#tooling/bin/}"
  else
    target="${app_root%/}/${rel}"
  fi

  tmp="$(mktemp "${TMPDIR:-/tmp}/dcq-src-XXXXXX")"
  strip_generated_header "$source" "$tmp"

  if [ -e "$target" ]; then
    if cmp -s "$target" "$tmp"; then
      printf 'OK: %s already matches.\n' "$target"
      rm -f "$tmp"
      continue
    fi

    if [ "$skip_all" -eq 1 ]; then
      printf 'SKIP: %s (existing file).\n' "$target"
      rm -f "$tmp"
      continue
    fi

    if [ "$replace_all" -eq 1 ]; then
      backup="$(backup_file "$target")"
      printf 'BACKUP: %s\n' "$backup"
    elif [ "$abort_on_conflict" -eq 1 ]; then
      printf 'ABORT: conflict at %s.\n' "$target" >&2
      rm -f "$tmp"
      exit 1
    else
      show_diff "$target" "$tmp"
      choice="$(prompt_choice "$target" "true")"
      choice="$(string_lower "$choice")"
      choice="$(printf '%s' "$choice" | tr -s ' ')"
      case "$choice" in
        r|replace)
          backup="$(backup_file "$target")"
          printf 'BACKUP: %s\n' "$backup"
          ;;
        s|skip)
          printf 'SKIP: %s (existing file).\n' "$target"
          rm -f "$tmp"
          continue
          ;;
        a|abort)
          printf 'ABORT: conflict at %s.\n' "$target" >&2
          rm -f "$tmp"
          exit 1
          ;;
        ra|rall|"replace all")
          replace_all=1
          backup="$(backup_file "$target")"
          printf 'BACKUP: %s\n' "$backup"
          ;;
        sa|sall|"skip all")
          skip_all=1
          printf 'SKIP: %s (existing file).\n' "$target"
          rm -f "$tmp"
          continue
          ;;
        *)
          printf 'Unknown choice. Skipping %s.\n' "$target"
          rm -f "$tmp"
          continue
          ;;
      esac
    fi
  fi

  ensure_dir "$(dirname "$target")"
  cat "$tmp" >"$target"
  rm -f "$tmp"

  if [ -x "$source" ] || [[ "$target" == "$shim_dir"* ]]; then
    chmod 0755 "$target" || true
  fi
  printf 'WRITE: %s\n' "$target"
done < <(find "$assets_root" -type f -print0)

printf 'Done.\n'

vendor_bin="${app_root%/}/vendor/bin"
missing_tools=()
for tool in phpstan phpcs phpcbf; do
  if [ ! -e "${vendor_bin}/${tool}" ]; then
    missing_tools+=("$tool")
  fi
done

if [ "${#missing_tools[@]}" -gt 0 ]; then
  composer_json="${app_root%/}/composer.json"
  has_core_dev=0
  if [ -f "$composer_json" ] && grep -q '"drupal/core-dev"' "$composer_json"; then
    has_core_dev=1
  fi

  ddev_cmd="${DDEV_EXECUTABLE:-ddev}"
  deps_mode_raw="$(string_lower "${DCQ_INSTALL_DEPS:-}")"
  if [ -z "$deps_mode_raw" ]; then
    if [ "$non_interactive" -eq 1 ]; then
      deps_mode="skip"
    else
      deps_mode="prompt"
    fi
  elif [ "$deps_mode_raw" = "1" ] || [ "$deps_mode_raw" = "true" ] || [ "$deps_mode_raw" = "yes" ] || [ "$deps_mode_raw" = "on" ] || [ "$deps_mode_raw" = "install" ] || [ "$deps_mode_raw" = "auto" ]; then
    deps_mode="install"
  elif [ "$deps_mode_raw" = "0" ] || [ "$deps_mode_raw" = "false" ] || [ "$deps_mode_raw" = "no" ] || [ "$deps_mode_raw" = "off" ] || [ "$deps_mode_raw" = "skip" ]; then
    deps_mode="skip"
  else
    deps_mode="prompt"
  fi

  printf 'Missing dev tools: %s.\n' "$(printf '%s ' "${missing_tools[@]}" | sed 's/[[:space:]]*$//')"
  if [ ! -f "$composer_json" ]; then
    printf 'composer.json not found; skipping dependency install.\n'
    missing_tools=()
  fi

  if [ "${#missing_tools[@]}" -gt 0 ] && ! command_available "$ddev_cmd"; then
    printf 'ddev executable not found in PATH; skipping dependency install.\n'
    missing_tools=()
  fi

  if [ "${#missing_tools[@]}" -gt 0 ]; then
    if [ "$has_core_dev" -eq 1 ]; then
      action="install"
      cmd=( "$ddev_cmd" "composer" "install" )
    else
      action="require"
      cmd=( "$ddev_cmd" "composer" "require" "--dev" "drupal/core-dev" "--with-all-dependencies" )
    fi
    if [ "$non_interactive" -eq 1 ]; then
      cmd+=( "--no-interaction" )
    fi

    if [ "$action" = "install" ]; then
      question="Run '${cmd[*]}' to install dev tools?"
    else
      question="Run '${cmd[*]}' to add Drupal core-dev tools?"
    fi

    should_install=0
    if [ "$deps_mode" = "install" ]; then
      should_install=1
    elif [ "$deps_mode" = "prompt" ]; then
      if prompt_yes_no "$question" 1; then
        should_install=1
      fi
    fi

    if [ "$should_install" -ne 1 ]; then
      printf "Skipping dependency install. Run '%s' later to enable PHPStan/PHPCS/PHPCBF.\n" "${cmd[*]}"
    else
      (cd "$app_root" && run_command "${cmd[@]}")
      printf 'Dependencies installed.\n'
    fi
  fi
fi

core_package_json="${app_root%/}/web/core/package.json"
if [ -f "$core_package_json" ]; then
  node_mode_raw="$(string_lower "${DCQ_INSTALL_NODE_DEPS:-}")"
  if [ -z "$node_mode_raw" ] && node_toolchain_present "$app_root"; then
    node_mode_raw="skip"
  fi

  if [ "$node_mode_raw" != "skip" ]; then
    ddev_cmd="${DDEV_EXECUTABLE:-ddev}"
    root_package_json="${app_root%/}/package.json"
    has_root_package_json=0
    if [ -f "$root_package_json" ]; then
      has_root_package_json=1
    fi
    if [ -z "$node_mode_raw" ]; then
      if [ "$non_interactive" -eq 1 ]; then
        node_mode="skip"
      else
        node_mode="prompt"
      fi
    elif [ "$node_mode_raw" = "1" ] || [ "$node_mode_raw" = "true" ] || [ "$node_mode_raw" = "yes" ] || [ "$node_mode_raw" = "on" ] || [ "$node_mode_raw" = "install" ] || [ "$node_mode_raw" = "auto" ]; then
      node_mode="install"
    elif [ "$node_mode_raw" = "0" ] || [ "$node_mode_raw" = "false" ] || [ "$node_mode_raw" = "no" ] || [ "$node_mode_raw" = "off" ] || [ "$node_mode_raw" = "skip" ]; then
      node_mode="skip"
    elif [ "$node_mode_raw" = "root" ] || [ "$node_mode_raw" = "project" ]; then
      node_mode="root"
    elif [ "$node_mode_raw" = "core" ]; then
      node_mode="core"
    else
      node_mode="prompt"
    fi

    if [ "$node_mode" != "skip" ]; then
      printf 'Preparing JS toolchain install.\n'
      if ! command_available "$ddev_cmd"; then
        printf 'ddev executable not found in PATH; skipping Node toolchain install.\n'
        node_mode="skip"
      fi

      target="skip"
      if [ "$node_mode" = "install" ]; then
        target="root"
      elif [ "$node_mode" = "root" ] || [ "$node_mode" = "core" ]; then
        target="$node_mode"
      elif [ "$node_mode" = "prompt" ]; then
        target="$(prompt_node_target "$has_root_package_json")"
      fi

      if [ "$target" = "root" ] && [ "$has_root_package_json" -eq 0 ]; then
        if ! create_root_package_json "$ddev_cmd" "$app_root"; then
          target="skip"
        else
          has_root_package_json=1
        fi
      fi

      if [ "$target" = "core" ]; then
        cmd=( "$ddev_cmd" "exec" "bash" "-lc" "cd web/core && yarn install" )
        run_command "${cmd[@]}"
        printf 'Node toolchain installed (core).\n'
      elif [ "$target" = "root" ]; then
        cmd=( "$ddev_cmd" "exec" "bash" "-lc" "cd /var/www/html && yarn install" )
        run_command "${cmd[@]}"
        printf 'Node toolchain installed (project root).\n'
      else
        printf 'Skipping Node toolchain install. Use DCQ_INSTALL_NODE_DEPS=root or DCQ_INSTALL_NODE_DEPS=core to enable later.\n'
      fi
    fi
  fi
fi
