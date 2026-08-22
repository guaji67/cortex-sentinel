#!/bin/bash
# 构建、签名、公证并验收 Cortex 哨兵正式发布包。

set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_dir="$package_dir/.build/CortexSentinelBar.app"
binary_path="$app_dir/Contents/MacOS/CortexSentinelBar"
dist_dir="$package_dir/dist"
version="${RELEASE_VERSION:-1.1.0}"
build_number="${RELEASE_BUILD_NUMBER:-$(TZ=Asia/Shanghai date +%Y%m%d)}"
identity="Developer ID Application: Xiang Yu (M3JSCZ5X23)"
signing_keychain="$HOME/.cortex-build/devid.keychain-db"
signing_password_file="$HOME/.cortex-build/devid.keychain-password"
notary_profile="cortex-notary"
notary_keychain="$HOME/.cortex-build/notary.keychain-db"
notary_password_file="$HOME/.cortex-build/notary.keychain-password"
dmg_path="$dist_dir/Cortex哨兵-$version.dmg"

work_dir=""
mount_dir=""
mounted=0

cleanup() {
  if [ "$mounted" -eq 1 ]; then
    hdiutil detach "$mount_dir" -quiet 2>/dev/null || true
  fi
  if [ -n "$work_dir" ]; then
    rm -rf "$work_dir"
  fi
  if [ -n "$mount_dir" ]; then
    rmdir "$mount_dir" 2>/dev/null || true
  fi
}
trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "失败：缺少命令 $1" >&2
    exit 1
  }
}

for command_name in swift codesign hdiutil xcrun spctl ditto plutil shasum security jq lipo awk readlink; do
  require_command "$command_name"
done

[ -f "$notary_keychain" ] || {
  echo "失败：公证钥匙串不存在：$notary_keychain" >&2
  exit 1
}
[ -f "$notary_password_file" ] || {
  echo "失败：公证钥匙串密码文件不存在：$notary_password_file" >&2
  exit 1
}
[ -f "$signing_keychain" ] || {
  echo "失败：签名钥匙串不存在：$signing_keychain" >&2
  exit 1
}
[ -f "$signing_password_file" ] || {
  echo "失败：签名钥匙串密码文件不存在：$signing_password_file" >&2
  exit 1
}

echo "== 解锁签名钥匙串 =="
# 密码只从 stdin 读取，不出现在命令行、日志或环境变量中。
security unlock-keychain "$signing_keychain" < "$signing_password_file"

echo "== 解锁公证钥匙串 =="
# 密码只从 stdin 读取，不出现在命令行、日志或环境变量中。
security unlock-keychain "$notary_keychain" < "$notary_password_file"

echo "== Swift release build =="
swift build --package-path "$package_dir" -c release
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$package_dir/.build/release/CortexSentinelBar" "$binary_path"
cp "$package_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$package_dir/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_dir/Contents/Info.plist"

if ! lipo -archs "$binary_path" | tr ' ' '\n' | grep -qx arm64; then
  echo "失败：正式 app 不包含 arm64" >&2
  exit 1
fi

echo "== 签名 app =="
codesign --force --deep --options runtime --timestamp --keychain "$signing_keychain" --sign "$identity" "$app_dir"
codesign --verify --deep --strict "$app_dir"

submit_notarization() {
  local artifact="$1"
  local result_file="$2"
  local status

  xcrun notarytool submit "$artifact" \
    --keychain-profile "$notary_profile" \
    --keychain "$notary_keychain" \
    --wait \
    --output-format json > "$result_file"
  status="$(/usr/bin/jq -r '.status // empty' "$result_file")"
  if [ "$status" != "Accepted" ]; then
    echo "失败：公证未 Accepted：$artifact（状态：${status:-未知}）" >&2
    /usr/bin/jq -r 'if .status then "status=\(.status)" else empty end, if .message then "message=\(.message)" else empty end' "$result_file" >&2
    exit 1
  fi
  echo "公证 Accepted：$(basename "$artifact")"
}

echo "== 公证 app =="
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/cortex-sentinel-release.XXXXXX")"
app_zip="$work_dir/Cortex哨兵-$version.app.zip"
app_notary_result="$work_dir/app-notary.json"
ditto -c -k --keepParent "$app_dir" "$app_zip"
submit_notarization "$app_zip" "$app_notary_result"
xcrun stapler staple "$app_dir"
xcrun stapler validate "$app_dir"
codesign --verify --deep --strict "$app_dir"

echo "== 构建 DMG =="
mkdir -p "$dist_dir"
rm -f "$dmg_path" "$dmg_path.sha256"
volume_dir="$work_dir/Cortex 哨兵"
mkdir -p "$volume_dir"
ditto "$app_dir" "$volume_dir/Cortex哨兵.app"
ln -s /Applications "$volume_dir/Applications"
hdiutil create -quiet -ov -format UDZO -volname "Cortex 哨兵" \
  -srcfolder "$volume_dir" "$dmg_path"
hdiutil verify "$dmg_path"

echo "== 签名 DMG =="
codesign --force --timestamp --keychain "$signing_keychain" --sign "$identity" "$dmg_path"
codesign --verify --strict "$dmg_path"

echo "== 公证 DMG =="
dmg_notary_result="$work_dir/dmg-notary.json"
submit_notarization "$dmg_path" "$dmg_notary_result"
xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"

echo "== app 终验 =="
spctl -a -vv -t exec "$app_dir"
xcrun stapler validate "$app_dir"
codesign --verify --deep --strict "$app_dir"

echo "== DMG 挂载终验 =="
mount_dir="$(mktemp -d "${TMPDIR:-/tmp}/cortex-sentinel-mount.XXXXXX")"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mount_dir" "$dmg_path"
mounted=1
mounted_app="$mount_dir/Cortex哨兵.app"
spctl -a -vv -t exec "$mounted_app"
xcrun stapler validate "$mounted_app"
codesign --verify --deep --strict "$mounted_app"
if [ ! -L "$mount_dir/Applications" ] || [ "$(readlink "$mount_dir/Applications")" != "/Applications" ]; then
  echo "失败：DMG 内 Applications 快捷方式不正确" >&2
  exit 1
fi
hdiutil detach "$mount_dir" -quiet
mounted=0

(
  cd "$dist_dir"
  shasum -a 256 "$(basename "$dmg_path")" > "$(basename "$dmg_path").sha256"
)

echo "== 发布产物 =="
echo "version=$version"
echo "build=$build_number"
echo "dmg=$dmg_path"
echo "sha256=$(awk '{print $1}' "$dmg_path.sha256")"
