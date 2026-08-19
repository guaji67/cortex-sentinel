#!/bin/bash
# 把源码编成 .app。仓里的 Resources/Info.plist 不改；只戳构建产物里的 CFBundleVersion。
# 单独跑默认写 dev；出 DMG 时传入这次的 commit 短哈希。

set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_dir="$package_dir/.build/CortexSentinelBar.app"
contents_dir="$app_dir/Contents"
bundle_version="${CORTEX_SENTINEL_BUNDLE_VERSION:-dev}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --bundle-version)
      [ "$#" -ge 2 ] || { echo "--bundle-version 缺值" >&2; exit 2; }
      bundle_version="$2"
      shift 2
      ;;
    *)
      echo "未知参数：$1" >&2
      exit 2
      ;;
  esac
done

swift build --package-path "$package_dir" -c release
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$package_dir/.build/release/CortexSentinelBar" "$contents_dir/MacOS/CortexSentinelBar"
cp "$package_dir/Resources/Info.plist" "$contents_dir/Info.plist"
plutil -replace CFBundleVersion -string "$bundle_version" "$contents_dir/Info.plist"
cp "$package_dir/Resources/AppIcon.icns" "$contents_dir/Resources/AppIcon.icns"
codesign --force --deep --sign - "$app_dir"
