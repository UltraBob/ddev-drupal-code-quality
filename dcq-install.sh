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
    if exec 3</dev/tty 4>/dev/tty 2>/dev/null; then
      PROMPT_IN_FD=3
      PROMPT_OUT_FD=4
      PROMPT_AVAILABLE=1
    fi
  fi
}

prompt_choice() {
  local path="$1"
  local warn_parity="$2"

  if [ "${PROMPT_AVAILABLE:-0}" -ne 1 ]; then
    printf 'No interactive terminal detected; skipping conflict prompt for %s (default: skip). Set DCQ_INSTALL_MODE=replace|skip|abort to control behavior.\n' "$path" >&2
    printf 's'
    return
  fi

  if [ "$warn_parity" = "true" ]; then
    printf 'Skipping this file may reduce CI parity for your local tooling.\n' >&"$PROMPT_OUT_FD"
  fi
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

find_missing_node_deps() {
  local ddev_cmd="$1"
  local output
  local status
  local php_script="${cwd}/.dcq-missing-node-deps.php"
  local script_path="/var/www/html/.ddev/.dcq-missing-node-deps.php"
  local attempts=0
  local max_attempts=5

  cat > "$php_script" <<'PHP'
<?php
$rootPath = "/var/www/html/package.json";
$corePath = "/var/www/html/web/core/package.json";
$assetsRoot = "/var/www/html/.ddev/dcq-assets";

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

  if [ "$status" -ne 0 ]; then
    return 1
  fi

  printf '%s' "$output"
}

maybe_install_missing_root_deps() {
  local ddev_cmd="$1"
  local non_interactive="$2"
  local missing_node_deps

  if ! missing_node_deps="$(find_missing_node_deps "$ddev_cmd")"; then
    return 1
  fi

  if [ -z "$missing_node_deps" ]; then
    return 1
  fi

  mapfile -t missing_node_deps_array <<< "$missing_node_deps"
  printf 'Detected missing Drupal JS tooling dependencies in package.json (%d):\n' "${#missing_node_deps_array[@]}"
  for dep in "${missing_node_deps_array[@]}"; do
    [ -n "$dep" ] || continue
    printf '  %s\n' "$dep"
  done

  if [ "$non_interactive" -eq 1 ]; then
    printf 'Skipping dependency add (non-interactive). Install the missing packages to avoid lint errors.\n'
    return 1
  fi

  if prompt_yes_no "Add missing dependencies with 'yarn add -D' in the project root?" 1; then
    deps_cmd=""
    for dep in "${missing_node_deps_array[@]}"; do
      deps_cmd+=" $(printf '%q' "$dep")"
    done
    cmd=( "$ddev_cmd" "exec" "bash" "-lc" "cd /var/www/html && yarn add -D${deps_cmd}" )
    run_command "${cmd[@]}"
    printf 'Node dependencies added (project root).\n'
    return 0
  fi

  printf 'Skipping missing dependency install. ESLint plugins may be unavailable.\n'
  return 1
}

prompt_node_target() {
  local has_root="$1"
  local choice

  if [ "${PROMPT_AVAILABLE:-0}" -ne 1 ]; then
    printf 'skip'
    return
  fi

  if [ "$has_root" -eq 1 ]; then
    printf 'Choose JS toolchain target: [r]oot (project package.json), [c]ore (web/core), [s]kip (no install, default: root): ' >&"$PROMPT_OUT_FD"
    if ! IFS= read -r -u "$PROMPT_IN_FD" choice; then
      choice=""
    fi
    choice="$(string_lower "$choice")"
    if [ -z "$choice" ]; then
      printf 'root'
      return
    fi
  else
    printf 'No project package.json found. Choose JS toolchain target: [r]oot (create from core), [c]ore (web/core), [s]kip (no install, default: root): ' >&"$PROMPT_OUT_FD"
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
    printf 'No interactive terminal detected; skipping prompt. Use DCQ_INSTALL_DEPS=install to auto-approve.\n' >&2
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

prompt_ide_settings_mode() {
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

escape_sed_replacement() {
  printf '%s' "${1:-}" | sed 's/[&|]/\\&/g'
}

render_ide_template() {
  local template="$1"
  local output="$2"
  local shim_setting="$3"
  local stylelint_path="$4"
  local prettier_path="$5"
  local cspell_path="$6"
  local eslint_node_path="$7"
  local eslint_resolve_plugins="$8"
  local escaped_shim
  local escaped_stylelint
  local escaped_prettier
  local escaped_cspell
  local escaped_node_path
  local escaped_resolve_plugins

  escaped_shim="$(escape_sed_replacement "$shim_setting")"
  escaped_stylelint="$(escape_sed_replacement "$stylelint_path")"
  escaped_prettier="$(escape_sed_replacement "$prettier_path")"
  escaped_cspell="$(escape_sed_replacement "$cspell_path")"
  escaped_node_path="$(escape_sed_replacement "$eslint_node_path")"
  escaped_resolve_plugins="$(escape_sed_replacement "$eslint_resolve_plugins")"

  sed \
    -e '1{/^#ddev-generated$/d;}' \
    -e "s|__DCQ_SHIM_DIR__|${escaped_shim}|g" \
    -e "s|__DCQ_STYLELINT_PATH__|${escaped_stylelint}|g" \
    -e "s|__DCQ_PRETTIER_PATH__|${escaped_prettier}|g" \
    -e "s|__DCQ_CSPELL_PATH__|${escaped_cspell}|g" \
    -e "s|__DCQ_ESLINT_NODE_PATH__|${escaped_node_path}|g" \
    -e "s|__DCQ_ESLINT_RESOLVE_PLUGINS__|${escaped_resolve_plugins}|g" \
    "$template" >"$output"
}

merge_json_settings() {
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
def load_json(path):
    with open(path, encoding="utf-8") as f:
        content = f.read()
    lines = content.splitlines()
    if lines and lines[0].strip() == "#ddev-generated":
        content = "\n".join(lines[1:])
    return json.loads(content)

existing = load_json(existing_path)
template = load_json(template_path)

if not isinstance(existing, dict) or not isinstance(template, dict):
    raise SystemExit("settings JSON must be objects")

for key, value in template.items():
    if key not in existing:
        existing[key] = value

with open(dest_path, "w", encoding="utf-8") as f:
    json.dump(existing, f, indent=2, ensure_ascii=True)
    f.write("\n")
PY
  then
    return 1
  fi
}

merge_json_extensions() {
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
def load_json(path):
    with open(path, encoding="utf-8") as f:
        content = f.read()
    lines = content.splitlines()
    if lines and lines[0].strip() == "#ddev-generated":
        content = "\n".join(lines[1:])
    return json.loads(content)

existing = load_json(existing_path)
template = load_json(template_path)

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

with open(dest_path, "w", encoding="utf-8") as f:
    json.dump(merged, f, indent=2, ensure_ascii=True)
    f.write("\n")
PY
  then
    return 1
  fi
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

node_target_choice=""

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

shim_record="$shim_dir_env"
if [[ "$shim_dir" == "$app_root_check"/* ]]; then
  shim_record="${shim_dir#${app_root_check}/}"
fi
if [ -n "$shim_record" ] && [ "$shim_record" != "." ]; then
  printf '%s\n' "$shim_record" > "${cwd}/.dcq-shim-dir"
fi

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
  if [[ "$rel" == ide-settings/* ]]; then
    continue
  fi
  is_shim=0
  if [[ "$rel" == dcq-tooling/bin/* ]]; then
    target="${shim_dir%/}/${rel#dcq-tooling/bin/}"
    is_shim=1
  else
    target="${app_root%/}/${rel}"
  fi

  tmp="$(mktemp "${TMPDIR:-/tmp}/dcq-src-XXXXXX")"
  if [ "$is_shim" -eq 1 ]; then
    cat "$source" >"$tmp"
  else
    strip_generated_header "$source" "$tmp"
  fi

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
        printf 'ddev executable not found in PATH; skipping Node dependency check.\n'
      else
        maybe_install_missing_root_deps "$ddev_cmd" "$non_interactive" || true
      fi
    fi
    if [ "$node_mode_raw" = "skip" ]; then
      printf 'Skipping Node toolchain install. Use DCQ_INSTALL_NODE_DEPS=root or DCQ_INSTALL_NODE_DEPS=core to enable later.\n'
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

      if [ "$target" = "root" ] || [ "$target" = "core" ]; then
        node_target_choice="$target"
      fi

      node_install_done=0
      if [ "$target" = "core" ]; then
        cmd=( "$ddev_cmd" "exec" "bash" "-lc" "cd web/core && yarn install" )
        run_command "${cmd[@]}"
        printf 'Node toolchain installed (core).\n'
        node_install_done=1
      elif [ "$target" = "root" ]; then
        if [ "$has_root_package_json" -eq 1 ]; then
          if maybe_install_missing_root_deps "$ddev_cmd" "$non_interactive"; then
            node_install_done=1
          fi
        fi
        if [ "$node_install_done" -eq 0 ]; then
          cmd=( "$ddev_cmd" "exec" "bash" "-lc" "cd /var/www/html && yarn install" )
          run_command "${cmd[@]}"
        fi
        printf 'Node toolchain installed (project root).\n'
      fi
    fi
  fi
fi

ide_settings_root="${cwd}/dcq-assets/ide-settings/vscode"
ide_settings_template="${ide_settings_root}/settings.json"
ide_extensions_template="${ide_settings_root}/extensions.json"
ide_settings_doc="${ide_settings_root}/README.md"
if [ -f "$ide_settings_template" ] || [ -f "$ide_extensions_template" ]; then
  ide_mode_raw="$(string_lower "${DCQ_INSTALL_IDE_SETTINGS:-}")"
  if [ -z "$ide_mode_raw" ]; then
    if [ "$non_interactive" -eq 1 ]; then
      ide_mode="skip"
    else
      ide_mode="prompt"
    fi
  else
    case "$ide_mode_raw" in
      merge|m) ide_mode="merge" ;;
      overwrite|replace|o) ide_mode="overwrite" ;;
      manual|skip|s) ide_mode="skip" ;;
      *) ide_mode="prompt" ;;
    esac
  fi

  if [ "$ide_mode" = "prompt" ]; then
    ide_mode="$(prompt_ide_settings_mode)"
  fi

  if [ "$ide_mode" = "skip" ]; then
    printf 'Skipping IDE settings/extensions install. See %s for manual setup.\n' "$ide_settings_doc"
  else
    ide_target_dir="${app_root%/}/.vscode"
    ide_target_settings="${ide_target_dir}/settings.json"
    ide_target_extensions="${ide_target_dir}/extensions.json"

    if [ -f "$ide_settings_template" ]; then
      ide_tmp="$(mktemp "${TMPDIR:-/tmp}/dcq-ide-XXXXXX")"

      shim_setting="$shim_dir_env"
      if [[ "$shim_setting" != /* ]]; then
        shim_setting="./${shim_setting}"
      fi
      ide_node_mode=""
      ide_node_mode_raw="$(string_lower "${DCQ_INSTALL_NODE_DEPS:-}")"
      if [ -n "$node_target_choice" ]; then
        ide_node_mode="$node_target_choice"
      else
        case "$ide_node_mode_raw" in
          core) ide_node_mode="core" ;;
          root|project) ide_node_mode="root" ;;
          1|true|yes|on|install|auto) ide_node_mode="root" ;;
        esac
      fi

      if [ -z "$ide_node_mode" ]; then
        if [ -d "${app_root%/}/web/core/node_modules" ] && [ ! -d "${app_root%/}/node_modules" ]; then
          ide_node_mode="core"
        elif [ -d "${app_root%/}/node_modules" ]; then
          ide_node_mode="root"
        elif [ -d "${app_root%/}/web/core/node_modules" ]; then
          ide_node_mode="core"
        else
          ide_node_mode="root"
        fi
      fi

      if [ "$ide_node_mode" = "core" ]; then
        js_modules="./web/core/node_modules"
        eslint_node_path="web/core/node_modules"
        eslint_resolve_plugins="./web/core"
      else
        js_modules="./node_modules"
        eslint_node_path="node_modules"
        eslint_resolve_plugins="."
      fi

      stylelint_path="${js_modules}/stylelint"
      prettier_path="${js_modules}/prettier"
      cspell_path="${js_modules}/cspell"

      render_ide_template "$ide_settings_template" "$ide_tmp" "$shim_setting" \
        "$stylelint_path" "$prettier_path" "$cspell_path" "$eslint_node_path" "$eslint_resolve_plugins"

      if [ "$ide_mode" = "merge" ] && [ -f "$ide_target_settings" ]; then
        if merge_json_settings "$ide_target_settings" "$ide_tmp" "$ide_target_settings"; then
          printf 'MERGE: %s\n' "$ide_target_settings"
        else
          printf 'Unable to merge IDE settings; install manually from %s.\n' "$ide_settings_doc" >&2
        fi
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
        if merge_json_extensions "$ide_target_extensions" "$ide_extensions_template" "$ide_target_extensions"; then
          printf 'MERGE: %s\n' "$ide_target_extensions"
        else
          printf 'Unable to merge IDE extensions; install manually from %s.\n' "$ide_settings_doc" >&2
        fi
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
