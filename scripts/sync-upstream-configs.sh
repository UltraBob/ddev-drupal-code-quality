#!/usr/bin/env bash
set -euo pipefail

# Fetch latest upstream config files from Drupal core and GitLab CI templates,
# compare against local assets, and optionally apply updates.
#
# Usage:
#   ./scripts/sync-upstream-configs.sh              # Check mode: report diffs
#   ./scripts/sync-upstream-configs.sh --update      # Apply auto-updateable changes
#   ./scripts/sync-upstream-configs.sh --help        # Show usage
#
# Options:
#   --branch-core=BRANCH       Drupal core branch (default: 11.x)
#   --branch-templates=BRANCH  GitLab templates branch (default: main)

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

# Defaults
branch_core="11.x"
branch_templates="main"
do_update=false
base_url="https://git.drupalcode.org"

# Color helpers (respect NO_COLOR)
if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED='' GREEN='' YELLOW='' BOLD='' RESET=''
fi

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Fetch latest upstream config files and compare against local assets.

Options:
  --update                  Apply changes to auto-updateable files
  --branch-core=BRANCH      Drupal core branch (default: ${branch_core})
  --branch-templates=BRANCH GitLab templates branch (default: ${branch_templates})
  --help                    Show this help

Exit codes:
  0  All files up to date (or updated successfully with --update)
  1  Changes detected
  2  Fetch errors occurred
EOF
  exit 0
}

# Parse arguments
for arg in "$@"; do
  case "$arg" in
    --update) do_update=true ;;
    --branch-core=*) branch_core="${arg#*=}" ;;
    --branch-templates=*) branch_templates="${arg#*=}" ;;
    --help|-h) usage ;;
    *) printf "${RED}Unknown argument: %s${RESET}\n" "$arg" >&2; exit 2 ;;
  esac
done

# Temp directory with cleanup
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# Counters
total=0
up_to_date=0
changed=0
updated=0
fetch_errors=0
patch_errors=0

# --- File manifest ---
# Format: local_path|upstream_url|transform|header_extra
# transform: none, phpstan, cspell, prepare-cspell
# header_extra: additional header line after #ddev-generated (empty for most)

declare -a MANIFEST=(
  # Drupal core files
  "drupal-code-quality/assets/.eslintrc.json|${base_url}/project/drupal/-/raw/${branch_core}/core/.eslintrc.json|none|"
  "drupal-code-quality/assets/.eslintrc.passing.json|${base_url}/project/drupal/-/raw/${branch_core}/core/.eslintrc.passing.json|none|"
  "drupal-code-quality/assets/.eslintrc.jquery.json|${base_url}/project/drupal/-/raw/${branch_core}/core/.eslintrc.jquery.json|none|"
  "drupal-code-quality/assets/.stylelintrc.json|${base_url}/project/drupal/-/raw/${branch_core}/core/.stylelintrc.json|none|"
  "drupal-code-quality/assets/.prettierrc.json|${base_url}/project/drupal/-/raw/${branch_core}/core/.prettierrc.json|none|"
  # GitLab templates files
  "drupal-code-quality/assets/phpstan.neon|${base_url}/project/gitlab_templates/-/raw/${branch_templates}/assets/phpstan.neon|phpstan|# Source: ${base_url}/project/gitlab_templates/-/blob/${branch_templates}/assets/phpstan.neon"
  "drupal-code-quality/assets/.phpcs.xml|${base_url}/project/gitlab_templates/-/raw/${branch_templates}/assets/phpcs.xml.dist|none|"
  "drupal-code-quality/assets/.cspell.json|${base_url}/project/gitlab_templates/-/raw/${branch_templates}/assets/.cspell.json|cspell|"
  # Scripts
  "drupal-code-quality/tooling/scripts/prepare-cspell.php|${base_url}/project/gitlab_templates/-/raw/${branch_templates}/scripts/prepare-cspell.php|prepare-cspell|"
)

# --- Transform functions ---

# Strip the includes/BASELINE_PLACEHOLDER block from upstream phpstan.neon
transform_phpstan() {
  local input="$1" output="$2"
  sed -n '/^parameters:/,$p' "$input" > "$output"
}

# Strip arrays populated by prepare-cspell.php from a .cspell.json file,
# leaving only structural fields (description, language, flagWords, overrides, etc.)
# for comparison. Uses python3 for reliable JSON handling.
strip_cspell_expanded_arrays() {
  local input="$1" output="$2"
  python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
for key in ('ignorePaths', 'dictionaries', 'dictionaryDefinitions', 'words'):
    data[key] = []
json.dump(data, sys.stdout, indent=4, ensure_ascii=False)
print()
" "$input" > "$output"
}

# Apply DCQ patch to prepare-cspell.php: replace single-line $non_project_directories
# with our expanded array for custom code scanning.
transform_prepare_cspell() {
  local input="$1" output="$2"
  if ! grep -q '\$non_project_directories = \["\$webRoot"' "$input"; then
    return 1  # Patch target not found
  fi

  # Replace the single-line assignment with our expanded multi-line array
  sed '/\$non_project_directories = \["\$webRoot",/c\
// Exclude specific directories but allow scanning custom code\
$non_project_directories = [\
  "$webRoot/core",\
  "$webRoot/modules/contrib",\
  "$webRoot/themes/contrib",\
  "$webRoot/profiles/contrib",\
  "vendor",\
  "node_modules",\
  ".git",\
  "recipes",\
];' "$input" > "$output"
}

# Strip DCQ headers from local file for comparison
strip_dcq_header() {
  local file="$1"
  # Remove first line if #ddev-generated, then remove next line if # Source:
  sed '1{/^#ddev-generated$/d;}' "$file" | sed '1{/^# Source:/d;}'
}

# --- Main loop ---

printf "${BOLD}Syncing upstream configs...${RESET}\n"
printf "Core branch: %s | Templates branch: %s\n\n" "$branch_core" "$branch_templates"

for entry in "${MANIFEST[@]}"; do
  IFS='|' read -r local_path upstream_url transform header_extra <<< "$entry"
  local_file="${repo_root}/${local_path}"
  filename="$(basename "$local_path")"
  total=$((total + 1))

  printf "${BOLD}%-40s${RESET} " "$local_path"

  # Fetch upstream
  fetched="${tmp_dir}/${filename}.upstream"
  http_code=$(curl --fail --silent --output "$fetched" --write-out '%{http_code}' "$upstream_url" 2>/dev/null || true)

  if [[ ! -f "$fetched" ]] || [[ ! -s "$fetched" ]] || [[ "$http_code" -ge 400 ]]; then
    printf "${RED}FETCH FAILED (HTTP %s)${RESET}\n" "$http_code"
    fetch_errors=$((fetch_errors + 1))
    continue
  fi

  # Apply transform to fetched file
  transformed="${tmp_dir}/${filename}.transformed"
  case "$transform" in
    phpstan)
      transform_phpstan "$fetched" "$transformed"
      ;;
    cspell)
      # Upstream has empty arrays; local has arrays populated by prepare-cspell.php.
      # Normalize both sides by stripping those arrays so we only compare
      # structural fields (description, language, flagWords, overrides, etc.).
      strip_cspell_expanded_arrays "$fetched" "$transformed"
      ;;
    prepare-cspell)
      if ! transform_prepare_cspell "$fetched" "$transformed"; then
        printf "${YELLOW}PATCH TARGET NOT FOUND${RESET}\n"
        printf "  The upstream file has changed structure. Manual review required.\n"
        printf "  Upstream: %s\n" "$upstream_url"
        patch_errors=$((patch_errors + 1))
        changed=$((changed + 1))
        continue
      fi
      ;;
    none)
      cp "$fetched" "$transformed"
      ;;
  esac

  # Ensure trailing newline on transformed file (DDEV addon checker requires it,
  # but some upstream files lack one)
  if [[ -s "$transformed" ]] && [[ "$(tail -c 1 "$transformed" | wc -l)" -eq 0 ]]; then
    echo "" >> "$transformed"
  fi

  # Strip DCQ header from local for comparison
  if [[ ! -f "$local_file" ]]; then
    printf "${RED}LOCAL FILE MISSING${RESET}\n"
    changed=$((changed + 1))
    continue
  fi

  local_stripped="${tmp_dir}/${filename}.local-stripped"
  strip_dcq_header "$local_file" > "$local_stripped"

  # For cspell, also strip expanded arrays from the local copy
  if [[ "$transform" == "cspell" ]]; then
    strip_cspell_expanded_arrays "$local_stripped" "${local_stripped}.tmp"
    mv "${local_stripped}.tmp" "$local_stripped"
  fi

  # Compare
  diff_output=$(diff -u --label "local: ${local_path}" --label "upstream" "$local_stripped" "$transformed" 2>/dev/null || true)

  if [[ -z "$diff_output" ]]; then
    printf "${GREEN}up to date${RESET}\n"
    up_to_date=$((up_to_date + 1))
  else
    printf "${RED}CHANGED${RESET}\n"
    changed=$((changed + 1))

    # Show diff
    echo "$diff_output" | head -50
    diff_lines=$(echo "$diff_output" | wc -l)
    if [[ "$diff_lines" -gt 50 ]]; then
      printf "  ... (%d more lines)\n" $((diff_lines - 50))
    fi
    echo

    # Apply update if requested
    if $do_update; then
      {
        echo "#ddev-generated"
        if [[ -n "$header_extra" ]]; then
          echo "$header_extra"
        fi
        cat "$transformed"
      } > "$local_file"
      printf "  ${GREEN}Updated.${RESET}\n"
      updated=$((updated + 1))
    fi
  fi
done

# --- Summary ---
echo
printf "${BOLD}Summary:${RESET} %d checked, %d up to date, %d changed" "$total" "$up_to_date" "$changed"
if [[ "$fetch_errors" -gt 0 ]]; then
  printf ", ${RED}%d fetch errors${RESET}" "$fetch_errors"
fi
if [[ "$patch_errors" -gt 0 ]]; then
  printf ", ${YELLOW}%d patch conflicts${RESET}" "$patch_errors"
fi
if $do_update && [[ "$updated" -gt 0 ]]; then
  printf ", ${GREEN}%d updated${RESET}" "$updated"
fi
echo

if [[ "$changed" -gt 0 ]] && ! $do_update; then
  echo
  printf "Run with ${BOLD}--update${RESET} to apply changes to auto-updateable files.\n"
fi

if [[ "$changed" -gt 0 ]] || { $do_update && [[ "$updated" -gt 0 ]]; }; then
  echo
  printf "Suggested: ${BOLD}DCQ_FULL_TESTS=1 bats --jobs 4 ./tests/test.bats${RESET}\n"
fi

# Exit code
if [[ "$fetch_errors" -gt 0 ]]; then
  exit 2
elif [[ "$changed" -gt 0 ]] && ! $do_update; then
  exit 1
else
  exit 0
fi
