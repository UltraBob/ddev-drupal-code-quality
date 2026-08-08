#!/usr/bin/env bash

# Installer for DDEV Drupal Code Quality add-on assets and tooling hints.
# Phases:
# 1) Copy Drupal.org GitLab CI template default configs and shims into the project (with conflict handling).
# 2) Offer to install PHP tooling via ddev composer (core-dev).
# 3) Offer to install JS tooling (project root) using the detected package manager.
# 4) Offer to install VS Code/Codium settings/extensions (merge/overwrite/skip).
#
# Key env vars (see README for full list):
# - DCQ_INSTALL_MODE: replace|skip|abort (conflict strategy for files)
# - DCQ_NONINTERACTIVE / DDEV_NONINTERACTIVE: disable prompts
# - DCQ_INSTALL_DEPS: install|skip (PHP dev tools)
# - DCQ_INSTALL_NODE_DEPS: root|install|skip (JS tooling)
# - DCQ_INSTALL_GITIGNORE: add|skip (dcq-reports entry)
# - DCQ_INSTALL_IDE_SETTINGS: merge|overwrite|skip (IDE settings)
# - DCQ_VERBOSE: 1|true (enable debug WRITE output, default: disabled)

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

detect_nodejs_version() {
  # Read the nodejs_version value from .ddev/config.yaml.
  # Returns the version string (e.g. "16", "20") or empty if not set.
  local config_path="$1"
  local value=""

  if [ -f "$config_path" ]; then
    value="$(awk -F: '/^[[:space:]]*nodejs_version:/ {
      val=$2
      sub(/^[[:space:]]+/, "", val)
      sub(/[[:space:]]+$/, "", val)
      gsub(/^"|"$/, "", val)
      gsub(/^'\''|'\''$/, "", val)
      print val
      exit
    }' "$config_path")"
  fi

  printf '%s' "$value"
}

check_nodejs_version() {
  # Check if the DDEV container's Node.js version meets the minimum requirement.
  # Sets NODEJS_VERSION_TOO_OLD=1 and NODEJS_DETECTED_VERSION if too old.
  # Returns 0 if OK or not set (DDEV defaults to 20), 1 if too old.
  local config_path="$1"
  local node_ver
  NODEJS_VERSION_TOO_OLD=0
  NODEJS_DETECTED_VERSION=""
  node_ver="$(detect_nodejs_version "$config_path")"

  if [ -z "$node_ver" ]; then
    return 0
  fi

  # Extract major version (handle values like "16", "16.x", "16.20.2").
  local major="${node_ver%%[.x-]*}"
  if [ -z "$major" ] || ! [[ "$major" =~ ^[0-9]+$ ]]; then
    return 0
  fi

  if [ "$major" -lt 18 ]; then
    NODEJS_VERSION_TOO_OLD=1
    NODEJS_DETECTED_VERSION="$node_ver"
    return 1
  fi

  return 0
}

prompt_nodejs_version_action() {
  # Prompt the user to abort, skip node tooling, or remove the add-on when
  # the DDEV Node.js version is too old.
  # Sets NODE_VERSION_ACTION to: abort, skip, or remove.
  local node_ver="$1"
  local non_interactive="$2"
  NODE_VERSION_ACTION="skip"

  emit '\n'
  emit 'Node.js 18 or higher is required for the JS-based code quality tooling\n'
  emit '(Stylelint, ESLint, Prettier). Your DDEV config sets nodejs_version: "%s".\n' "$node_ver"
  emit '\n'
  emit 'We recommend you fix this before continuing. You can:\n'
  emit '\n'
  emit '  [a]bort  — Exit the installer. Fix with:\n'
  emit '             ddev config --nodejs-version 20 && ddev restart\n'
  emit '             then re-run: ddev add-on get UltraBob/ddev-drupal-code-quality\n'
  emit '             To fully remove the add-on instead:\n'
  emit '             ddev add-on remove drupal-code-quality\n'
  emit '\n'
  emit '  [s]kip   — Continue without JS tooling (PHP tools still work)\n'
  emit '\n'

  if [ "$non_interactive" -eq 1 ]; then
    emit 'Non-interactive mode: skipping JS toolchain install (Node.js too old).\n'
    NODE_VERSION_ACTION="skip"
    return
  fi

  if [ "${PROMPT_AVAILABLE:-0}" -ne 1 ]; then
    emit 'No interactive terminal; skipping JS toolchain install.\n'
    NODE_VERSION_ACTION="skip"
    return
  fi

  printf '[a]bort or [s]kip? (default: skip) ' >&"$PROMPT_OUT_FD"
  local answer=""
  if ! IFS= read -r -u "$PROMPT_IN_FD" answer; then
    answer=""
  fi
  answer="$(string_lower "$answer")"
  answer="${answer//$'\r'/}"
  answer="${answer//$'\n'/}"
  answer="$(printf '%s' "$answer" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

  case "${answer:0:1}" in
    a) NODE_VERSION_ACTION="abort" ;;
    *) NODE_VERSION_ACTION="skip" ;;
  esac
}

maybe_add_engines_node() {
  # Offer to add engines.node to an existing package.json that lacks it.
  # Skipped in non-interactive mode unless the field is missing and we just
  # created the file (create_root_package_json already handles new files).
  local app_root="$1"
  local non_interactive="$2"
  local pkg="${app_root%/}/package.json"

  if [ ! -f "$pkg" ]; then
    return 0
  fi

  # Check if engines.node is already present.
  if grep -q '"engines"' "$pkg" 2>/dev/null; then
    return 0
  fi

  if [ "$non_interactive" -eq 1 ]; then
    emit 'Note: package.json has no "engines" field. Consider adding "engines": {"node": ">=20.0"} for compatibility.\n'
    return 0
  fi

  if ! prompt_yes_no 'Your package.json has no "engines" field. Add "engines": {"node": ">=20.0"} for Node.js compatibility?' 0; then
    return 0
  fi

  # Use PHP inside the container (same base64 pattern as create_root_package_json).
  local ddev_cmd="${DDEV_EXECUTABLE:-ddev}"
  local php_add_engines
  php_add_engines=$(cat <<'PHPCODE'
$path = "/var/www/html/package.json";
$data = json_decode(file_get_contents($path), true);
if (!is_array($data) || isset($data["engines"])) { exit(1); }
$data["engines"] = ["node" => ">=20.0"];
file_put_contents($path, json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
PHPCODE
  )
  local php_payload
  php_payload="$(printf '%s' "$php_add_engines" | base64 | tr -d '\n')"
  if command_available "$ddev_cmd" && \
     "$ddev_cmd" exec bash -lc "php -r 'eval(base64_decode(\"${php_payload}\"));'" >/dev/null 2>&1; then
    # Sync the container file back to the host.
    "$ddev_cmd" exec cat /var/www/html/package.json > "$pkg" 2>/dev/null || true
    emit 'Added "engines": {"node": ">=20.0"} to package.json.\n'
  else
    emit 'Could not update package.json automatically. Add manually:\n'
    emit '  "engines": {"node": ">=20.0"}\n'
  fi
}

prompt_setup() {
  # Detect a usable TTY for prompts. Falls back to /dev/tty when stdin/stdout
  # are redirected (e.g., running from automation).
  PROMPT_AVAILABLE=0
  PROMPT_IN_FD=
  PROMPT_OUT_FD=

  # Prefer /dev/tty so prompts remain interactive even inside loops that
  # temporarily redirect stdin.
  if [ -e /dev/tty ]; then
    if exec 3</dev/tty 2>/dev/null && exec 4>/dev/tty 2>/dev/null; then
      PROMPT_IN_FD=3
      PROMPT_OUT_FD=4
      PROMPT_AVAILABLE=1
      return
    fi
  fi

  if [ -t 0 ] && [ -t 1 ]; then
    PROMPT_IN_FD=0
    PROMPT_OUT_FD=1
    PROMPT_AVAILABLE=1
    return
  fi
}

emit() {
  # Print to the prompt TTY when available so context appears before prompts.
  if [ "${non_interactive:-0}" -eq 1 ]; then
    printf "$@"
  elif [ "${PROMPT_AVAILABLE:-0}" -eq 1 ]; then
    printf "$@" >&"$PROMPT_OUT_FD"
  else
    printf "$@"
  fi
}

emit_copy() {
  # Only emit WRITE debug lines when DCQ_VERBOSE is enabled
  if truthy "${DCQ_VERBOSE:-0}"; then
    emit "$@"
  fi
}

prompt_choice() {
  # Conflict prompt for file installs; sets PROMPT_CHOICE_RESULT for callers.
  local path="$1"
  local warn_parity="$2"
  local answer=""

  PROMPT_CHOICE_RESULT="s"

  if [ "${PROMPT_AVAILABLE:-0}" -ne 1 ]; then
    printf 'No interactive terminal detected; skipping conflict prompt for %s (default: skip). Set DCQ_INSTALL_MODE=replace|skip|abort to control behavior.\n' "$path" >&2
    return
  fi

  if [ "$warn_parity" = "true" ]; then
    printf 'Skipping this file may diverge from Drupal.org GitLab CI template defaults.\n' >&"$PROMPT_OUT_FD"
  fi
  printf '\n' >&"$PROMPT_OUT_FD"
  printf 'Conflict at %s. Choose: [r]eplace (backup), [s]kip, [a]bort, [ra] replace all, [sa] skip all (default: skip): ' "$path" >&"$PROMPT_OUT_FD"
  if ! IFS= read -r -u "$PROMPT_IN_FD" answer; then
    answer=""
  fi
  answer="$(printf '%s' "$answer" | tr -d '\r\n')"
  if [ -z "$answer" ]; then
    return
  fi
  PROMPT_CHOICE_RESULT="$answer"
}

create_root_package_json() {
  # Create a minimal project-root package.json with only the packages DCQ needs.
  # Reads curated package names from dcq-packages.json; resolves versions and
  # engines.node from core's package.json.
  local ddev_cmd="$1"
  local app_root="$2"
  local container_package_json="/var/www/html/package.json"
  local php_code
  local php_payload
  local output
  local status

  php_code=$(cat <<'PHP'
$corePath = "__DOCROOT_COREDIR__/package.json";
$dcqPath = "/var/www/html/.ddev/drupal-code-quality/assets/dcq-packages.json";

$core = json_decode(file_get_contents($corePath), true);
if (!is_array($core)) {
  fwrite(STDERR, "Failed to read core package.json\n");
  exit(1);
}
$dcq = json_decode(file_get_contents($dcqPath), true);
if (!is_array($dcq) || !isset($dcq["packages"])) {
  fwrite(STDERR, "Failed to read dcq-packages.json\n");
  exit(1);
}

$coreDeps = [];
foreach (["dependencies", "devDependencies"] as $key) {
  if (isset($core[$key]) && is_array($core[$key])) {
    $coreDeps += $core[$key];
  }
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
  "name" => $projectName ?: "drupal-project",
  "private" => true,
];
if (isset($core["engines"]["node"])) {
  $out["engines"] = ["node" => $core["engines"]["node"]];
}

$devDeps = [];
foreach ($dcq["packages"] as $pkg) {
  $devDeps[$pkg] = $coreDeps[$pkg] ?? "";
}
$out["devDependencies"] = $devDeps;

echo json_encode($out, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL;
PHP
  )
  php_code="${php_code//__DOCROOT_COREDIR__/${DOCROOT_COREDIR}}"
  php_payload="$(printf '%s' "$php_code" | base64 | tr -d '\n')"

  # Use bash -lc so the php -r argument stays quoted; ddev exec can reparse
  # complex arguments and break on parentheses/semicolons.
  output="$("$ddev_cmd" exec bash -lc "php -r 'eval(base64_decode(\"${php_payload}\"));'" 2>&1)"
  status=$?

  if [ "$status" -ne 0 ] || [ -z "$output" ]; then
    printf 'Unable to create project package.json from core.\n' >&2
    printf 'Helper status: %s\n' "$status" >&2
    if [ -n "$output" ]; then
      printf '%s\n' "$output" >&2
    else
      printf 'No output from helper.\n' >&2
    fi
    return 1
  fi

  if ! printf '%s' "$output" | grep -q '^{'; then
    printf 'Unable to create project package.json from core (invalid output).\n' >&2
    printf '%s\n' "$output" >&2
    return 1
  fi

  printf '%s\n' "$output" > "${app_root%/}/package.json"
  emit 'WRITE: %s\n' "${app_root%/}/package.json"

  if command_available "$ddev_cmd"; then
    if ! printf '%s\n' "$output" | "$ddev_cmd" exec bash -lc "cat > ${container_package_json}"; then
      printf 'Failed to write %s in container; Node install may fail.\n' "$container_package_json" >&2
    fi
    if ! "$ddev_cmd" exec test -f "$container_package_json" >/dev/null 2>&1; then
      printf '%s not visible in container; Node install may fail.\n' "$container_package_json" >&2
    fi
  fi

  emit 'Created package.json with DCQ dependencies (versions from Drupal core); review and customize as needed.\n'
  return 0
}

find_missing_node_deps() {
  # Determine missing JS tooling deps by comparing root package.json to the
  # curated list in dcq-packages.json (versions from core). Config files are
  # also scanned as a safety net for user-added plugins not in the curated list.
  local ddev_cmd="$1"
  local php_code
  local php_payload
  local output
  local status

  php_code=$(cat <<'PHP'
$rootPath = "/var/www/html/package.json";
$corePath = "__DOCROOT_COREDIR__/package.json";
$assetsRoot = "/var/www/html/.ddev/drupal-code-quality/assets";
$dcqPath = $assetsRoot . "/dcq-packages.json";

function read_json_file(string $path): ?array {
  if (!is_readable($path)) {
    return null;
  }
  $lines = file($path, FILE_IGNORE_NEW_LINES);
  if ($lines === false) {
    return null;
  }
  $filtered = [];
  foreach ($lines as $line) {
    if ($line !== "" && $line[0] === "#") {
      continue;
    }
    $filtered[] = $line;
  }
  $json = implode("\n", $filtered);
  $data = json_decode($json, true);
  return is_array($data) ? $data : null;
}

function merge_deps(array $data): array {
  $deps = [];
  foreach (["dependencies", "devDependencies"] as $key) {
    if (isset($data[$key]) && is_array($data[$key])) {
      $deps += $data[$key];
    }
  }
  return $deps;
}

function add_required(array &$required, string $name, array $coreDeps): void {
  if (!array_key_exists($name, $required)) {
    $required[$name] = $coreDeps[$name] ?? "";
  }
}

function eslint_plugin_package(string $plugin): string {
  if ($plugin === "") {
    return "";
  }
  if ($plugin[0] === "@") {
    $parts = explode("/", $plugin, 2);
    if (count($parts) === 1) {
      return $plugin . "/eslint-plugin";
    }
    return $parts[0] . "/eslint-plugin-" . $parts[1];
  }
  return "eslint-plugin-" . $plugin;
}

function eslint_config_package(string $config): string {
  if ($config === "") {
    return "";
  }
  if ($config[0] === "@") {
    $parts = explode("/", $config, 2);
    if (count($parts) === 1) {
      return $config . "/eslint-config";
    }
    return $parts[0] . "/eslint-config-" . $parts[1];
  }
  return "eslint-config-" . $config;
}

$root = read_json_file($rootPath);
$core = read_json_file($corePath);
if (!is_array($root) || !is_array($core)) {
  exit(0);
}

$rootDeps = merge_deps($root);
$coreDeps = merge_deps($core);

// Seed required set from the curated package list.
$dcqData = read_json_file($dcqPath);
$required = [];
if (is_array($dcqData) && isset($dcqData["packages"])) {
  foreach ($dcqData["packages"] as $pkg) {
    $required[$pkg] = $coreDeps[$pkg] ?? "";
  }
}

// Safety net: also scan config files for user-added plugins/extends not in
// the curated list.
$eslintConfigs = [
  $assetsRoot . "/.eslintrc.json",
  $assetsRoot . "/.eslintrc.jquery.json",
  $assetsRoot . "/.eslintrc.passing.json",
];
foreach ($eslintConfigs as $path) {
  $config = read_json_file($path);
  if (!is_array($config)) {
    continue;
  }
  if (isset($config["plugins"]) && is_array($config["plugins"])) {
    foreach ($config["plugins"] as $plugin) {
      if (!is_string($plugin)) {
        continue;
      }
      $pkg = eslint_plugin_package($plugin);
      if ($pkg !== "") {
        add_required($required, $pkg, $coreDeps);
      }
    }
  }
  if (isset($config["extends"]) && is_array($config["extends"])) {
    foreach ($config["extends"] as $extend) {
      if (!is_string($extend) || $extend === "") {
        continue;
      }
      if ($extend[0] === "." || $extend[0] === "/") {
        continue;
      }
      if (strpos($extend, "eslint:") === 0) {
        continue;
      }
      if (preg_match("/^plugin:([^\\/]+)\\//", $extend, $matches)) {
        $pluginName = $matches[1];
        $pkg = eslint_plugin_package($pluginName);
        if ($pkg !== "") {
          add_required($required, $pkg, $coreDeps);
        }
        continue;
      }
      $pkg = eslint_config_package($extend);
      if ($pkg !== "") {
        add_required($required, $pkg, $coreDeps);
      }
    }
  }
}

$stylelintConfig = read_json_file($assetsRoot . "/.stylelintrc.json");
if (is_array($stylelintConfig)) {
  if (isset($stylelintConfig["plugins"]) && is_array($stylelintConfig["plugins"])) {
    foreach ($stylelintConfig["plugins"] as $plugin) {
      if (is_string($plugin) && $plugin !== "") {
        add_required($required, $plugin, $coreDeps);
      }
    }
  }
  if (isset($stylelintConfig["extends"]) && is_array($stylelintConfig["extends"])) {
    foreach ($stylelintConfig["extends"] as $extend) {
      if (!is_string($extend) || $extend === "") {
        continue;
      }
      if ($extend[0] === "." || $extend[0] === "/") {
        continue;
      }
      $pkg = $extend;
      if (strpos($extend, "/") !== false) {
        $pkg = explode("/", $extend, 2)[0];
      }
      add_required($required, $pkg, $coreDeps);
    }
  }
}

$missing = [];
foreach ($required as $name => $version) {
  if (!array_key_exists($name, $rootDeps)) {
    $missing[$name] = $version;
  }
}
if (!$missing) {
  exit(0);
}
foreach ($missing as $name => $version) {
  $suffix = $version ? "@".$version : "";
  echo $name . $suffix . PHP_EOL;
}
PHP
  )
  php_code="${php_code//__DOCROOT_COREDIR__/${DOCROOT_COREDIR}}"
  php_payload="$(printf '%s' "$php_code" | base64 | tr -d '\n')"

  # Use bash -lc so the php -r argument stays quoted; ddev exec can reparse
  # complex arguments and break on parentheses/semicolons.
  output="$("$ddev_cmd" exec bash -lc "php -r 'eval(base64_decode(\"${php_payload}\"));'" 2>&1)"
  status=$?

  if [ "$status" -ne 0 ]; then
    return 1
  fi

  printf '%s' "$output"
}

maybe_install_missing_root_deps() {
  # Prompt to add missing root devDependencies when root package.json exists.
  local ddev_cmd="$1"
  local non_interactive="$2"
  local package_manager="$3"
  local auto_add="${4:-0}"
  local suppress_list="${5:-0}"
  local missing_node_deps

  if ! missing_node_deps="$(find_missing_node_deps "$ddev_cmd")"; then
    return 1
  fi

  if [ -z "$missing_node_deps" ]; then
    return 1
  fi

  # Avoid mapfile (requires bash 4+; macOS ships bash 3.2).
  missing_node_deps_array=()
  while IFS= read -r _line; do
    [ -n "$_line" ] && missing_node_deps_array+=("$_line")
  done <<< "$missing_node_deps"
  if [ "$suppress_list" -ne 1 ]; then
    emit 'Detected missing Drupal JS tooling dependencies in package.json (%d):\n' "${#missing_node_deps_array[@]}"
    for dep in "${missing_node_deps_array[@]}"; do
      [ -n "$dep" ] || continue
      emit '  %s\n' "$dep"
    done
  fi

  if [ "$package_manager" = "npm" ]; then
    prompt_msg="Add missing dependencies with 'npm install --save-dev' in the project root? This updates package.json and package-lock.json."
  else
    prompt_msg="Add missing dependencies with 'yarn add -D' in the project root? This updates package.json and yarn.lock."
  fi

  should_add=0
  if [ "$auto_add" -eq 1 ]; then
    should_add=1
  elif [ "$non_interactive" -eq 1 ]; then
    emit 'Skipping dependency add (non-interactive). Install the missing packages to avoid lint errors.\n'
    return 1
  elif prompt_yes_no "$prompt_msg" 1; then
    should_add=1
  fi

  if [ "$should_add" -eq 1 ]; then
    deps_cmd=""
    for dep in "${missing_node_deps_array[@]}"; do
      deps_cmd+=" $(printf '%q' "$dep")"
    done
    if [ "$package_manager" = "npm" ]; then
      # shellcheck disable=SC2086
      cmd=( "$ddev_cmd" "npm" "install" "--save-dev" "--package-lock"${deps_cmd} )
      if ! run_command "${cmd[@]}"; then
        emit 'npm install --save-dev failed. You can retry manually.\n'
        emit_dcq_package_list "npm"
        return 1
      fi
      emit 'Node dependencies added (project root).\n'
      cmd=( "$ddev_cmd" "npm" "install" "--package-lock" )
      if ! run_command "${cmd[@]}"; then
        emit 'npm install failed. You can retry manually.\n'
        emit_dcq_package_list "npm"
        return 1
      fi
    else
      # shellcheck disable=SC2086
      cmd=( "$ddev_cmd" "yarn" "add" "-D"${deps_cmd} )
      if ! run_command "${cmd[@]}"; then
        emit 'yarn add failed. You can retry manually.\n'
        emit_dcq_package_list "yarn"
        return 1
      fi
      emit 'Node dependencies added (project root).\n'
    fi
    return 0
  fi

  emit 'Skipping missing dependency install. ESLint plugins may be unavailable.\n'
  return 1
}

prompt_node_install_action() {
  local has_root="$1"
  local missing_deps="$2"
  local choice
  local first_char

  NODE_INSTALL_ACTION="install"

  if [ "${PROMPT_AVAILABLE:-0}" -ne 1 ]; then
    return
  fi

  if [ "$has_root" -eq 0 ]; then
    emit 'No project package.json found.\n'
  fi

  if [ -n "$missing_deps" ]; then
    emit 'Some required node modules are missing:\n'
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      emit '  %s\n' "$dep"
    done <<< "$missing_deps"
  fi

  emit 'ESLint, Prettier, and Stylelint require several packages to function properly.\n'
  emit '\n'
  emit '[i]nstall in the project root, [s]kip (default: install): '
  if ! IFS= read -r -u "$PROMPT_IN_FD" choice; then
    choice=""
  fi
  # Normalize prompt input to avoid silent fall-through on CR/LF/whitespace.
  choice="${choice//$'\r'/}"
  choice="${choice//$'\n'/}"
  choice="$(printf '%s' "$choice" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  choice="$(string_lower "$choice")"
  if [ -z "$choice" ]; then
    return
  fi

  first_char="${choice:0:1}"
  case "$first_char" in
    i) NODE_INSTALL_ACTION="install" ;;
    s) NODE_INSTALL_ACTION="skip" ;;
    *) NODE_INSTALL_ACTION="install" ;;
  esac
}

emit_node_install_command() {
  local package_manager="$1"
  local missing_deps="$2"
  local has_root="$3"
  local deps_cmd=""
  local cmd=""

  if [ -n "$missing_deps" ]; then
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      deps_cmd+=" $(printf '%q' "$dep")"
    done <<< "$missing_deps"
  fi

  if [ -n "$deps_cmd" ]; then
    if [ "$package_manager" = "npm" ]; then
      cmd="ddev npm install --save-dev${deps_cmd}"
    else
      cmd="ddev yarn add -D${deps_cmd}"
    fi
  else
    if [ "$package_manager" = "npm" ]; then
      cmd="ddev npm install"
    else
      cmd="ddev yarn install"
    fi
  fi

  if [ "$has_root" -eq 0 ]; then
    emit 'No project package.json found. The install requires one at the project root.\n'
  fi
  emit 'Run:\n  %s\n' "$cmd"
}

emit_dcq_package_list() {
  # Print the curated DCQ package list and a manual install command.
  # Usage: emit_dcq_package_list <package_manager>
  local package_manager="${1:-npm}"
  local assets_dir
  assets_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/drupal-code-quality/assets"
  local dcq_packages_file="${assets_dir}/dcq-packages.json"
  local packages=""

  if [ -f "$dcq_packages_file" ]; then
    # Extract package names from the JSON array (lines containing only a quoted
    # string, no colon — excludes keys like "packages" and "_comment").
    packages="$(grep -v ':' "$dcq_packages_file" | grep '"' | sed 's/.*"\([^"]*\)".*/\1/' | tr '\n' ' ')"
  fi

  if [ -z "$packages" ]; then
    packages="cspell eslint eslint-config-airbnb-base eslint-config-prettier eslint-plugin-import eslint-plugin-jsdoc eslint-plugin-no-jquery eslint-plugin-prettier eslint-plugin-yml prettier stylelint stylelint-config-standard stylelint-order stylelint-prettier"
  fi

  emit '\nDCQ requires these npm packages for code quality tooling:\n'
  emit '  %s\n' "$packages"
  emit '\nTo install manually:\n'
  if [ "$package_manager" = "yarn" ]; then
    emit '  ddev yarn add -D %s\n' "$packages"
  else
    emit '  ddev npm install --save-dev %s\n' "$packages"
  fi
}

prompt_yes_no() {
  # Standard yes/no prompt with default behavior.
  local question="$1"
  local default_no="$2"
  local suffix

  if [ "${PROMPT_AVAILABLE:-0}" -ne 1 ]; then
    printf 'No interactive terminal detected; skipping prompt. Use DCQ_INSTALL_* env vars to control behavior.\n' >&2
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

prompt_recommended_settings() {
  # Prompt for accepting recommended settings (default: yes).
  if [ "${PROMPT_AVAILABLE:-0}" -ne 1 ]; then
    return 1
  fi

  if prompt_yes_no "Accept recommended settings for this install?" 0; then
    return 0
  fi
  return 1
}

print_recommended_settings_summary() {
  # Show what the one-step recommended install will do before prompting.
  if [ "${PROMPT_AVAILABLE:-0}" -ne 1 ]; then
    return
  fi

  emit '\nRecommended defaults for this install:\n'
  emit '  - If a copied config file already exists, the installer will create a backup and then replace the file.\n'
  emit '  - Install missing PHP tooling via drupal/core-dev, including PHPStan, PHPCS, PHPCBF, and Drupal coding standards.\n'
  emit '  - Install Node tooling in the project root, including ESLint, Stylelint, Prettier, and CSpell dependencies.\n'
  emit '  - Set phpstan.neon level to 3 as a practical local default.\n'
  emit '  - Merge DCQ VS Code/Codium settings into .vscode/settings.json and extension recommendations into .vscode/extensions.json.\n'
  emit "  - Add 'dcq-reports/' to .gitignore so generated check logs and patch previews are not committed.\n"
}

set_default_env() {
  local name="$1"
  local value="$2"
  if [ -z "${!name:-}" ]; then
    printf -v "$name" '%s' "$value"
    if [ "$non_interactive" -eq 1 ]; then
      emit 'Using recommended default: %s=%s (override with env var)\n' "$name" "$value"
    fi
  fi
  # Always return success - this is just setting defaults
  return 0
}

prompt_ide_settings_mode() {
  # Prompt for IDE settings merge/overwrite/skip mode; sets PROMPT_IDE_MODE_RESULT.
  local choice

  PROMPT_IDE_MODE_RESULT="skip"

  if [ "${PROMPT_AVAILABLE:-0}" -ne 1 ]; then
    return
  fi

  printf 'VS Code/Codium settings/extensions: [m]erge, [o]verwrite (backup), [s]kip (default: skip): ' >&"$PROMPT_OUT_FD"
  if ! IFS= read -r -u "$PROMPT_IN_FD" choice; then
    choice=""
  fi
  choice="$(string_lower "$choice")"
  if [ -z "$choice" ]; then
    return
  fi

  case "$choice" in
    m|merge) PROMPT_IDE_MODE_RESULT="merge" ;;
    o|overwrite|replace) PROMPT_IDE_MODE_RESULT="overwrite" ;;
    s|skip|manual) PROMPT_IDE_MODE_RESULT="skip" ;;
    *) PROMPT_IDE_MODE_RESULT="skip" ;;
  esac
}

set_phpstan_level() {
  local config_path="$1"
  local level="$2"
  local tmp
  local replaced=0
  local inserted=0

  if [ ! -f "$config_path" ]; then
    return 1
  fi

  tmp="$(mktemp "${TMPDIR:-/tmp}/dcq-phpstan-XXXXXX")"
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*level:[[:space:]]*[0-9]+ ]]; then
      if [ "$replaced" -eq 0 ]; then
        printf '    level: %s\n' "$level" >>"$tmp"
        replaced=1
      else
        printf '%s\n' "$line" >>"$tmp"
      fi
      continue
    fi
    printf '%s\n' "$line" >>"$tmp"
  done <"$config_path"

  if [ "$replaced" -eq 0 ]; then
    tmp2="$(mktemp "${TMPDIR:-/tmp}/dcq-phpstan-XXXXXX")"
    while IFS= read -r line; do
      printf '%s\n' "$line" >>"$tmp2"
      if [ "$inserted" -eq 0 ] && [[ "$line" =~ ^parameters: ]]; then
        printf '    level: %s\n' "$level" >>"$tmp2"
        inserted=1
      fi
    done <"$tmp"
    if [ "$inserted" -eq 0 ]; then
      printf '\nparameters:\n    level: %s\n' "$level" >>"$tmp2"
    fi
    mv "$tmp2" "$tmp"
  fi

  cat "$tmp" >"$config_path"
  rm -f "$tmp"
  return 0
}

prompt_phpstan_level() {
  local app_root="$1"
  local config_path="${app_root%/}/phpstan.neon"
  local baseline_path="${app_root%/}/phpstan-baseline.neon"
  local answer
  local env_level

  emit '\n==> PHPStan defaults\n'
  emit 'The GitLab CI template defaults to PHPStan level 0, which only catches obvious syntax errors. You can keep level 0 or set a higher level for your project.\n'
  emit 'Recommended starting point: level 3.\n'

  if [ ! -f "$config_path" ]; then
    printf 'phpstan.neon not found in project root; skipping level update.\n'
    return 0
  fi

  env_level="$(string_lower "${DCQ_PHPSTAN_LEVEL:-}")"
  # env_level should now always be set via set_default_env or user override
  if [[ "$env_level" =~ ^([0-9]|10)$ ]]; then
    if set_phpstan_level "$config_path" "$env_level"; then
      emit 'WRITE: %s (level %s)\n' "$config_path" "$env_level"
    else
      printf 'Unable to update phpstan.neon level.\n' >&2
    fi
  elif [ "$non_interactive" -eq 0 ] && [ "${PROMPT_AVAILABLE:-0}" -eq 1 ]; then
    # Interactive mode with invalid/missing level - prompt user
    printf '\n'
    emit 'Set phpstan.neon level (0-10) (default: 0): '
    if ! IFS= read -r -u "$PROMPT_IN_FD" answer; then
      answer=""
    fi
    answer="$(string_lower "$answer")"
    if [ "$answer" = "s" ] || [ "$answer" = "skip" ]; then
      answer=""
    elif [ -z "$answer" ]; then
      answer="0"
    fi
    if [ -n "$answer" ]; then
      if [[ "$answer" =~ ^([0-9]|10)$ ]]; then
        if set_phpstan_level "$config_path" "$answer"; then
          emit 'WRITE: %s (level %s)\n' "$config_path" "$answer"
        else
          printf 'Unable to update phpstan.neon level.\n' >&2
        fi
      else
        printf 'Invalid level "%s"; keeping current phpstan.neon level.\n' "$answer" >&2
      fi
    fi
  fi

  if [ ! -f "$baseline_path" ]; then
    emit 'No phpstan-baseline.neon found. Baselines let you focus on new errors while you fix existing ones over time.\n'
    emit 'Generate one with:\n'
    emit '  ddev phpstan --generate-baseline\n'
  fi
  return 0
}

maybe_add_gitignore_reports() {
  local app_root="$1"
  local mode_raw
  local mode
  local gitignore="${app_root%/}/.gitignore"
  local entry="dcq-reports/"

  mode_raw="$(string_lower "${2:-}")"
  if [ -z "$mode_raw" ]; then
    if [ "$non_interactive" -eq 1 ]; then
      mode="add"
    else
      mode="prompt"
    fi
  else
    case "$mode_raw" in
      1|true|yes|on|add|install|auto) mode="add" ;;
      0|false|no|off|skip) mode="skip" ;;
      *) mode="add" ;;
    esac
  fi

  if [ -f "$gitignore" ] && grep -q "^${entry}$" "$gitignore"; then
    printf 'OK: %s already lists %s\n' "$gitignore" "$entry"
    return 0
  fi

  if [ "$mode" = "add" ]; then
    if [ -f "$gitignore" ]; then
      printf '\n%s\n' "$entry" >>"$gitignore"
    else
      printf '%s\n' "$entry" >"$gitignore"
    fi
    emit 'WRITE: %s\n' "$gitignore"
    return 0
  fi

  if [ "$mode" = "skip" ]; then
    emit 'Skipping .gitignore update for %s.\n' "$entry"
    return 0
  fi

  emit 'Add %s to .gitignore to avoid committing report logs.\n' "$entry"
  printf '\n'
  if prompt_yes_no "Add '${entry}' to .gitignore?" 0; then
    if [ -f "$gitignore" ]; then
      printf '\n%s\n' "$entry" >>"$gitignore"
    else
      printf '%s\n' "$entry" >"$gitignore"
    fi
    emit 'WRITE: %s\n' "$gitignore"
  else
    emit 'Skipping .gitignore update for %s.\n' "$entry"
  fi
  return 0
}

strip_generated_header() {
  # Remove ddev-generated header if present to keep target files clean.
  local source="$1"
  local dest="$2"
  if [ "$(head -n 1 "$source")" = "#ddev-generated" ]; then
    tail -n +2 "$source" >"$dest"
  else
    cat "$source" >"$dest"
  fi
}

rewrite_docroot_config() {
  local source="$1"
  local target="$2"
  local tmp

  if [ "${DCQ_DOCROOT:-web}" = "web" ]; then
    return 0
  fi

  case "$source" in
    */assets/.cspell.json|*/assets/.phpcs.xml)
      tmp="$(mktemp "${TMPDIR:-/tmp}/dcq-docroot-XXXXXX")"
      sed "s|web/|${DCQ_DOCROOT}/|g" "$target" >"$tmp"
      mv "$tmp" "$target"
      ;;
  esac
}

merge_phpstan_config() {
  # Merge phpstan.neon with phpstan.dcq.neon and substitute docroot placeholders.
  local phpstan_source="$1"
  local phpstan_dcq_source="$2"
  local target="$3"
  local docroot="${DCQ_DOCROOT:-web}"
  local tmp

  if [ ! -f "$phpstan_dcq_source" ]; then
    # If dcq amendments don't exist, just use the base config
    return 0
  fi

  # Append DCQ amendments to the target (already contains base phpstan.neon).
  tmp="$(mktemp "${TMPDIR:-/tmp}/dcq-phpstan-XXXXXX")"
  cat "$target" > "$tmp"
  printf '\n' >> "$tmp"
  tail -n +2 "$phpstan_dcq_source" | awk 'BEGIN { seen = 0 }
    {
      if (seen == 0 && $0 ~ /^[[:space:]]*parameters:/) {
        seen = 1
        next
      }
      if (seen == 1) {
        print
      }
    }' >> "$tmp"

  # Substitute __DOCROOT__ placeholder with actual docroot.
  sed "s|__DOCROOT__|${docroot}|g" "$tmp" > "$target"
  rm -f "$tmp"
}

merge_phpcs_config() {
  local phpcs_source="$1"
  local phpcs_dcq_source="$2"
  local target="$3"
  local docroot="${DCQ_DOCROOT:-web}"
  local tmp

  if [ ! -f "$phpcs_dcq_source" ]; then
    # If dcq amendments don't exist, just use the base config
    return 0
  fi

  # NOTE: $target already has the cleaned base config (header stripped, docroot substituted)
  # from the main copy loop. We just need to merge in the amendments.

  # Prepare amendments with docroot substitution
  tmp="$(mktemp "${TMPDIR:-/tmp}/dcq-phpcs-XXXXXX")"
  tail -n +2 "$phpcs_dcq_source" | sed "s|__DOCROOT__|${docroot}|g" > "$tmp"

  # Insert amendments before the closing </ruleset> tag
  # Create a new temp file with the merged content
  local merged
  merged="$(mktemp "${TMPDIR:-/tmp}/dcq-phpcs-merged-XXXXXX")"

  # Copy everything except the closing </ruleset> tag
  sed '/<\/ruleset>/d' "$target" > "$merged"

  # Append our amendments
  cat "$tmp" >> "$merged"

  # Add closing tag back
  printf '\n</ruleset>\n' >> "$merged"

  # Move merged content to target
  cat "$merged" > "$target"

  # Cleanup
  rm -f "$tmp" "$merged"
}

merge_stylelint_config() {
  # Merge .stylelintrc.dcq.json amendments into .stylelintrc.json.
  # Adds top-level keys from the amendment file that are missing in the target.
  local stylelint_dcq_source="$1"
  local target="$2"
  local python_bin=""

  if [ ! -f "$stylelint_dcq_source" ]; then
    return 0
  fi
  if [ ! -f "$target" ]; then
    return 0
  fi

  if command_available python3; then
    python_bin="python3"
  elif command_available python; then
    python_bin="python"
  else
    emit 'Warning: python not available; unable to merge stylelint amendments.\n'
    return 1
  fi

  "$python_bin" - "$target" "$stylelint_dcq_source" <<'PY'
import json
import sys

target_path, amendment_path = sys.argv[1:3]

with open(target_path, encoding="utf-8") as f:
    content = f.read()
lines = content.splitlines()
if lines and lines[0].strip() == "#ddev-generated":
    content = "\n".join(lines[1:])
target = json.loads(content)

with open(amendment_path, encoding="utf-8") as f:
    content = f.read()
lines = content.splitlines()
if lines and lines[0].strip() == "#ddev-generated":
    content = "\n".join(lines[1:])
amendment = json.loads(content)

changed = False
for key, value in amendment.items():
    if key.startswith("_"):
        continue
    if key not in target:
        target[key] = value
        changed = True

if changed:
    with open(target_path, "w", encoding="utf-8") as f:
        json.dump(target, f, indent=4, ensure_ascii=False)
        f.write("\n")
PY
}

append_unique_lines_from_file() {
  local target="$1"
  local source="$2"
  local tmp
  local line

  if [ ! -f "$source" ]; then
    return 0
  fi

  tmp="$(mktemp "${TMPDIR:-/tmp}/dcq-lines-XXXXXX")"
  if [ -f "$target" ]; then
    cat "$target" >"$tmp"
  else
    : >"$tmp"
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "#ddev-generated" ]; then
      continue
    fi
    if grep -Fxq "$line" "$tmp"; then
      continue
    fi
    printf '%s\n' "$line" >>"$tmp"
  done <"$source"

  if [ ! -f "$target" ] || ! cmp -s "$target" "$tmp"; then
    cat "$tmp" >"$target"
    emit_copy 'WRITE: %s\n' "$target"
  fi
  rm -f "$tmp"
}

expand_cspell_config() {
  local app_root="$1"
  local ddev_approot="${DDEV_APPROOT:-$app_root}"
  local prepare_script="${ddev_approot}/.ddev/drupal-code-quality/tooling/scripts/prepare-cspell.php"
  local cspell_config="${app_root%/}/.cspell.json"
  local docroot="${DCQ_DOCROOT:-web}"
  local ddev_cmd="${DDEV_EXECUTABLE:-ddev}"
  local container_cspell="/var/www/html/.cspell.json"
  local container_core_cspell_dir="/var/www/html/${docroot}/core/misc/cspell"
  local container_prepare_script="/mnt/ddev_config/drupal-code-quality/tooling/scripts/prepare-cspell.php"


  # Check if CSpell config exists
  if [ ! -f "$cspell_config" ]; then
    emit 'No .cspell.json found; skipping CSpell expansion.\n'
    return 0
  fi

  # Check if prepare-cspell.php exists
  if [ ! -f "$prepare_script" ]; then
    emit 'prepare-cspell.php not found; skipping CSpell expansion.\n'
    return 0
  fi

  # Run prepare-cspell.php in the container to expand .cspell.json
  if ! command_available "$ddev_cmd"; then
    emit 'DDEV not available; skipping CSpell expansion.\n'
    return 0
  fi

  emit 'Expanding .cspell.json with project-specific settings...\n'

  if ! wait_for_container_file "$ddev_cmd" "$container_cspell" 20 1 "readable"; then
    emit 'Skipping CSpell expansion (.cspell.json not readable in the container after waiting).\n'
    return 0
  fi

  if ! "$ddev_cmd" exec test -f "${container_core_cspell_dir}/dictionary.txt" >/dev/null 2>&1 \
    || ! "$ddev_cmd" exec test -f "${container_core_cspell_dir}/drupal-dictionary.txt" >/dev/null 2>&1; then
    emit 'Skipping CSpell expansion (Drupal core dictionary files are not available at %s).\n' "${docroot}/core/misc/cspell"
    return 0
  fi

  local output
  if output=$("$ddev_cmd" exec bash -lc "cd /var/www/html && export _WEB_ROOT='${docroot}' _CSPELL_DICTIONARY='.cspell-project-words.txt' && php '${container_prepare_script}'" 2>&1); then
    if echo "$output" | grep -q "Writing json"; then
      emit 'Successfully expanded .cspell.json\n'
    else
      emit 'CSpell expansion completed (no changes needed)\n'
    fi
  else
    emit 'Skipping CSpell expansion (prepare-cspell.php failed).\n'
    if truthy "${DCQ_VERBOSE:-0}" && [ -n "$output" ]; then
      emit 'CSpell expansion error output:\n%s\n' "$output"
    fi
  fi

  # Always return success - CSpell expansion is optional
  return 0
}

ensure_phpstan_paths() {
  local app_root="$1"
  local docroot="${DCQ_DOCROOT:-web}"

  # Create standard Drupal directories that PHPStan config expects
  local paths=(
    "${docroot}/modules/custom"
    "${docroot}/themes/custom"
    "${docroot}/sites"
  )

  for path in "${paths[@]}"; do
    ensure_dir "${app_root%/}/${path}"
  done
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
  if [ "${PROMPT_AVAILABLE:-0}" -eq 1 ]; then
    diff -u "$target" "$source" >&"$PROMPT_OUT_FD" || true
  else
    diff -u "$target" "$source" || true
  fi
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

wait_for_container_file() {
  # Wait for a file to appear in the container.  When require_readable is set
  # to a non-empty value the check additionally verifies that the file has
  # non-zero size (test -s), which guards against filesystem-sync race
  # conditions where the inode is visible but the content has not landed yet.
  local ddev_cmd="$1"
  local path="$2"
  local max_attempts="${3:-20}"
  local delay_seconds="${4:-1}"
  local require_readable="${5:-}"
  local attempts=0
  local test_flag="-f"
  if [ -n "$require_readable" ]; then
    test_flag="-s"
  fi

  while [ "$attempts" -lt "$max_attempts" ]; do
    if "$ddev_cmd" exec test "$test_flag" "$path" >/dev/null 2>&1; then
      return 0
    fi
    attempts=$((attempts + 1))
    sleep "$delay_seconds"
  done
  return 1
}

detect_package_manager() {
  local dir="$1"
  local has_yarn=0
  local has_npm=0

  if [ -f "${dir%/}/yarn.lock" ]; then
    has_yarn=1
  fi
  if [ -f "${dir%/}/package-lock.json" ]; then
    has_npm=1
  fi

  if [ "$has_npm" -eq 1 ] && [ "$has_yarn" -eq 1 ]; then
    printf 'Both yarn.lock and package-lock.json found in %s; defaulting to npm.\n' "$dir" >&2
    printf 'npm'
    return
  fi
  if [ "$has_npm" -eq 1 ]; then
    printf 'npm'
    return
  fi
  if [ "$has_yarn" -eq 1 ]; then
    printf 'yarn'
    return
  fi

  printf 'npm'
}

ensure_root_yarnrc() {
  local app_root="$1"
  if [ -f "${app_root%/}/${DCQ_DOCROOT}/core/.yarnrc.yml" ] && [ ! -f "${app_root%/}/.yarnrc.yml" ]; then
    cp "${app_root%/}/${DCQ_DOCROOT}/core/.yarnrc.yml" "${app_root%/}/.yarnrc.yml"
    emit 'WRITE: %s\n' "${app_root%/}/.yarnrc.yml"
  fi
}

escape_sed_replacement() {
  printf '%s' "${1:-}" | sed 's/[&|]/\\&/g'
}

eslint_quiet_disabled() {
  case "${1:-}" in
    0|false|FALSE|False|no|NO|off|OFF)
      return 0
      ;;
  esac
  return 1
}

resolve_eslint_quiet_setting() {
  local app_root="$1"
  local raw="${DCQ_ESLINT_QUIET:-}"
  local config_file=""
  local matched_line=""

  if [ -z "$raw" ]; then
    for config_file in "${app_root%/}/.ddev/config.yaml" "${app_root%/}/.ddev/config.yml"; do
      [ -f "$config_file" ] || continue
      matched_line="$(grep -E '^[[:space:]-]*["'"'"']?DCQ_ESLINT_QUIET=' "$config_file" | tail -n 1 || true)"
      [ -n "$matched_line" ] || continue
      raw="${matched_line#*=}"
      raw="${raw%%#*}"
      raw="$(printf '%s' "$raw" | tr -d "\"'" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$raw" ] && break
    done
  fi

  if eslint_quiet_disabled "$raw"; then
    printf 'false'
    return
  fi
  printf 'true'
}

render_ide_template() {
  # Render IDE settings template with resolved shim and tool paths.
  local template="$1"
  local output="$2"
  local shim_setting="$3"
  local stylelint_path="$4"
  local prettier_path="$5"
  local eslint_node_path="$6"
  local eslint_resolve_plugins="$7"
  local eslint_quiet="$8"
  local escaped_shim
  local escaped_stylelint
  local escaped_prettier
  local escaped_node_path
  local escaped_resolve_plugins
  local escaped_eslint_quiet

  escaped_shim="$(escape_sed_replacement "$shim_setting")"
  escaped_stylelint="$(escape_sed_replacement "$stylelint_path")"
  escaped_prettier="$(escape_sed_replacement "$prettier_path")"
  escaped_node_path="$(escape_sed_replacement "$eslint_node_path")"
  escaped_resolve_plugins="$(escape_sed_replacement "$eslint_resolve_plugins")"
  escaped_eslint_quiet="$(escape_sed_replacement "$eslint_quiet")"

  sed \
    -e '1{/^#ddev-generated$/d;}' \
    -e "s|__DCQ_SHIM_DIR__|${escaped_shim}|g" \
    -e "s|__DCQ_STYLELINT_PATH__|${escaped_stylelint}|g" \
    -e "s|__DCQ_PRETTIER_PATH__|${escaped_prettier}|g" \
    -e "s|__DCQ_ESLINT_NODE_PATH__|${escaped_node_path}|g" \
    -e "s|__DCQ_ESLINT_RESOLVE_PLUGINS__|${escaped_resolve_plugins}|g" \
    -e "s|__DCQ_ESLINT_QUIET__|${escaped_eslint_quiet}|g" \
    "$template" >"$output"
}

strip_ide_js_settings() {
  local settings_path="$1"
  local python_bin=""

  if command_available python3; then
    python_bin="python3"
  elif command_available python; then
    python_bin="python"
  else
    emit 'Warning: python not available; unable to remove JS tool paths from %s.\n' "$settings_path"
    return 1
  fi

  if ! "$python_bin" - "$settings_path" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)

for key in ("stylelint.stylelintPath", "prettier.prettierPath", "eslint.nodePath", "eslint.options"):
    data.pop(key, None)

with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2, sort_keys=False)
    handle.write("\n")
PY
  then
    emit 'Warning: unable to strip JS tool paths from %s.\n' "$settings_path"
    return 1
  fi

  return 0
}

merge_json_settings() {
  # Merge settings.json: keep existing keys, add missing keys from template.
  local existing="$1"
  local template="$2"
  local dest="$3"
  local python_bin=""

  if command_available python3; then
    python_bin="python3"
  elif command_available python; then
    python_bin="python"
  else
    return 2
  fi

  "$python_bin" - "$existing" "$template" "$dest" <<'PY'
import copy
import json
import sys

existing_path, template_path, dest_path = sys.argv[1:4]

def strip_jsonc(text):
    out = []
    i = 0
    in_string = False
    escape = False
    in_line = False
    in_block = False
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if in_line:
            if ch == "\n":
                in_line = False
                out.append(ch)
            i += 1
            continue
        if in_block:
            if ch == "*" and nxt == "/":
                in_block = False
                i += 2
                continue
            i += 1
            continue
        if in_string:
            out.append(ch)
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if ch == "/" and nxt == "/":
            in_line = True
            i += 2
            continue
        if ch == "/" and nxt == "*":
            in_block = True
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)

def strip_trailing_commas(text):
    out = []
    i = 0
    in_string = False
    escape = False
    while i < len(text):
        ch = text[i]
        if in_string:
            out.append(ch)
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if ch == ",":
            j = i + 1
            while j < len(text) and text[j] in " \t\r\n":
                j += 1
            if j < len(text) and text[j] in "}]":
                i += 1
                continue
        out.append(ch)
        i += 1
    return "".join(out)

def load_json(path):
    with open(path, encoding="utf-8") as f:
        content = f.read()
    lines = content.splitlines()
    if lines and lines[0].strip() == "#ddev-generated":
        content = "\n".join(lines[1:])
    content = strip_trailing_commas(strip_jsonc(content))
    return json.loads(content)

try:
    existing = load_json(existing_path)
    template = load_json(template_path)
except Exception as exc:
    sys.stderr.write(
        "WARNING: Failed to parse JSONC in VS Code settings; skipping merge. "
        f"{exc}\n"
    )
    raise SystemExit(1)

if not isinstance(existing, dict) or not isinstance(template, dict):
    raise SystemExit("settings JSON must be objects")

original = copy.deepcopy(existing)

for key, value in template.items():
    if key not in existing:
        existing[key] = value

if existing == original:
    raise SystemExit(3)

with open(dest_path, "w", encoding="utf-8") as f:
    json.dump(existing, f, indent=2, ensure_ascii=True)
    f.write("\n")
PY
  return $?
}

merge_json_extensions() {
  # Merge extensions.json: union recommendations/unwantedRecommendations, preserve other keys.
  local existing="$1"
  local template="$2"
  local dest="$3"
  local python_bin=""

  if command_available python3; then
    python_bin="python3"
  elif command_available python; then
    python_bin="python"
  else
    return 2
  fi

  "$python_bin" - "$existing" "$template" "$dest" <<'PY'
import json
import sys

existing_path, template_path, dest_path = sys.argv[1:4]

def strip_jsonc(text):
    out = []
    i = 0
    in_string = False
    escape = False
    in_line = False
    in_block = False
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if in_line:
            if ch == "\n":
                in_line = False
                out.append(ch)
            i += 1
            continue
        if in_block:
            if ch == "*" and nxt == "/":
                in_block = False
                i += 2
                continue
            i += 1
            continue
        if in_string:
            out.append(ch)
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if ch == "/" and nxt == "/":
            in_line = True
            i += 2
            continue
        if ch == "/" and nxt == "*":
            in_block = True
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)

def strip_trailing_commas(text):
    out = []
    i = 0
    in_string = False
    escape = False
    while i < len(text):
        ch = text[i]
        if in_string:
            out.append(ch)
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if ch == ",":
            j = i + 1
            while j < len(text) and text[j] in " \t\r\n":
                j += 1
            if j < len(text) and text[j] in "}]":
                i += 1
                continue
        out.append(ch)
        i += 1
    return "".join(out)

def load_json(path):
    with open(path, encoding="utf-8") as f:
        content = f.read()
    lines = content.splitlines()
    if lines and lines[0].strip() == "#ddev-generated":
        content = "\n".join(lines[1:])
    content = strip_trailing_commas(strip_jsonc(content))
    return json.loads(content)

try:
    existing = load_json(existing_path)
    template = load_json(template_path)
except Exception as exc:
    sys.stderr.write(
        "WARNING: Failed to parse JSONC in VS Code extensions; skipping merge. "
        f"{exc}\n"
    )
    raise SystemExit(1)

if not isinstance(existing, dict) or not isinstance(template, dict):
    raise SystemExit("extensions JSON must be objects")

merged = dict(existing)

def merge_list(key):
    existing_list = existing.get(key, [])
    template_list = template.get(key, [])
    if not isinstance(existing_list, list):
        existing_list = []
    if not isinstance(template_list, list):
        template_list = []
    merged_list = []
    seen = set()
    for item in existing_list + template_list:
        if isinstance(item, str) and item not in seen:
            merged_list.append(item)
            seen.add(item)
    if merged_list:
        merged[key] = merged_list
    elif key in existing:
        merged[key] = existing_list
    elif key in template:
        merged[key] = template_list

merge_list("recommendations")
merge_list("unwantedRecommendations")

for key, value in template.items():
    if key in ("recommendations", "unwantedRecommendations"):
        continue
    if key not in merged:
        merged[key] = value

if merged == existing:
    raise SystemExit(3)

with open(dest_path, "w", encoding="utf-8") as f:
    json.dump(merged, f, indent=2, ensure_ascii=True)
    f.write("\n")
PY
  return $?
}

node_toolchain_present() {
  # Detect installed eslint tooling at the project root (root-only policy).
  local app_root="$1"
  local paths=(
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

detect_scss_files() {
  # Check if the project contains .scss or .sass files (excluding dependencies).
  local search_root="$1"
  find "$search_root" \
    -type d \( -name node_modules -o -name vendor -o -name .git -o -name .ddev \) -prune \
    -o -type f \( -name '*.scss' -o -name '*.sass' \) -print -quit 2>/dev/null | grep -q .
}

run_command() {
  # Echo and execute a command (simple transparency for users).
  # In interactive installs we route output through a small sanitizer to drop
  # terminal query/response noise (OSC/DSR bytes) that can appear as garbage.
  local arg
  local status
  emit 'Running: %s\n' "$*"
  if [ "${non_interactive:-0}" -eq 1 ] || [ "${PROMPT_AVAILABLE:-0}" -ne 1 ]; then
    "$@"
  else
    if command_available perl; then
      "$@" 2>&1 | perl -pe 's/\e\][^\a\x1b]*(?:\a|\e\\)//g; s/\e\[[0-9;?]*R//g;' >&"$PROMPT_OUT_FD"
      status=${PIPESTATUS[0]}
      return "$status"
    fi
    "$@" >&"$PROMPT_OUT_FD"
  fi
}

ensure_composer_plugin_blocked() {
  # Preseed Composer plugin policy to avoid interactive trust prompts when
  # users accept recommended installer settings.
  local ddev_cmd="$1"
  local app_root="$2"
  local composer_json="${app_root%/}/composer.json"
  local plugin_name="tbachert/spi"
  local plugin_key="allow-plugins.${plugin_name}"
  local cmd

  if [ ! -f "$composer_json" ]; then
    return 0
  fi
  if ! command_available "$ddev_cmd"; then
    return 0
  fi

  if grep -Eq "\"${plugin_name}\"[[:space:]]*:[[:space:]]*false" "$composer_json"; then
    return 0
  fi

  if grep -Eq "\"${plugin_name}\"[[:space:]]*:[[:space:]]*true" "$composer_json"; then
    emit 'Composer plugin trust for %s already configured; leaving existing setting.\n' "$plugin_name"
    return 0
  fi

  cmd=( "$ddev_cmd" "composer" "config" "--no-plugins" "$plugin_key" "false" )

  if run_command "${cmd[@]}"; then
    emit 'Set Composer %s=false to avoid plugin trust prompts.\n' "$plugin_key"
  else
    emit 'WARNING: Failed to set Composer %s=false; dependency install may prompt.\n' "$plugin_key"
  fi
}

emit_unique_path_list() {
  # Emit a de-duplicated list of relative paths, one per line.
  if [ "$#" -eq 0 ]; then
    return 0
  fi
  printf '%s\n' "$@" | sed '/^$/d' | sort -u | while IFS= read -r path; do
    emit '  - %s\n' "$path"
  done
}

prompt_setup


cwd="$(pwd)"
app_root="${DDEV_APPROOT:-}"
if [ -z "$app_root" ]; then
  app_root="$(cd "$cwd/.." && pwd)"
fi

dcq_docroot="${DDEV_DOCROOT-web}"
DCQ_DOCROOT="$dcq_docroot"
DOCROOT_CONTAINER="/var/www/html/${DCQ_DOCROOT}"
DOCROOT_COREDIR="${DOCROOT_CONTAINER}/core"
docroot_file="${app_root%/}/.ddev/.dcq-docroot"
if [ -f "$docroot_file" ]; then
  if ! grep -Fxq "$DCQ_DOCROOT" "$docroot_file"; then
    printf '%s\n' "$DCQ_DOCROOT" >"$docroot_file"
    emit_copy 'WRITE: %s\n' "$docroot_file"
  fi
else
  printf '%s\n' "$DCQ_DOCROOT" >"$docroot_file"
  emit_copy 'WRITE: %s\n' "$docroot_file"
fi


node_target_choice=""

addon_root="${cwd}/drupal-code-quality"
assets_root="${addon_root}/assets"
if [ ! -d "$assets_root" ]; then
  printf 'drupal-code-quality assets directory not found at %s.\n' "$assets_root" >&2
  exit 1
fi

shim_dir_env=".ddev/drupal-code-quality/tooling/bin"
shim_dir="${app_root%/}/${shim_dir_env}"

non_interactive=0
if truthy "${DDEV_NONINTERACTIVE:-}"; then
  non_interactive=1
fi
if truthy "${DCQ_NONINTERACTIVE:-}"; then
  non_interactive=1
fi

if [ "${PROMPT_AVAILABLE:-0}" -ne 1 ]; then
  non_interactive=1
fi

# In interactive mode, offer to accept all recommended settings at once.
# In non-interactive mode, or if user accepts, set recommended defaults for any unset vars.
recommended_mode=0
if [ "$non_interactive" -eq 0 ] && [ "${PROMPT_AVAILABLE:-0}" -eq 1 ]; then
  print_recommended_settings_summary
  if prompt_recommended_settings; then
    recommended_mode=1
  else
    emit 'Using manual mode. You will be prompted for each setting.\n'
  fi
fi

# Set recommended defaults when in non-interactive mode or when user accepts recommended settings.
# In interactive mode with user declining, each setting will be prompted individually.
if [ "$non_interactive" -eq 1 ] || [ "$recommended_mode" -eq 1 ]; then
  set_default_env "DCQ_INSTALL_MODE" "replace"
  set_default_env "DCQ_INSTALL_DEPS" "install"
  set_default_env "DCQ_INSTALL_NODE_DEPS" "root"
  set_default_env "DCQ_PHPSTAN_LEVEL" "3"
  set_default_env "DCQ_INSTALL_IDE_SETTINGS" "merge"
  set_default_env "DCQ_INSTALL_GITIGNORE" "add"
fi

# Fail loudly if ddev describe cannot resolve a project. Silent skips later are
# usually caused by running in a context where DDEV can't find .ddev/config.yaml.
ddev_cmd="${DDEV_EXECUTABLE:-ddev}"
if command_available "$ddev_cmd"; then
  if ! "$ddev_cmd" describe >/dev/null 2>&1; then
    emit 'ERROR: ddev describe could not resolve a project from %s.\n' "${PWD:-.}"
    emit 'Run the installer from the target project (for add-on installs, this should be automatic).\n'
    emit 'Try: cd %s && ddev describe\n' "$app_root"
    exit 1
  fi
fi

install_mode="$(string_lower "${DCQ_INSTALL_MODE:-}")"
replace_all=0
skip_all=0
abort_on_conflict=0
case "$install_mode" in
  replace) replace_all=1 ;;
  skip) skip_all=1 ;;
  abort) abort_on_conflict=1 ;;
esac

emit '\n==> Phase 1: PHP tooling dependencies\n'
php_deps_failed=0
vendor_bin="${app_root%/}/vendor/bin"
missing_tools=()
for tool in phpstan phpcs phpcbf; do
  if [ ! -e "${vendor_bin}/${tool}" ]; then
    missing_tools+=("$tool")
  fi
done

if [ "${#missing_tools[@]}" -eq 0 ]; then
  emit 'PHP dev tools already present (phpstan, phpcs, phpcbf). No action needed.\n'
elif [ "${#missing_tools[@]}" -gt 0 ]; then
  composer_json="${app_root%/}/composer.json"
  has_core_dev=0
  if [ -f "$composer_json" ] && grep -q '"drupal/core-dev"' "$composer_json"; then
    has_core_dev=1
  fi

  ddev_cmd="${DDEV_EXECUTABLE:-ddev}"
  deps_mode_raw="$(string_lower "${DCQ_INSTALL_DEPS:-}")"
  if [ "$deps_mode_raw" = "1" ] || [ "$deps_mode_raw" = "true" ] || [ "$deps_mode_raw" = "yes" ] || [ "$deps_mode_raw" = "on" ] || [ "$deps_mode_raw" = "install" ] || [ "$deps_mode_raw" = "auto" ]; then
    deps_mode="install"
  elif [ "$deps_mode_raw" = "0" ] || [ "$deps_mode_raw" = "false" ] || [ "$deps_mode_raw" = "no" ] || [ "$deps_mode_raw" = "off" ] || [ "$deps_mode_raw" = "skip" ]; then
    deps_mode="skip"
  elif [ -z "$deps_mode_raw" ]; then
    if [ "$non_interactive" -eq 1 ]; then
      deps_mode="install"
    else
      deps_mode="prompt"
    fi
  else
    # Unrecognized values fall back to install for backwards compatibility.
    deps_mode="install"
  fi

  emit 'Missing dev tools: %s.\n' "$(printf '%s ' "${missing_tools[@]}" | sed 's/[[:space:]]*$//')"
  if [ ! -f "$composer_json" ]; then
    emit 'composer.json not found; skipping dependency install.\n'
    missing_tools=()
  fi

  if [ "${#missing_tools[@]}" -gt 0 ] && ! command_available "$ddev_cmd"; then
    emit 'ddev executable not found in PATH; skipping dependency install.\n'
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
      question="Install PHP dev tools from composer.lock now?"
    else
      question="Install drupal/core-dev now to provide PHP code quality tools and Drupal coding standards?"
    fi

    should_install=0
    if [ "$deps_mode" = "install" ]; then
      should_install=1
    elif [ "$deps_mode" = "prompt" ]; then
      printf '\n'
      if prompt_yes_no "$question" 0; then
        should_install=1
      fi
    fi

    if [ "$should_install" -ne 1 ]; then
      emit "Skipping dependency install. Run '%s' later to enable PHPStan/PHPCS/PHPCBF.\n" "${cmd[*]}"
    else
      composer_succeeded=0
      while true; do
        if (
          cd "$app_root"
          if [ "$recommended_mode" -eq 1 ]; then
            ensure_composer_plugin_blocked "$ddev_cmd" "$app_root"
          fi
          run_command "${cmd[@]}"
        ); then
          composer_succeeded=1
          break
        fi

        emit '\n'
        emit 'WARNING: PHP dev tools installation failed.\n'
        emit 'The composer output above should indicate the cause. Common issues:\n'
        emit '  - Security advisories blocking dependency resolution (update Drupal core first)\n'
        emit '  - allow-plugins not configured (add the plugin to composer.json allow-plugins)\n'
        emit '\n'
        emit 'You can fix the issue in another terminal and retry.\n'
        emit 'Command was: %s\n' "${cmd[*]}"

        if [ "$non_interactive" -eq 1 ]; then
          emit 'Non-interactive mode: proceeding without PHP dev tools.\n'
          break
        fi

        if [ "${PROMPT_AVAILABLE:-0}" -ne 1 ]; then
          emit 'No interactive terminal: proceeding without PHP dev tools.\n'
          break
        fi

        printf '\n[r]etry, [p]roceed without PHP tools, [a]bort install (default: proceed): ' >&"$PROMPT_OUT_FD"
        fail_answer=""
        if ! IFS= read -r -u "$PROMPT_IN_FD" fail_answer; then
          fail_answer=""
        fi
        fail_answer="$(string_lower "$(printf '%s' "$fail_answer" | tr -d '\r\n')")"

        case "$fail_answer" in
          r|retry)
            emit 'Retrying composer install...\n'
            continue
            ;;
          a|abort)
            emit 'Aborting install.\n'
            exit 1
            ;;
          *)
            emit 'Proceeding without PHP dev tools.\n'
            break
            ;;
        esac
      done

      if [ "$composer_succeeded" -eq 1 ]; then
        emit 'Dependencies installed.\n'
      else
        php_deps_failed=1
      fi
    fi
  fi
fi

script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
if [[ "$script_path" == */.ddev/dcq-install.sh ]]; then
  rm -f "$script_path"
fi

emit '\n==> Phase 2: Copy Drupal.org GitLab CI template configs and shims\n'
emit 'This will copy config files into the project root and install shims under %s.\n' "$shim_dir_env"
phpstan_updated=0
copy_changed=0
copy_skipped=0
copy_unchanged=0
phase2_changed_root_configs=()
phase2_skipped_root_configs=()
phase2_unchanged_root_configs=()
phase2_changed_ddev_files=0
phase2_skipped_ddev_files=0
phase2_unchanged_ddev_files=0
phase2_changed_shims=0
phase2_skipped_shims=0
phase2_unchanged_shims=0


# Copy add-on assets/shims into project, respecting conflict handling mode.
while IFS= read -r -d '' source; do
  rel="${source#$addon_root/}"
  if [[ "$rel" == ide-settings/* ]]; then
    continue
  fi
  if [[ "$rel" == tooling/scripts/* ]]; then
    continue
  fi
  if [[ "$rel" == config-amendments/* ]]; then
    continue
  fi
  if [[ "$rel" == assets/dcq-packages.json ]]; then
    continue
  fi
  is_shim=0
  if [[ "$rel" == tooling/bin/* ]]; then
    target="${shim_dir%/}/${rel#tooling/bin/}"
    is_shim=1
  elif [[ "$rel" == assets/* ]]; then
    target="${app_root%/}/${rel#assets/}"
  else
    continue
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/dcq-src-XXXXXX")"
  if [ "$is_shim" -eq 1 ]; then
    cat "$source" >"$tmp"
  else
    strip_generated_header "$source" "$tmp"
    rewrite_docroot_config "$source" "$tmp"
  fi
  target_rel="${target#${app_root%/}/}"
  is_root_config=0
  if [ "$is_shim" -eq 0 ] && [ "$(dirname "$target")" = "${app_root%/}" ]; then
    is_root_config=1
  fi
  is_ddev_file=0
  if [ "$is_shim" -eq 0 ] && [[ "$target_rel" == .ddev/* ]]; then
    is_ddev_file=1
  fi

  if [ -e "$target" ]; then
    if cmp -s "$target" "$tmp"; then
      if [ "$is_shim" -eq 1 ]; then
        phase2_unchanged_shims=$((phase2_unchanged_shims + 1))
      elif [ "$is_root_config" -eq 1 ]; then
        phase2_unchanged_root_configs+=("$target_rel")
      elif [ "$is_ddev_file" -eq 1 ]; then
        phase2_unchanged_ddev_files=$((phase2_unchanged_ddev_files + 1))
      fi
      emit_copy 'OK: %s already matches.\n' "$target"
      copy_unchanged=$((copy_unchanged + 1))
      rm -f "$tmp"
      continue
    fi

    if [ "$skip_all" -eq 1 ]; then
      if [ "$is_shim" -eq 1 ]; then
        phase2_skipped_shims=$((phase2_skipped_shims + 1))
      elif [ "$is_root_config" -eq 1 ]; then
        phase2_skipped_root_configs+=("$target_rel")
      elif [ "$is_ddev_file" -eq 1 ]; then
        phase2_skipped_ddev_files=$((phase2_skipped_ddev_files + 1))
      fi
      emit_copy 'SKIP: %s (existing file).\n' "$target"
      copy_skipped=$((copy_skipped + 1))
      rm -f "$tmp"
      continue
    fi

    if [ "$replace_all" -eq 1 ]; then
      backup="$(backup_file "$target")"
      emit_copy 'BACKUP: %s\n' "$backup"
    elif [ "$abort_on_conflict" -eq 1 ]; then
      printf 'ABORT: conflict at %s.\n' "$target" >&2
      rm -f "$tmp"
      exit 1
    else
      show_diff "$target" "$tmp"
      prompt_choice "$target" "true"
      choice="${PROMPT_CHOICE_RESULT:-s}"
      choice="$(string_lower "$choice")"
      choice="$(printf '%s' "$choice" | tr -s ' ')"
      case "$choice" in
        r|replace)
          backup="$(backup_file "$target")"
          emit_copy 'BACKUP: %s\n' "$backup"
          ;;
        s|skip)
          if [ "$is_shim" -eq 1 ]; then
            phase2_skipped_shims=$((phase2_skipped_shims + 1))
          elif [ "$is_root_config" -eq 1 ]; then
            phase2_skipped_root_configs+=("$target_rel")
          elif [ "$is_ddev_file" -eq 1 ]; then
            phase2_skipped_ddev_files=$((phase2_skipped_ddev_files + 1))
          fi
          emit_copy 'SKIP: %s (existing file).\n' "$target"
          copy_skipped=$((copy_skipped + 1))
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
          emit_copy 'BACKUP: %s\n' "$backup"
          ;;
        sa|sall|"skip all")
          skip_all=1
          if [ "$is_shim" -eq 1 ]; then
            phase2_skipped_shims=$((phase2_skipped_shims + 1))
          elif [ "$is_root_config" -eq 1 ]; then
            phase2_skipped_root_configs+=("$target_rel")
          elif [ "$is_ddev_file" -eq 1 ]; then
            phase2_skipped_ddev_files=$((phase2_skipped_ddev_files + 1))
          fi
          emit_copy 'SKIP: %s (existing file).\n' "$target"
          copy_skipped=$((copy_skipped + 1))
          rm -f "$tmp"
          continue
          ;;
        *)
          if [ "$is_shim" -eq 1 ]; then
            phase2_skipped_shims=$((phase2_skipped_shims + 1))
          elif [ "$is_root_config" -eq 1 ]; then
            phase2_skipped_root_configs+=("$target_rel")
          elif [ "$is_ddev_file" -eq 1 ]; then
            phase2_skipped_ddev_files=$((phase2_skipped_ddev_files + 1))
          fi
          emit_copy 'Unknown choice. Skipping %s.\n' "$target"
          copy_skipped=$((copy_skipped + 1))
          rm -f "$tmp"
          continue
          ;;
      esac
    fi
  fi

  ensure_dir "$(dirname "$target")"
  cat "$tmp" >"$target"
  rm -f "$tmp"

  # Merge phpstan.dcq.neon into phpstan.neon if this is the phpstan config
  if [ "$target" = "${app_root%/}/phpstan.neon" ]; then
    phpstan_dcq_source="${addon_root}/config-amendments/phpstan.dcq.neon"
    merge_phpstan_config "$source" "$phpstan_dcq_source" "$target"
    ensure_phpstan_paths "$app_root"
    phpstan_updated=1
  fi

  # Merge .phpcs.dcq.xml into .phpcs.xml if this is the phpcs config
  if [ "$target" = "${app_root%/}/.phpcs.xml" ]; then
    phpcs_dcq_source="${addon_root}/config-amendments/.phpcs.dcq.xml"
    merge_phpcs_config "$source" "$phpcs_dcq_source" "$target"
  fi

  if [ -x "$source" ] || [[ "$target" == "$shim_dir"* ]]; then
    chmod 0755 "$target" || true
  fi
  if [ "$is_shim" -eq 1 ]; then
    phase2_changed_shims=$((phase2_changed_shims + 1))
  elif [ "$is_root_config" -eq 1 ]; then
    phase2_changed_root_configs+=("$target_rel")
  elif [ "$is_ddev_file" -eq 1 ]; then
    phase2_changed_ddev_files=$((phase2_changed_ddev_files + 1))
  fi
  emit_copy 'WRITE: %s\n' "$target"
  copy_changed=$((copy_changed + 1))
done < <(find "$addon_root" -type f -print0)

# Append DCQ scope defaults to the project prettier ignore file.
append_unique_lines_from_file \
  "${app_root%/}/.prettierignore" \
  "${addon_root}/config-amendments/.prettierignore.dcq"

# Merge stylelint DCQ amendments (runs post-loop so it applies even when the
# base config was unchanged and skipped by the copy loop).
if [ -f "${app_root%/}/.stylelintrc.json" ]; then
  stylelint_dcq_source="${addon_root}/config-amendments/.stylelintrc.dcq.json"
  merge_stylelint_config "$stylelint_dcq_source" "${app_root%/}/.stylelintrc.json"
fi

# Clean up dcq-packages.json from project root if left by a prior install.
if [ -f "${app_root%/}/dcq-packages.json" ]; then
  rm -f "${app_root%/}/dcq-packages.json"
fi

if [ "$copy_changed" -eq 0 ] && [ "$copy_skipped" -eq 0 ]; then
  emit 'All files already match; no changes.\n'
else
  emit 'Done. Changed: %s, skipped: %s, unchanged: %s.\n' "$copy_changed" "$copy_skipped" "$copy_unchanged"
fi

if [ "${#phase2_changed_root_configs[@]}" -gt 0 ]; then
  emit 'Project root tooling configs updated (%s):\n' "${#phase2_changed_root_configs[@]}"
  emit_unique_path_list "${phase2_changed_root_configs[@]}"
elif [ "${#phase2_unchanged_root_configs[@]}" -gt 0 ] || [ "${#phase2_skipped_root_configs[@]}" -gt 0 ]; then
  emit 'Project root tooling configs updated (0).\n'
fi
if [ "${#phase2_skipped_root_configs[@]}" -gt 0 ]; then
  emit 'Project root tooling configs skipped (%s):\n' "${#phase2_skipped_root_configs[@]}"
  emit_unique_path_list "${phase2_skipped_root_configs[@]}"
fi

if [ $((phase2_changed_ddev_files + phase2_skipped_ddev_files)) -gt 0 ]; then
  emit 'DDEV command/config files: %s updated, %s skipped, %s unchanged.\n' "$phase2_changed_ddev_files" "$phase2_skipped_ddev_files" "$phase2_unchanged_ddev_files"
fi
if [ $((phase2_changed_shims + phase2_skipped_shims)) -gt 0 ]; then
  emit 'Host shim wrappers under %s: %s updated, %s skipped, %s unchanged.\n' "$shim_dir_env" "$phase2_changed_shims" "$phase2_skipped_shims" "$phase2_unchanged_shims"
fi

if [ "$phpstan_updated" -eq 1 ]; then
  prompt_phpstan_level "$app_root"
fi

project_cspell_words="${app_root%/}/.cspell-project-words.txt"
if [ ! -f "$project_cspell_words" ]; then
  printf '# Project-specific CSpell words (managed via ddev cspell-suggest).\n' > "$project_cspell_words"
  emit_copy 'WRITE: %s\n' "$project_cspell_words"
fi

# Expand CSpell configuration with project-specific settings
expand_cspell_config "$app_root"

scss_detected="false"
scss_install_scss="false"

emit '\n==> Phase 3: JS toolchain dependencies\n'
core_package_json="${app_root%/}/${DCQ_DOCROOT}/core/package.json"
core_package_json_present=0
if [ -f "$core_package_json" ]; then
  core_package_json_present=1
elif command_available "${DDEV_EXECUTABLE:-ddev}"; then
  ddev_cmd="${DDEV_EXECUTABLE:-ddev}"
  attempts=0
  while [ "$attempts" -lt 5 ]; do
    if "$ddev_cmd" exec test -f "/var/www/html/${DCQ_DOCROOT}/core/package.json" >/dev/null 2>&1; then
      core_package_json_present=1
      break
    fi
    attempts=$((attempts + 1))
    sleep 1
  done
  if [ "$core_package_json_present" -eq 0 ]; then
    emit 'Core package.json not detected in container after waiting; skipping JS toolchain install.\n'
  fi
fi

if [ "$core_package_json_present" -eq 1 ]; then
  # Check DDEV Node.js version before proceeding with JS toolchain setup.
  ddev_config="${app_root%/}/.ddev/config.yaml"
  if ! check_nodejs_version "$ddev_config"; then
    prompt_nodejs_version_action "$NODEJS_DETECTED_VERSION" "$non_interactive"
    case "$NODE_VERSION_ACTION" in
      abort)
        emit 'Aborting installer. Fix your Node.js version, then re-run the add-on install.\n'
        exit 0
        ;;
      skip)
        emit 'Skipping JS toolchain install (Node.js too old). PHP tooling is still available.\n'
        core_package_json_present=0
        ;;
    esac
  fi
fi

if [ "$core_package_json_present" -eq 1 ]; then
  node_mode_raw="$(string_lower "${DCQ_INSTALL_NODE_DEPS:-}")"
  node_toolchain_existing=0
  if node_toolchain_present "$app_root"; then
    node_toolchain_existing=1
  fi
  skip_due_to_existing_toolchain=0
  if [ -z "$node_mode_raw" ] && [ "$node_toolchain_existing" -eq 1 ]; then
    node_mode_raw="skip"
    skip_due_to_existing_toolchain=1
  fi

  # Detect legacy core-only installs that need migration to project root.
  if [ -z "$node_mode_raw" ] && [ "$node_toolchain_existing" -eq 0 ]; then
    core_dir="${DCQ_DOCROOT}/core"
    legacy_core_nm="${app_root}/${core_dir}/node_modules"
    if [ -e "${legacy_core_nm}/.bin/eslint" ] || \
       [ -e "${legacy_core_nm}/eslint/bin/eslint.js" ]; then
      emit 'Legacy core-only Node toolchain detected. The add-on now requires tooling at the project root.\n'
      if [ "$non_interactive" -eq 1 ]; then
        node_mode_raw="root"
      fi
    fi
  fi

  if [ "$node_mode_raw" != "skip" ] || [ "$skip_due_to_existing_toolchain" -eq 1 ]; then
    ddev_cmd="${DDEV_EXECUTABLE:-ddev}"
    root_package_json="${app_root%/}/package.json"
    has_root_package_json=0
    if [ -f "$root_package_json" ]; then
      has_root_package_json=1
    fi
    if [ "$skip_due_to_existing_toolchain" -eq 1 ] && [ "$has_root_package_json" -eq 1 ]; then
      if ! command_available "$ddev_cmd"; then
        emit 'ddev executable not found in PATH; skipping Node dependency check.\n'
      else
        root_pm="$(detect_package_manager "$app_root")"
        if [ "$root_pm" = "yarn" ]; then
          ensure_root_yarnrc "$app_root"
        fi
        maybe_install_missing_root_deps "$ddev_cmd" "$non_interactive" "$root_pm" 0 0 || true
      fi
    fi
    if [ "$node_mode_raw" = "skip" ]; then
      emit 'Skipping Node toolchain install. Use DCQ_INSTALL_NODE_DEPS=root to enable later.\n'
      node_mode="skip"
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
    else
      emit 'Unknown DCQ_INSTALL_NODE_DEPS value "%s"; skipping Node toolchain install.\n' "$node_mode_raw"
      node_mode="skip"
    fi

    root_auto_add=0
    root_suppress_list=0
    if [ "$node_mode" = "install" ] || [ "$node_mode" = "root" ]; then
      root_auto_add=1
    fi

    missing_node_deps=""
    if [ "$has_root_package_json" -eq 1 ] && command_available "$ddev_cmd"; then
      if missing_node_deps="$(find_missing_node_deps "$ddev_cmd")"; then
        :
      else
        emit 'Failed to compute missing Node deps.\n'
        missing_node_deps=""
      fi
    fi
    # Detect SCSS files before Node install so we can offer to set up support.
    scss_install_scss="false"
    if detect_scss_files "$app_root"; then
      # Check if SCSS support is already fully configured.
      # Both conditions must be true: a stylelint config references scss AND
      # the DDEV env var includes scss globs.
      scss_has_config=false
      scss_has_globs=false
      if find "$app_root" -maxdepth 4 \
           -type d \( -name node_modules -o -name vendor -o -name .git -o -name .ddev \) -prune \
           -o -name '.stylelintrc*' -type f -print0 2>/dev/null \
         | xargs -0 grep -lq 'scss' 2>/dev/null; then
        scss_has_config=true
      fi
      if grep -rlq 'DCQ_STYLELINT_GLOBS.*scss' "${app_root%/}/.ddev/"*.yaml 2>/dev/null; then
        scss_has_globs=true
      fi
      scss_already_configured=false
      if [ "$scss_has_config" = true ] && [ "$scss_has_globs" = true ]; then
        scss_already_configured=true
      fi

      if [ "$scss_already_configured" = true ]; then
        scss_detected="configured"
        emit 'SCSS files detected — SCSS support appears to be configured already.\n'
      elif [ "$non_interactive" -eq 0 ] && [ "$recommended_mode" -eq 0 ] && [ "${PROMPT_AVAILABLE:-0}" -eq 1 ]; then
        emit '\nYour project contains SCSS files, but Stylelint is currently configured\n'
        emit 'to check CSS only. Would you like to set up SCSS support? [Y/n] '
        scss_answer=""
        if IFS= read -r -u "$PROMPT_IN_FD" scss_answer; then
          scss_answer="$(printf '%s' "$scss_answer" | tr -d '\r\n')"
        fi
        if [ -z "$scss_answer" ] || [ "$scss_answer" = "y" ] || [ "$scss_answer" = "Y" ]; then
          scss_install_scss="true"
          scss_detected="pending"
        else
          scss_detected="declined"
        fi
      else
        scss_detected="true"
      fi
    fi

    if [ "$node_mode" != "skip" ]; then
      emit 'Preparing JS toolchain install.\n'
      if ! command_available "$ddev_cmd"; then
        emit 'ddev executable not found in PATH; skipping Node toolchain install.\n'
        node_mode="skip"
      fi

      target="skip"
      if [ "$node_mode" = "install" ]; then
        target="root"
      elif [ "$node_mode" = "root" ]; then
        target="$node_mode"
      elif [ "$node_mode" = "prompt" ]; then
        root_pm="$(detect_package_manager "$app_root")"
        prompt_node_install_action "$has_root_package_json" "$missing_node_deps"
        node_action="${NODE_INSTALL_ACTION:-install}"
        # Defensively normalize the prompt result to avoid silent fall-through.
        node_action="${node_action//$'\r'/}"
        node_action="${node_action//$'\n'/}"
        node_action="$(printf '%s' "$node_action" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        case "$node_action" in
          install)
            target="root"
            root_auto_add=1
            root_suppress_list=1
            ;;
          skip)
            emit_node_install_command "$root_pm" "$missing_node_deps" "$has_root_package_json"
            target="skip"
            ;;
        esac
      fi

      if [ "$target" = "root" ] && [ "$has_root_package_json" -eq 0 ]; then
        if ! create_root_package_json "$ddev_cmd" "$app_root"; then
          emit 'Failed to create a project-root package.json; skipping Node toolchain install.\n'
          target="skip"
        else
          has_root_package_json=1
        fi
      fi

      if [ "$target" = "root" ]; then
        node_target_choice="$target"
      fi

      # Offer to add engines.node to existing package.json before installing.
      if [ "$target" = "root" ] && [ "$has_root_package_json" -eq 1 ]; then
        maybe_add_engines_node "$app_root" "$non_interactive"
      fi

      node_install_done=0
      if [ "$target" = "root" ]; then
        if [ "$has_root_package_json" -eq 1 ]; then
          root_pm="$(detect_package_manager "$app_root")"
          if [ "$root_pm" = "yarn" ]; then
            ensure_root_yarnrc "$app_root"
          fi
          if maybe_install_missing_root_deps "$ddev_cmd" "$non_interactive" "$root_pm" "$root_auto_add" "$root_suppress_list"; then
            node_install_done=1
          fi
        fi
        if [ "$node_install_done" -eq 0 ]; then
          if [ -z "${root_pm:-}" ]; then
            root_pm="$(detect_package_manager "$app_root")"
            if [ "$root_pm" = "yarn" ]; then
              ensure_root_yarnrc "$app_root"
            fi
          fi
          emit 'Installing JS deps in project root using %s (this may take several minutes).\n' "${root_pm:-npm}"
          if [ "${root_pm:-npm}" = "npm" ]; then
            cmd=( "$ddev_cmd" "npm" "install" )
          else
            cmd=( "$ddev_cmd" "yarn" "install" )
          fi
          if run_command "${cmd[@]}"; then
            node_install_done=1
          else
            emit 'JS dependency install failed. You can retry manually:\n'
            emit '  ddev %s install\n' "${root_pm:-npm}"
            emit_dcq_package_list "${root_pm:-npm}"
          fi
        fi
        if [ "$node_install_done" -eq 1 ]; then
          emit 'Node toolchain installed (project root).\n'
        fi
      fi
    fi
  fi
fi

# If user accepted SCSS support, write the SCSS globs to the add-on config.
# The package install command and config change are shown in the summary
# so the user can see them all together and handle version conflicts.
if [ "$scss_install_scss" = "true" ]; then
  dcq_config="${app_root%/}/.ddev/config.drupal-code-quality.yaml"
  cat > "$dcq_config" <<'DCQYAML'
# Drupal Code Quality add-on configuration.
web_environment:
  - "DCQ_STYLELINT_GLOBS=**/*.css **/*.scss"
DCQYAML
  emit 'Updated .ddev/config.drupal-code-quality.yaml with SCSS globs.\n'
  emit 'Note: there are manual steps to complete after install — look for the\n'
  emit 'SCSS instructions in the install summary at the end.\n'
  if [ "${PROMPT_AVAILABLE:-0}" -eq 1 ]; then
    emit 'Press Enter to continue...'
    IFS= read -r -u "$PROMPT_IN_FD" _ || true
  fi
  scss_detected="accepted"
fi

emit '\n==> Optional: .gitignore update\n'
maybe_add_gitignore_reports "$app_root" "${DCQ_INSTALL_GITIGNORE:-}"

ide_settings_root="${addon_root}/ide-settings/vscode"
ide_settings_template="${ide_settings_root}/settings.json"
ide_extensions_template="${ide_settings_root}/extensions.json"
ide_settings_doc="${ide_settings_root}/README.md"
if [ -f "$ide_settings_template" ] || [ -f "$ide_extensions_template" ]; then
  emit '\n==> Phase 4: IDE settings\n'
  ide_mode_raw="$(string_lower "${DCQ_INSTALL_IDE_SETTINGS:-}")"
  if [ "$ide_mode_raw" = "merge" ] || [ "$ide_mode_raw" = "m" ]; then
    ide_mode="merge"
  elif [ "$ide_mode_raw" = "overwrite" ] || [ "$ide_mode_raw" = "replace" ] || [ "$ide_mode_raw" = "o" ]; then
    ide_mode="overwrite"
  elif [ "$ide_mode_raw" = "manual" ] || [ "$ide_mode_raw" = "skip" ] || [ "$ide_mode_raw" = "s" ]; then
    ide_mode="skip"
  elif [ -z "$ide_mode_raw" ]; then
    if [ "$non_interactive" -eq 1 ]; then
      ide_mode="merge"
    else
      ide_mode="prompt"
    fi
  else
    # Unrecognized values fall back to merge for backwards compatibility.
    ide_mode="merge"
  fi

  if [ "$ide_mode" = "prompt" ]; then
    emit 'VS Code/Codium settings/extensions: choose merge, overwrite (with backup), or skip.\n'
    printf '\n'
    prompt_ide_settings_mode
    ide_mode="${PROMPT_IDE_MODE_RESULT:-skip}"
  fi

  if [ "$ide_mode" = "skip" ]; then
    emit 'Skipping IDE settings/extensions install. See %s for manual setup.\n' "$ide_settings_doc"
  else
    ide_target_dir="${app_root%/}/.vscode"
    ide_target_settings="${ide_target_dir}/settings.json"
    ide_target_extensions="${ide_target_dir}/extensions.json"

    if [ -f "$ide_settings_template" ]; then
      ide_tmp="$(mktemp "${TMPDIR:-/tmp}/dcq-ide-XXXXXX")"

      shim_setting="$shim_dir_env"
      ide_node_mode=""
      ide_node_mode_raw="$(string_lower "${DCQ_INSTALL_NODE_DEPS:-}")"
      has_root_node_modules=0
      if [ -d "${app_root%/}/node_modules" ]; then
        has_root_node_modules=1
      fi

      if [ -n "$node_target_choice" ]; then
        ide_node_mode="$node_target_choice"
      else
        case "$ide_node_mode_raw" in
          root|project|1|true|yes|on|install|auto) ide_node_mode="root" ;;
        esac
      fi

      if [ -z "$ide_node_mode" ] && [ "$has_root_node_modules" -eq 1 ]; then
        ide_node_mode="root"
      fi

      # Re-check for node_modules after installation (may have been installed in Phase 3)
      if [ "$has_root_node_modules" -eq 0 ]; then
        if [ -d "${app_root%/}/node_modules" ]; then
          has_root_node_modules=1
        elif command_available "${DDEV_EXECUTABLE:-ddev}"; then
          ddev_cmd="${DDEV_EXECUTABLE:-ddev}"
          if "$ddev_cmd" exec test -d "/var/www/html/node_modules" >/dev/null 2>&1; then
            has_root_node_modules=1
          fi
        fi
        if [ "$has_root_node_modules" -eq 1 ] && [ -z "$ide_node_mode" ]; then
          ide_node_mode="root"
        fi
      fi

      ide_js_paths_set=0
      js_modules=""
      eslint_node_path=""
      eslint_resolve_plugins=""
      eslint_quiet="$(resolve_eslint_quiet_setting "$app_root")"
      if [ "$ide_node_mode" = "root" ] && [ "$has_root_node_modules" -eq 1 ]; then
        js_modules="./node_modules"
        eslint_node_path="node_modules"
        eslint_resolve_plugins="."
        ide_js_paths_set=1
      fi

      stylelint_path=""
      prettier_path=""
      if [ "$ide_js_paths_set" -eq 1 ]; then
        stylelint_path="${js_modules}/stylelint"
        prettier_path="${js_modules}/prettier"
      fi

      render_ide_template "$ide_settings_template" "$ide_tmp" "$shim_setting" \
        "$stylelint_path" "$prettier_path" "$eslint_node_path" "$eslint_resolve_plugins" "$eslint_quiet"
      if [ "$ide_js_paths_set" -eq 0 ]; then
        strip_ide_js_settings "$ide_tmp" || true
        emit 'JS tool paths not configured (node_modules missing). Install JS deps and re-run the installer or update settings manually.\n'
      fi

      if [ "$ide_mode" = "merge" ] && [ -f "$ide_target_settings" ]; then
        merge_tmp="$(mktemp "${TMPDIR:-/tmp}/dcq-ide-merge-XXXXXX")"
        if merge_json_settings "$ide_target_settings" "$ide_tmp" "$merge_tmp"; then
          backup="$(backup_file "$ide_target_settings")"
          printf 'BACKUP: %s\n' "$backup"
          cat "$merge_tmp" >"$ide_target_settings"
          printf 'MERGE: %s\n' "$ide_target_settings"
        else
          merge_status=$?
          if [ "$merge_status" -eq 3 ]; then
            printf 'OK: %s already includes DCQ settings.\n' "$ide_target_settings"
          else
            emit 'Unable to merge IDE settings; install manually from %s.\n' "$ide_settings_doc"
          fi
        fi
        rm -f "$merge_tmp"
      else
        ensure_dir "$ide_target_dir"
        if [ -f "$ide_target_settings" ]; then
          backup="$(backup_file "$ide_target_settings")"
          printf 'BACKUP: %s\n' "$backup"
        fi
        cat "$ide_tmp" >"$ide_target_settings"
        printf 'WRITE: %s\n' "$ide_target_settings"
      fi

      rm -f "$ide_tmp"
    fi

    if [ -f "$ide_extensions_template" ]; then
      if [ "$ide_mode" = "merge" ] && [ -f "$ide_target_extensions" ]; then
        merge_tmp="$(mktemp "${TMPDIR:-/tmp}/dcq-ide-merge-XXXXXX")"
        if merge_json_extensions "$ide_target_extensions" "$ide_extensions_template" "$merge_tmp"; then
          backup="$(backup_file "$ide_target_extensions")"
          printf 'BACKUP: %s\n' "$backup"
          cat "$merge_tmp" >"$ide_target_extensions"
          printf 'MERGE: %s\n' "$ide_target_extensions"
        else
          merge_status=$?
          if [ "$merge_status" -eq 3 ]; then
            printf 'OK: %s already includes DCQ extensions.\n' "$ide_target_extensions"
          else
            emit 'Unable to merge IDE extensions; install manually from %s.\n' "$ide_settings_doc"
          fi
        fi
        rm -f "$merge_tmp"
      else
        ensure_dir "$ide_target_dir"
        if [ -f "$ide_target_extensions" ]; then
          backup="$(backup_file "$ide_target_extensions")"
          printf 'BACKUP: %s\n' "$backup"
        fi
        strip_generated_header "$ide_extensions_template" "$ide_target_extensions"
        printf 'WRITE: %s\n' "$ide_target_extensions"
      fi
    fi
  fi
fi

print_install_summary() {
  local php_deps_status="$1"
  local node_status="$2"
  local ide_status="$3"
  local configs_count="$4"
  local has_scss="$5"
  local pkg_mgr="${6:-npm}"

  emit '\n'
  emit '===============================================================\n'
  emit '  Installation Complete\n'
  emit '===============================================================\n'
  emit '\n'
  emit 'What was installed:\n'
  emit '  - GitLab CI template configs (%s files) and DDEV commands\n' "$configs_count"
  emit '  - Host shims for IDE integration\n'

  if [ "$php_deps_status" = "installed" ]; then
    emit '  - PHP dev tools (PHPStan, PHPCS, etc.)\n'
  elif [ "$php_deps_status" = "present" ]; then
    emit '  - PHP dev tools: already present (skipped)\n'
  elif [ "$php_deps_status" = "failed" ]; then
    emit '  - PHP dev tools: FAILED (see warning below)\n'
  else
    emit '  - PHP dev tools: NOT installed\n'
  fi

  if [ "$node_status" = "root" ]; then
    emit '  - Node toolchain (ESLint, Prettier, Stylelint)\n'
  elif [ "$node_status" = "present" ]; then
    emit '  - Node toolchain: already present (skipped)\n'
  else
    emit '  - Node toolchain: NOT installed\n'
  fi

  if [ "$ide_status" = "merge" ] || [ "$ide_status" = "overwrite" ]; then
    emit '  - VS Code settings\n'
  else
    emit '  - VS Code settings: NOT installed\n'
  fi

  emit '\n'
  emit 'Next steps:\n'
  local step_num=1

  if [ "$php_deps_status" = "failed" ]; then
    emit '  %s. FIX: PHP dev tools failed to install. Resolve the composer issue\n' "$step_num"
    emit '     (see error output above), then run:\n'
    emit '     ddev composer require --dev drupal/core-dev --with-all-dependencies\n'
    step_num=$((step_num + 1))
  elif [ "$php_deps_status" != "installed" ] && [ "$php_deps_status" != "present" ]; then
    emit '  %s. Install PHP tools: ddev composer require --dev drupal/core-dev\n' "$step_num"
    step_num=$((step_num + 1))
  fi

  if [ "$node_status" != "root" ] && [ "$node_status" != "present" ]; then
    emit '  %s. Install Node tools:\n' "$step_num"
    emit_dcq_package_list "$pkg_mgr"
    step_num=$((step_num + 1))
  fi

  emit '  %s. Run quality checks: ddev checks\n' "$step_num"
  step_num=$((step_num + 1))

  if [ "$ide_status" = "skip" ]; then
    emit '  %s. Setup VS Code: see .ddev/drupal-code-quality/ide-settings/vscode/README.md\n' "$step_num"
  fi

  local scss_install_cmd
  if [ "$pkg_mgr" = "yarn" ]; then
    scss_install_cmd="ddev yarn add --dev stylelint-config-standard-scss"
  else
    scss_install_cmd="ddev npm install --save-dev stylelint-config-standard-scss"
  fi

  if [ "$has_scss" = "accepted" ]; then
    emit '\n'
    emit 'SCSS Setup (complete these steps to finish):\n'
    emit '  a. Install the SCSS config package:\n'
    emit '       %s\n' "$scss_install_cmd"
    emit '  b. Update .stylelintrc.json — replace "stylelint-config-standard" with\n'
    emit '     "stylelint-config-standard-scss" in the "extends" array.\n'
    emit '  c. Run: ddev restart\n'
    emit '  (SCSS scan globs have already been configured in\n'
    emit '   .ddev/config.drupal-code-quality.yaml)\n'
  elif [ "$has_scss" = "true" ] || [ "$has_scss" = "declined" ]; then
    emit '\n'
    if [ "$has_scss" = "declined" ]; then
      emit 'SCSS support was not installed. Stylelint will only check CSS files.\n'
    else
      emit 'SCSS files were detected but SCSS support was not configured.\n'
      emit 'Stylelint will only check CSS files.\n'
    fi
    emit 'To enable SCSS linting later:\n'
    emit '  - Re-run the installer interactively and accept SCSS setup, or:\n'
    emit '  a. Install the SCSS config package:\n'
    emit '       %s\n' "$scss_install_cmd"
    emit '  b. Update .stylelintrc.json — replace "stylelint-config-standard" with\n'
    emit '     "stylelint-config-standard-scss" in the "extends" array.\n'
    emit '  c. In .ddev/config.drupal-code-quality.yaml, uncomment and update the\n'
    emit '     DCQ_STYLELINT_GLOBS line under web_environment:\n'
    emit '       - "DCQ_STYLELINT_GLOBS=**/*.css **/*.scss"\n'
    emit '  d. Run: ddev restart\n'
  fi

  emit '\n'
  emit 'More info: https://github.com/UltraBob/ddev-drupal-code-quality\n'
  emit '===============================================================\n'
}

# Determine summary statuses — report actual state, not just what this run did.
php_deps_summary="skipped"
if [ "${php_deps_failed:-0}" -eq 1 ]; then
  php_deps_summary="failed"
elif [ "${should_install:-0}" -eq 1 ]; then
  php_deps_summary="installed"
fi
# Check if tools are actually present regardless of what happened in this run.
if [ "$php_deps_summary" = "skipped" ]; then
  _all_php_present=1
  for _tool in phpstan phpcs phpcbf; do
    if [ ! -e "${vendor_bin}/${_tool}" ]; then _all_php_present=0; break; fi
  done
  if [ "$_all_php_present" -eq 1 ]; then
    php_deps_summary="present"
  fi
fi

node_summary="skipped"
if [ -n "${node_target_choice:-}" ] && [ "$node_target_choice" = "root" ]; then
  node_summary="root"
fi
# Check if Node toolchain is actually present regardless of what happened in this run.
if [ "$node_summary" = "skipped" ] && node_toolchain_present "$app_root"; then
  node_summary="present"
fi

ide_summary="${ide_mode:-skip}"

configs_copied="${copy_changed:-0}"

# Detect SCSS if not already done during Node deps phase (e.g. Node was skipped).
if [ "$scss_detected" = "false" ] && detect_scss_files "$app_root"; then
  # Check if SCSS support is already fully configured (both config and globs).
  scss_has_config=false
  scss_has_globs=false
  if find "$app_root" -maxdepth 4 \
       -type d \( -name node_modules -o -name vendor -o -name .git -o -name .ddev \) -prune \
       -o -name '.stylelintrc*' -type f -print0 2>/dev/null \
     | xargs -0 grep -lq 'scss' 2>/dev/null; then
    scss_has_config=true
  fi
  if grep -rlq 'DCQ_STYLELINT_GLOBS.*scss' "${app_root%/}/.ddev/"*.yaml 2>/dev/null; then
    scss_has_globs=true
  fi
  if [ "$scss_has_config" = true ] && [ "$scss_has_globs" = true ]; then
    scss_detected="configured"
  else
    scss_detected="true"
  fi
fi

print_install_summary "$php_deps_summary" "$node_summary" "$ide_summary" "$configs_copied" "$scss_detected" "${root_pm:-npm}"
