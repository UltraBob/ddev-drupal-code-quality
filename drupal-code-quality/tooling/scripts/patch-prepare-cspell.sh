#!/usr/bin/env bash
#ddev-generated

# MAINTAINER TOOL: Patches prepare-cspell.php to search custom directories
# instead of excluding entire web/ directory.
#
# Usage:
#   1. Download fresh prepare-cspell.php from GitLab templates
#   2. Run: ./patch-prepare-cspell.sh path/to/fresh-prepare-cspell.php
#   3. Commit the patched version to the addon repo

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ $# -lt 1 ]; then
  echo "Usage: $0 <path-to-prepare-cspell.php>"
  echo ""
  echo "This script patches prepare-cspell.php to search custom Drupal directories"
  echo "(web/modules/custom, web/themes/custom, etc.) instead of excluding the"
  echo "entire web/ directory."
  echo ""
  echo "Example workflow:"
  echo "  1. Download fresh prepare-cspell.php from GitLab templates"
  echo "  2. ./patch-prepare-cspell.sh ../prepare-cspell.php"
  echo "  3. Review and commit the patched file"
  exit 1
fi

SCRIPT_FILE="$1"

if [ ! -f "$SCRIPT_FILE" ]; then
  echo "Error: File not found: $SCRIPT_FILE"
  exit 1
fi

# Backup the original
cp "$SCRIPT_FILE" "$SCRIPT_FILE.orig"

echo "Patching $SCRIPT_FILE..."

# Replace the single-line array definition with a multi-line version
# that excludes specific contrib/core directories instead of the entire webroot
perl -i.bak -pe '
  if (/^\$non_project_directories = \["\$webRoot", '\''vendor'\'', '\''node_modules'\'', '\''\.git'\'', '\''recipes'\''\];$/) {
    $_ = "// Exclude specific directories but allow scanning custom code\n" .
         "\$non_project_directories = [\n" .
         "  \"\$webRoot/core\",\n" .
         "  \"\$webRoot/modules/contrib\",\n" .
         "  \"\$webRoot/themes/contrib\",\n" .
         "  \"\$webRoot/profiles/contrib\",\n" .
         "  \"vendor\",\n" .
         "  \"node_modules\",\n" .
         "  \".git\",\n" .
         "  \"recipes\",\n" .
         "];\n";
  }
' "$SCRIPT_FILE"

# Perl creates .bak automatically; remove it if patch succeeded
rm -f "$SCRIPT_FILE.bak"

echo ""
echo "✓ Successfully patched $SCRIPT_FILE"
echo "✓ Original saved as $SCRIPT_FILE.orig"
echo ""
echo "The patched file now searches custom directories:"
echo "  - web/modules/custom/"
echo "  - web/themes/custom/"
echo "  - web/profiles/custom/"
echo ""
echo "Review the changes and commit the patched file to the addon repo."
