#!/bin/bash
# 把 build-release.sh 的产物发布成 GitHub Release（正式版，自动更新源吃这个）。
#
# 用法：bash scripts/publish-release.sh <版本号> <release 说明文件>
#   bash scripts/publish-release.sh 0.1.8 dist/Cortex哨兵-0.1.8.notes.md
#
# 资产名统一改 ASCII（Cortex.-x.y.z.*），避开中文文件名在 GitHub 资产和
# 下载 URL 里的转义坑；更新器按这个名字找 DMG 和 sha256。
set -euo pipefail

version="${1:?用法: publish-release.sh <版本号> <说明文件.md>}"
notes_file="${2:?用法: publish-release.sh <版本号> <说明文件.md>}"
repo="guaji67/cortex-sentinel"

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist_dir="$package_dir/dist"
dmg="$dist_dir/Cortex哨兵-$version.dmg"
manifest="$dist_dir/Cortex哨兵-$version.manifest.json"

[ -f "$dmg" ] || { echo "失败：找不到 $dmg，先跑 build-release.sh" >&2; exit 1; }
[ -f "$dmg.sha256" ] || { echo "失败：找不到 $dmg.sha256" >&2; exit 1; }
[ -f "$manifest" ] || { echo "失败：找不到 $manifest" >&2; exit 1; }
[ -f "$notes_file" ] || { echo "失败：找不到说明文件 $notes_file" >&2; exit 1; }

ascii_dmg="$dist_dir/Cortex.-$version.dmg"
ascii_sha="$dist_dir/Cortex.-$version.dmg.sha256"
ascii_manifest="$dist_dir/Cortex.-$version.manifest.json"
cp "$dmg" "$ascii_dmg"
cp "$dmg.sha256" "$ascii_sha"
cp "$manifest" "$ascii_manifest"

echo "== 发布 v$version 到 $repo =="
gh release create "v$version" \
  --repo "$repo" \
  --title "Cortex 哨兵 $version" \
  --notes-file "$notes_file" \
  "$ascii_dmg" "$ascii_sha" "$ascii_manifest"

echo "== 已发布 =="
gh release view "v$version" --repo "$repo" --json name,isDraft,isPrerelease,assets \
  -q '{name, isDraft, isPrerelease, assets: [.assets[].name]}'
