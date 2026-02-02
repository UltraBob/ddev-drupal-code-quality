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

detect_docroot() {
  local config_path="$1"
  local value=""

  if [ -f "$config_path" ]; then
    value="$(awk -F: '/^[[:space:]]*docroot:/ {
      val=$2
      sub(/^[[:space:]]+/, "", val)
      sub(/[[:space:]]+$/, "", val)
      gsub(/^"|"$/, "", val)
      gsub(/^'\''|'\''$/, "", val)
      print val
      exit
    }' "$config_path")"
  fi

  value="${value#/}"
  value="${value%/}"
  if [ -z "$value" ]; then
    value="web"
  fi
  printf '%s' "$value"
}

prompt_setup() {
  # Detect a usable TTY for prompts. Falls back to /dev/tty when stdin/stdout
  # are redirected (e.g., running from automation).
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
    if exec 3</dev/tty 4>/dev/tty 2>/dev/null; then
      PROMPT_IN_FD=3
      PROMPT_OUT_FD=4
      PROMPT_AVAILABLE=1
    fi
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
  emit "$@"
}

prompt_choice() {
  # Conflict prompt for file installs; returns short choice code for callers.
  local path="$1"
  local warn_parity="$2"

  if [ "${PROMPT_AVAILABLE:-0}" -ne 1 ]; then
    printf 'No interactive terminal detected; skipping conflict prompt for %s (default: skip). Set DCQ_INSTALL_MODE=replace|skip|abort to control behavior.\n' "$path" >&2
    printf 's'
    return
  fi

  if [ "$warn_parity" = "true" ]; then
    printf 'Skipping this file may diverge from Drupal.org GitLab CI template defaults.\n' >&"$PROMPT_OUT_FD"
  fi
  printf '\n' >&"$PROMPT_OUT_FD"
  printf 'Conflict at %s. Choose: [r]eplace (backup), [s]kip, [a]bort, [ra] replace all, [sa] skip all (default: skip): ' "$path" >&"$PROMPT_OUT_FD"
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
  # Create a project-root package.json based on Drupal core's package.json.
  # Uses PHP inside the DDEV container to read core dependencies.
  local ddev_cmd="$1"
  local app_root="$2"
  local container_package_json="/var/www/html/package.json"
  local php_code
  local php_payload
  local output
  local status

  php_code=$(cat <<'PHP'
$path = "__DOCROOT_CORE__/package.json";
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
if (isset($data["dependencies"])) {
  $out["dependencies"] = $data["dependencies"];
}
if (isset($data["devDependencies"])) {
  $out["devDependencies"] = $data["devDependencies"];
}
echo json_encode($out, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL;
PHP
  )
  php_code="${php_code//__DOCROOT_CORE__/${DOCROOT_CORE}}"
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

  emit 'Created package.json from Drupal core devDependencies; review and customize as needed.\n'
  return 0
}

find_missing_node_deps() {
  # Determine missing JS tooling deps by comparing root package.json to
  # Drupal core + add-on config requirements (via a PHP helper in the container).
  local ddev_cmd="$1"
  local php_code
  local php_payload
  local output
  local status

  php_code=$(cat <<'PHP'
$rootPath = "/var/www/html/package.json";
$corePath = "__DOCROOT_CORE__/package.json";
$assetsRoot = "/var/www/html/.ddev/drupal-code-quality/assets";

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
$required = $coreDeps;

$basePackages = ["eslint", "prettier", "stylelint", "cspell"];
foreach ($basePackages as $pkg) {
  add_required($required, $pkg, $coreDeps);
}

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
  php_code="${php_code//__DOCROOT_CORE__/${DOCROOT_CORE}}"
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

  mapfile -t missing_node_deps_array <<< "$missing_node_deps"
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
      cmd=( "$ddev_cmd" "exec" "bash" "-lc" "cd /var/www/html && npm install --save-dev --package-lock${deps_cmd}" )
      run_command "${cmd[@]}"
      emit 'Node dependencies added (project root).\n'
      cmd=( "$ddev_cmd" "exec" "bash" "-lc" "cd /var/www/html && npm install --package-lock" )
      run_command "${cmd[@]}"
    else
      cmd=( "$ddev_cmd" "exec" "bash" "-lc" "cd /var/www/html && yarn add -D${deps_cmd}" )
      run_command "${cmd[@]}"
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

  if [ "${PROMPT_AVAILABLE:-0}" -ne 1 ]; then
    printf 'install'
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
  emit '[i]nstall these in the project root, [s]kip node module installation (default: install): '
  if ! IFS= read -r -u "$PROMPT_IN_FD" choice; then
    choice=""
  fi
  # Normalize prompt input to avoid silent fall-through on CR/LF/whitespace.
  choice="${choice//$'\r'/}"
  choice="${choice//$'\n'/}"
  choice="$(printf '%s' "$choice" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  choice="$(string_lower "$choice")"
  if [ -z "$choice" ]; then
    printf 'install'
    return
  fi

  case "$choice" in
    i|install) printf 'install' ;;
    s|skip) printf 'skip' ;;
    *) printf 'install' ;;
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
      cmd="ddev exec bash -lc \"cd /var/www/html && npm install --save-dev${deps_cmd}\""
    else
      cmd="ddev exec bash -lc \"cd /var/www/html && yarn add -D${deps_cmd}\""
    fi
  else
    if [ "$package_manager" = "npm" ]; then
      cmd="ddev exec bash -lc \"cd /var/www/html && npm install\""
    else
      cmd="ddev exec bash -lc \"cd /var/www/html && yarn install\""
    fi
  fi

  if [ "$has_root" -eq 0 ]; then
    emit 'No project package.json found. The install requires one at the project root.\n'
  fi
  emit 'Run:\n  %s\n' "$cmd"
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
  # Prompt for accepting recommended settings (default: no).
  if [ "${PROMPT_AVAILABLE:-0}" -ne 1 ]; then
    return 1
  fi

  printf 'Accept recommended settings? (y/N) ' >&"$PROMPT_OUT_FD"
  local answer=""
  if ! IFS= read -r -u "$PROMPT_IN_FD" answer; then
    answer=""
  fi
  answer="$(string_lower "$answer")"
  if [ -z "$answer" ]; then
    return 1
  fi
  case "$answer" in
    y|yes) return 0 ;;
  esac
  return 1
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
  # Prompt for IDE settings merge/overwrite/skip mode.
  local choice

  if [ "${PROMPT_AVAILABLE:-0}" -ne 1 ]; then
    printf 'skip'
    return
  fi

  printf 'VS Code/Codium settings/extensions: [m]erge, [o]verwrite (backup), [s]kip (default: skip): ' >&"$PROMPT_OUT_FD"
  if ! IFS= read -r -u "$PROMPT_IN_FD" choice; then
    choice=""
  fi
  choice="$(string_lower "$choice")"
  if [ -z "$choice" ]; then
    printf 'skip'
    return
  fi

  case "$choice" in
    m|merge) printf 'merge' ;;
    o|overwrite|replace) printf 'overwrite' ;;
    s|skip|manual) printf 'skip' ;;
    *) printf 'skip' ;;
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
  if [[ "$env_level" =~ ^[0-9]$ ]]; then
    if set_phpstan_level "$config_path" "$env_level"; then
      emit 'WRITE: %s (level %s)\n' "$config_path" "$env_level"
    else
      printf 'Unable to update phpstan.neon level.\n' >&2
    fi
  elif [ "$non_interactive" -eq 0 ] && [ "${PROMPT_AVAILABLE:-0}" -eq 1 ]; then
    # Interactive mode with invalid/missing level - prompt user
    printf '\n'
    emit 'Set phpstan.neon level (0-9) (default: 0): '
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
      if [[ "$answer" =~ ^[0-9]$ ]]; then
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
  case "$mode_raw" in
    1|true|yes|on|add|install|auto) mode="add" ;;
    0|false|no|off|skip) mode="skip" ;;
    *) mode="add" ;;  # Default is now set via set_default_env
  esac

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

  # mode should now be "add" due to set_default_env, unless explicitly overridden
  emit 'Add %s to .gitignore to avoid committing report logs.\n' "$entry"
  printf '\n'
  if [ "$mode" = "add" ] || prompt_yes_no "Add '${entry}' to .gitignore?" 1; then
    if [ -f "$gitignore" ]; then
      printf '\n%s\n' "$entry" >>"$gitignore"
    else
      printf '%s\n' "$entry" >"$gitignore"
    fi
    emit 'WRITE: %s\n' "$gitignore"
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

expand_cspell_config() {
  local app_root="$1"
  local ddev_approot="${DDEV_APPROOT:-$app_root}"
  local prepare_script="${ddev_approot}/.ddev/drupal-code-quality/tooling/scripts/prepare-cspell.php"
  local cspell_config="${app_root%/}/.cspell.json"


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
  if command_available "${DDEV_EXECUTABLE:-ddev}"; then
    emit 'Expanding .cspell.json with project-specific settings...\n'
    local ddev_cmd="${DDEV_EXECUTABLE:-ddev}"

    # Copy prepare-cspell.php to project root for execution
    local project_script="${app_root%/}/.prepare-cspell-tmp.php"
    cp "$prepare_script" "$project_script" || {
      emit 'Failed to copy prepare-cspell.php; skipping expansion.\n'
      return 0
    }

    # Run the script in container from project root
    # Capture both stdout and stderr, but don't fail the installer if it errors
    # Pass the docroot via _WEB_ROOT environment variable
    local output
    if output=$("$ddev_cmd" exec bash -c "export _WEB_ROOT='${DCQ_DOCROOT:-web}' && php .prepare-cspell-tmp.php" 2>&1); then
      if echo "$output" | grep -q "Writing json"; then
        emit 'Successfully expanded .cspell.json\n'
      else
        emit 'CSpell expansion completed (no changes needed)\n'
      fi
    else
      # Script failed - likely no Drupal core installed yet
      emit 'Skipping CSpell expansion (Drupal core may not be installed yet)\n'
    fi

    # Clean up temp script
    rm -f "$project_script"
  else
    emit 'DDEV not available; skipping CSpell expansion.\n'
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

render_ide_template() {
  # Render IDE settings template with resolved shim and tool paths.
  local template="$1"
  local output="$2"
  local shim_setting="$3"
  local stylelint_path="$4"
  local prettier_path="$5"
  local eslint_node_path="$6"
  local eslint_resolve_plugins="$7"
  local escaped_shim
  local escaped_stylelint
  local escaped_prettier
  local escaped_node_path
  local escaped_resolve_plugins

  escaped_shim="$(escape_sed_replacement "$shim_setting")"
  escaped_stylelint="$(escape_sed_replacement "$stylelint_path")"
  escaped_prettier="$(escape_sed_replacement "$prettier_path")"
  escaped_node_path="$(escape_sed_replacement "$eslint_node_path")"
  escaped_resolve_plugins="$(escape_sed_replacement "$eslint_resolve_plugins")"

  sed \
    -e '1{/^#ddev-generated$/d;}' \
    -e "s|__DCQ_SHIM_DIR__|${escaped_shim}|g" \
    -e "s|__DCQ_STYLELINT_PATH__|${escaped_stylelint}|g" \
    -e "s|__DCQ_PRETTIER_PATH__|${escaped_prettier}|g" \
    -e "s|__DCQ_ESLINT_NODE_PATH__|${escaped_node_path}|g" \
    -e "s|__DCQ_ESLINT_RESOLVE_PLUGINS__|${escaped_resolve_plugins}|g" \
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

  if ! "$python_bin" - "$existing" "$template" "$dest" <<'PY'
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
  then
    return 1
  fi
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

  if ! "$python_bin" - "$existing" "$template" "$dest" <<'PY'
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
  then
    return 1
  fi
}

node_toolchain_present() {
  # Detect installed eslint tooling in either root or core node_modules.
  local app_root="$1"
  local paths=(
    "$app_root/${DCQ_DOCROOT}/core/node_modules/.bin/eslint"
    "$app_root/${DCQ_DOCROOT}/core/node_modules/eslint/bin/eslint.js"
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
  # Echo and execute a command (simple transparency for users).
  local arg
  emit 'Running:'
  for arg in "$@"; do
    emit ' %q' "$arg"
  done
  emit '\n'
  if [ "${non_interactive:-0}" -eq 1 ] || [ "${PROMPT_AVAILABLE:-0}" -ne 1 ]; then
    "$@"
  else
    "$@" >&"$PROMPT_OUT_FD"
  fi
}

prompt_setup


cwd="$(pwd)"
app_root="${DDEV_APPROOT:-}"
if [ -z "$app_root" ]; then
  app_root="$(cd "$cwd/.." && pwd)"
fi

dcq_docroot="$(detect_docroot "${app_root%/}/.ddev/config.yaml")"
DCQ_DOCROOT="$dcq_docroot"
DOCROOT_CONTAINER="/var/www/html/${DCQ_DOCROOT}"
DOCROOT_CORE="${DOCROOT_CONTAINER}/core"
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
  if prompt_recommended_settings; then
    recommended_mode=1
  fi
fi

# Always set recommended defaults for unset environment variables.
# This ensures sensible defaults in non-interactive mode and when using recommended_mode.
set_default_env "DCQ_INSTALL_MODE" "replace"
set_default_env "DCQ_INSTALL_DEPS" "install"
set_default_env "DCQ_INSTALL_NODE_DEPS" "root"
set_default_env "DCQ_PHPSTAN_LEVEL" "3"
set_default_env "DCQ_INSTALL_IDE_SETTINGS" "merge"
set_default_env "DCQ_INSTALL_GITIGNORE" "add"

# Fail loudly if ddev exec cannot resolve a project. Silent skips later are
# usually caused by running in a context where DDEV can't find .ddev/config.yaml.
ddev_cmd="${DDEV_EXECUTABLE:-ddev}"
if command_available "$ddev_cmd"; then
  if ! "$ddev_cmd" exec true >/dev/null 2>&1; then
    emit 'ERROR: ddev exec could not resolve a project from %s.\n' "${PWD:-.}"
    emit 'Run the installer from the target project (for add-on installs, this should be automatic).\n'
    emit 'Try: cd %s && ddev exec true\n' "$app_root"
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
  if [ "$deps_mode_raw" = "1" ] || [ "$deps_mode_raw" = "true" ] || [ "$deps_mode_raw" = "yes" ] || [ "$deps_mode_raw" = "on" ] || [ "$deps_mode_raw" = "install" ] || [ "$deps_mode_raw" = "auto" ]; then
    deps_mode="install"
  elif [ "$deps_mode_raw" = "0" ] || [ "$deps_mode_raw" = "false" ] || [ "$deps_mode_raw" = "no" ] || [ "$deps_mode_raw" = "off" ] || [ "$deps_mode_raw" = "skip" ]; then
    deps_mode="skip"
  else
    # Default is now set via set_default_env, so this should be install unless overridden
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
      question="Recommend installing PHP dev tools from composer.lock. Proceed?"
    else
      question="Recommend installing drupal/core-dev as a dev dependency to install PHP code quality tools and Drupal coding standards. Proceed?"
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
      (cd "$app_root" && run_command "${cmd[@]}")
      emit 'Dependencies installed.\n'
    fi
  fi
fi

script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
if [[ "$script_path" == */.ddev/dcq-install.sh ]]; then
  rm -f "$script_path"
  emit 'Removed %s after install.\n' "$script_path"
fi

emit '\n==> Phase 2: Copy Drupal.org GitLab CI template configs and shims\n'
emit 'This will copy config files into the project root and install shims under %s.\n' "$shim_dir_env"
phpstan_updated=0
copy_changed=0
copy_skipped=0
copy_unchanged=0


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

  if [ -e "$target" ]; then
    if cmp -s "$target" "$tmp"; then
      emit_copy 'OK: %s already matches.\n' "$target"
      copy_unchanged=$((copy_unchanged + 1))
      rm -f "$tmp"
      continue
    fi

    if [ "$skip_all" -eq 1 ]; then
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
      choice="$(prompt_choice "$target" "true")"
      choice="$(string_lower "$choice")"
      choice="$(printf '%s' "$choice" | tr -s ' ')"
      case "$choice" in
        r|replace)
          backup="$(backup_file "$target")"
          emit_copy 'BACKUP: %s\n' "$backup"
          ;;
        s|skip)
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
          emit_copy 'SKIP: %s (existing file).\n' "$target"
          copy_skipped=$((copy_skipped + 1))
          rm -f "$tmp"
          continue
          ;;
        *)
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
  emit_copy 'WRITE: %s\n' "$target"
  copy_changed=$((copy_changed + 1))
done < <(find "$addon_root" -type f -print0)

if [ "$copy_changed" -eq 0 ] && [ "$copy_skipped" -eq 0 ]; then
  emit 'All files already match; no changes.\n'
else
  emit 'Done. Changed: %s, skipped: %s, unchanged: %s.\n' "$copy_changed" "$copy_skipped" "$copy_unchanged"
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
        node_action="$(prompt_node_install_action "$has_root_package_json" "$missing_node_deps")"
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
          emit 'Installing JS deps in project root using %s.\n' "${root_pm:-npm}"
          if [ "${root_pm:-npm}" = "npm" ]; then
            cmd=( "$ddev_cmd" "exec" "bash" "-lc" "cd /var/www/html && npm install" )
          else
            cmd=( "$ddev_cmd" "exec" "bash" "-lc" "cd /var/www/html && yarn install" )
          fi
          run_command "${cmd[@]}"
        fi
        emit 'Node toolchain installed (project root).\n'
      fi
    fi
  fi
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
  case "$ide_mode_raw" in
    merge|m) ide_mode="merge" ;;
    overwrite|replace|o) ide_mode="overwrite" ;;
    manual|skip|s) ide_mode="skip" ;;
    *) ide_mode="merge" ;;  # Default is now set via set_default_env
  esac

  if [ "$ide_mode" = "prompt" ]; then
    emit 'VS Code/Codium settings/extensions: choose merge, overwrite (with backup), or skip.\n'
    printf '\n'
    ide_mode="$(prompt_ide_settings_mode)"
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
        "$stylelint_path" "$prettier_path" "$eslint_node_path" "$eslint_resolve_plugins"
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
  else
    emit '  - PHP dev tools: NOT installed\n'
  fi

  if [ "$node_status" = "root" ]; then
    emit '  - Node toolchain (ESLint, Prettier, Stylelint)\n'
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

  if [ "$php_deps_status" != "installed" ]; then
    emit '  %s. Install PHP tools: ddev composer require --dev drupal/core-dev\n' "$step_num"
    step_num=$((step_num + 1))
  fi

  if [ "$node_status" != "root" ]; then
    emit '  %s. Install Node tools: ddev exec bash -lc "cd /var/www/html && npm install"\n' "$step_num"
    step_num=$((step_num + 1))
  fi

  emit '  %s. Run quality checks: ddev checks\n' "$step_num"
  step_num=$((step_num + 1))

  if [ "$ide_status" = "skip" ]; then
    emit '  %s. Setup VS Code: see .ddev/drupal-code-quality/ide-settings/vscode/README.md\n' "$step_num"
  fi

  emit '\n'
  emit 'More info: https://github.com/UltraBob/ddev-drupal-code-quality\n'
  emit '===============================================================\n'
}

# Determine summary statuses
php_deps_summary="skipped"
if [ "${should_install:-0}" -eq 1 ]; then
  php_deps_summary="installed"
fi

node_summary="skipped"
if [ -n "${node_target_choice:-}" ] && [ "$node_target_choice" = "root" ]; then
  node_summary="root"
fi

ide_summary="${ide_mode:-skip}"

configs_copied="${copy_changed:-0}"

print_install_summary "$php_deps_summary" "$node_summary" "$ide_summary" "$configs_copied"
