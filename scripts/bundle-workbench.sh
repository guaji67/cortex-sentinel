#!/bin/bash
# Shared by developer and notarized release builds, before signing.
set -euo pipefail
package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_dir="${1:?app path required}"
destination="$app_dir/Contents/Resources/Workbench"
mkdir -p "$destination/client"
cp "$package_dir"/Resources/Workbench/{index.html,workbench.js,workbench.css,GUIDE.md} "$destination/"
cp "$package_dir"/backend/cortex_sentinel/workbench/{client.py,protocol.py,import_html.py,authorize.py} "$destination/client/"
mkdir -p "$destination/skill"
cp "$package_dir/skills/cortex-governance-board/SKILL.md" "$destination/skill/"
test -s "$destination/index.html"
test -s "$destination/workbench.js"
