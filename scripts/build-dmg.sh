#!/bin/bash
# 生成可拖拽安装的 arm64 DMG：一侧应用，一侧「应用程序」快捷方式。

set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${1:-$package_dir/dist}"

if [ -n "$(git -C "$package_dir" status --porcelain --untracked-files=all)" ]; then
  echo "失败：只从 clean commit 构建 DMG" >&2
  exit 1
fi

commit="$(git -C "$package_dir" rev-parse HEAD)"
commit_short="$(git -C "$package_dir" rev-parse --short=12 HEAD)"
version="$(defaults read "$package_dir/Resources/Info" CFBundleShortVersionString)"
candidate_id="cortex-sentinel-${version}-arm64"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
dmg_path="$output_dir/$candidate_id.dmg"
manifest_path="$output_dir/$candidate_id.manifest.json"
checksum_path="$dmg_path.sha256"

echo "== 构建 release app =="
bash "$package_dir/scripts/build-app.sh" --bundle-version "$commit_short"
source_app="$package_dir/.build/CortexSentinelBar.app"
codesign --verify --deep --strict "$source_app"
built_version="$(defaults read "$source_app/Contents/Info" CFBundleVersion)"
if [ "$built_version" != "$commit_short" ]; then
  echo "失败：构建产物 CFBundleVersion=$built_version，期望 $commit_short" >&2
  exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/cortex-sentinel-dmg.XXXXXX")"
mount_dir="$(mktemp -d "${TMPDIR:-/tmp}/cortex-sentinel-mount.XXXXXX")"
volume_dir="$work_dir/Cortex 哨兵"
mounted=0

cleanup() {
  if [ "$mounted" -eq 1 ]; then
    hdiutil detach "$mount_dir" -quiet 2>/dev/null || true
  fi
  rm -rf "$work_dir" "$mount_dir"
}
trap cleanup EXIT

mkdir -p "$volume_dir"
ditto "$source_app" "$volume_dir/Cortex哨兵.app"
ln -s /Applications "$volume_dir/Applications"

binary_sha256="$(shasum -a 256 "$source_app/Contents/MacOS/CortexSentinelBar" | awk '{print $1}')"
generated_at="$(TZ=Asia/Shanghai date +%Y-%m-%dT%H:%M:%S%z)"

cat > "$manifest_path" <<EOF
{
  "candidate_id": "$candidate_id",
  "commit": "$commit",
  "commit_short": "$commit_short",
  "version": "$version",
  "architecture": "arm64",
  "distribution_scope": "public",
  "signature": "adhoc",
  "notarized": false,
  "generated_at": "$generated_at",
  "app_binary_sha256": "$binary_sha256"
}
EOF
jq empty "$manifest_path"

rm -f "$dmg_path" "$checksum_path"
hdiutil create -quiet -ov -format UDZO -volname "Cortex 哨兵" \
  -srcfolder "$volume_dir" "$dmg_path"
hdiutil verify "$dmg_path"
(
  cd "$output_dir"
  shasum -a 256 "$(basename "$dmg_path")" > "$(basename "$checksum_path")"
)

echo "== 挂载验收 =="
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mount_dir" "$dmg_path"
mounted=1
codesign --verify --deep --strict "$mount_dir/Cortex哨兵.app"
mounted_version="$(defaults read "$mount_dir/Cortex哨兵.app/Contents/Info" CFBundleVersion)"
if [ "$mounted_version" != "$commit_short" ]; then
  echo "失败：DMG 内 CFBundleVersion=$mounted_version，期望 $commit_short" >&2
  exit 1
fi
if [ ! -L "$mount_dir/Applications" ]; then
  echo "失败：DMG 内没有应用程序快捷方式" >&2
  exit 1
fi
if [ "$(readlink "$mount_dir/Applications")" != "/Applications" ]; then
  echo "失败：应用程序快捷方式目标不正确：$(readlink "$mount_dir/Applications")" >&2
  exit 1
fi
mounted_binary_sha256="$(shasum -a 256 "$mount_dir/Cortex哨兵.app/Contents/MacOS/CortexSentinelBar" | awk '{print $1}')"
if [ "$mounted_binary_sha256" != "$binary_sha256" ]; then
  echo "失败：DMG 内 app hash 不匹配" >&2
  exit 1
fi
echo "== 卷内条目 =="
ls -la "$mount_dir"
hdiutil detach "$mount_dir" -quiet
mounted=0

echo "candidate_id=$candidate_id"
echo "dmg=$dmg_path"
echo "manifest=$manifest_path"
echo "checksum=$checksum_path"
