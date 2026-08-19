#!/bin/bash

set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_dir="$package_dir/.build/CortexSentinelBar.app"
contents_dir="$app_dir/Contents"

swift build --package-path "$package_dir" -c release
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$package_dir/.build/release/CortexSentinelBar" "$contents_dir/MacOS/CortexSentinelBar"
cp "$package_dir/Resources/Info.plist" "$contents_dir/Info.plist"
cp "$package_dir/Resources/AppIcon.icns" "$contents_dir/Resources/AppIcon.icns"
codesign --force --deep --sign - "$app_dir"
