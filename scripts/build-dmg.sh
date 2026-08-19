#!/bin/bash
# 生成供维护者自有 arm64 Mac 使用的 LAN 内部分发 DMG。

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
candidate_id="cortex-sentinel-${version}-${commit_short}-arm64-lan"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
dmg_path="$output_dir/$candidate_id.dmg"
manifest_path="$output_dir/$candidate_id.manifest.json"
checksum_path="$dmg_path.sha256"

echo "== 构建 release app =="
bash "$package_dir/scripts/build-app.sh"
source_app="$package_dir/.build/CortexSentinelBar.app"
codesign --verify --deep --strict "$source_app"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/cortex-sentinel-dmg.XXXXXX")"
mount_dir="$(mktemp -d "${TMPDIR:-/tmp}/cortex-sentinel-mount.XXXXXX")"
volume_dir="$work_dir/Cortex 哨兵安装器"
mounted=0

cleanup() {
  if [ "$mounted" -eq 1 ]; then
    hdiutil detach "$mount_dir" -quiet 2>/dev/null || true
  fi
  rm -rf "$work_dir" "$mount_dir"
}
trap cleanup EXIT

mkdir -p "$volume_dir/Payload" "$volume_dir/scripts"
ditto "$source_app" "$volume_dir/Payload/Cortex哨兵.app"
install -m 0755 "$package_dir/Install-Cortex-Sentinel.command" \
  "$volume_dir/安装 Cortex 哨兵.command"
install -m 0755 "$package_dir/scripts/install-app.sh" "$volume_dir/scripts/install-app.sh"
cp "$package_dir/INSTALL.md" "$volume_dir/安装说明.md"

binary_sha256="$(shasum -a 256 "$source_app/Contents/MacOS/CortexSentinelBar" | awk '{print $1}')"
installer_sha256="$(shasum -a 256 "$package_dir/scripts/install-app.sh" | awk '{print $1}')"
generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "$volume_dir/manifest.json" <<EOF
{
  "candidate_id": "$candidate_id",
  "commit": "$commit",
  "version": "$version",
  "architecture": "arm64",
  "distribution_scope": "falcon_lan_internal",
  "signature": "adhoc",
  "notarized": false,
  "generated_at": "$generated_at",
  "app_binary_sha256": "$binary_sha256",
  "installer_sha256": "$installer_sha256"
}
EOF
jq empty "$volume_dir/manifest.json"
cp "$volume_dir/manifest.json" "$manifest_path"

rm -f "$dmg_path" "$checksum_path"
hdiutil create -quiet -ov -format UDZO -volname "Cortex 哨兵安装器" \
  -srcfolder "$volume_dir" "$dmg_path"
hdiutil verify "$dmg_path"
(
  cd "$output_dir"
  shasum -a 256 "$(basename "$dmg_path")" > "$(basename "$checksum_path")"
)

echo "== 挂载验收 =="
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mount_dir" "$dmg_path"
mounted=1
codesign --verify --deep --strict "$mount_dir/Payload/Cortex哨兵.app"
bash -n "$mount_dir/安装 Cortex 哨兵.command"
bash -n "$mount_dir/scripts/install-app.sh"
mounted_binary_sha256="$(shasum -a 256 "$mount_dir/Payload/Cortex哨兵.app/Contents/MacOS/CortexSentinelBar" | awk '{print $1}')"
if [ "$mounted_binary_sha256" != "$binary_sha256" ]; then
  echo "失败：DMG 内 app hash 不匹配" >&2
  exit 1
fi
hdiutil detach "$mount_dir" -quiet
mounted=0

echo "candidate_id=$candidate_id"
echo "dmg=$dmg_path"
echo "manifest=$manifest_path"
echo "checksum=$checksum_path"
