#!/bin/bash
# Shared by developer and notarized release builds, before signing.
set -euo pipefail
package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_dir="${1:?app path required}"
destination="$app_dir/Contents/Resources/Workbench"
mkdir -p "$destination/client"
cp "$package_dir"/Resources/Workbench/{index.html,workbench.js,ai-management.js,workbench.css,GUIDE.md} "$destination/"
cp "$package_dir/docs/ai-management-runbook.md" "$destination/AI-RULES.md"
cp "$package_dir"/backend/cortex_sentinel/workbench/{client.py,protocol.py,import_html.py,authorize.py} "$destination/client/"
cp "$package_dir/scripts/ai-rules.py" "$destination/client/"
cp "$package_dir/scripts/export-ai-peer.py" "$destination/client/"
mkdir -p "$destination/skill"
cp "$package_dir/skills/cortex-governance-board/SKILL.md" "$destination/skill/"
mkdir -p "$destination/hooks"
cp "$package_dir/Resources/Workbench/hooks/board-context.sh" "$destination/hooks/"
test -s "$destination/index.html"
test -s "$destination/workbench.js"
