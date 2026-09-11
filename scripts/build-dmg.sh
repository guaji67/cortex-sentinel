#!/bin/bash
# 把打好的 Cortex哨兵.app 包成标准「拖进应用程序」安装盘。
#
# 版式对齐 Cortex 主仓的 build_cortex_dmg.sh（Falcon 2026-09-11 令）：
#   窗口 {{200, 360}, {660, 400}}、图标 128、文字 13、不排列、标签在下方
#   Cortex哨兵.app (180,170)     Applications (480,170)
#   中间箭头画在背景图上。盘根只放这两个图标 + .background。
#
# 只用系统自带的 hdiutil + osascript + Chrome 截 HTML。不引第三方工具链。
# 交付盘是 HFS+ 压缩安装盘（ULMO，盘里有 Applications 摆位）。
#
# 用法：
#   scripts/build-dmg.sh --app /path/to/Cortex哨兵.app --output /path/to/out.dmg
#   scripts/build-dmg.sh --app ... --volume-name "Cortex 哨兵" --format ULMO

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BG_HTML="$REPO_ROOT/scripts/dmg-assets/dmg-bg.html"
RENDERER="$REPO_ROOT/scripts/lib/render_dmg_html.py"
DS_PATCH="$REPO_ROOT/scripts/lib/patch_dmg_ds_store.py"

APP_PATH=""
OUTPUT_PATH=""
VOLUME_NAME="Cortex 哨兵"
DMG_FORMAT="ULMO"

usage() {
  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP_PATH="${2:-}"; shift 2 ;;
    --output) OUTPUT_PATH="${2:-}"; shift 2 ;;
    --volume-name) VOLUME_NAME="${2:-}"; shift 2 ;;
    --format) DMG_FORMAT="${2:-}"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "未知参数：$1" >&2; usage 1 ;;
  esac
done

case "$DMG_FORMAT" in
  UDZO|ULFO|ULMO) ;;
  *) echo "不支持的 DMG 压缩格式：$DMG_FORMAT（可选 UDZO、ULFO、ULMO）" >&2; exit 1 ;;
esac
[ -n "$APP_PATH" ] || { echo "必须 --app 指定 .app" >&2; exit 1; }
APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"
[ -f "$APP_PATH/Contents/Info.plist" ] || { echo "不像一个 .app：$APP_PATH" >&2; exit 1; }
[ -f "$BG_HTML" ] || { echo "缺少背景素材：$BG_HTML" >&2; exit 1; }
[ -f "$RENDERER" ] || { echo "缺少渲染器：$RENDERER" >&2; exit 1; }
[ -f "$DS_PATCH" ] || { echo "缺少 .DS_Store 补丁工具：$DS_PATCH" >&2; exit 1; }
[ -n "$OUTPUT_PATH" ] || { echo "必须 --output 指定输出路径" >&2; exit 1; }
mkdir -p "$(dirname "$OUTPUT_PATH")"

APP_NAME="$(basename "$APP_PATH")"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sentinel-dmg.XXXXXX")"
STAGE_DIR="$WORK_DIR/stage"
RW_DMG="$WORK_DIR/rw.dmg"
DEV_NODE=""
cleanup() {
  local rc=$?
  if [ -n "${DEV_NODE:-}" ]; then
    /usr/bin/hdiutil detach "$DEV_NODE" -quiet 2>/dev/null \
      || /usr/bin/hdiutil detach "$DEV_NODE" -force -quiet 2>/dev/null || true
  fi
  /bin/rm -rf "$WORK_DIR"
  exit $rc
}
trap cleanup EXIT INT TERM

echo "==> 渲染背景图"
PROFILE_BG="$(mktemp -d "$WORK_DIR/chrome-bg.XXXXXX")"
/usr/bin/python3 "$RENDERER" \
  --html "$BG_HTML" \
  --out "$WORK_DIR/bg.png" \
  --width 660 --height 400 --scale 2 \
  --profile-dir "$PROFILE_BG"

echo "==> 准备安装窗口内容"
mkdir -p "$STAGE_DIR/.background"
if /bin/cp -cR "$APP_PATH" "$STAGE_DIR/$APP_NAME" 2>/dev/null; then
  :
else
  /usr/bin/ditto "$APP_PATH" "$STAGE_DIR/$APP_NAME"
fi
/bin/cp "$WORK_DIR/bg.png" "$STAGE_DIR/.background/bg.png"
/bin/ln -s /Applications "$STAGE_DIR/Applications"

STAGE_KB="$(/usr/bin/du -sk "$STAGE_DIR" | awk '{print $1}')"
IMAGE_KB=$(( STAGE_KB * 5 / 4 + 20480 ))

echo "==> 生成可写盘映像（内容 ${STAGE_KB} KB，映像 ${IMAGE_KB} KB）"
LEFTOVER_VOLUME="$(printf '/%s/%s' Volumes "$VOLUME_NAME")"
if [ -e "$LEFTOVER_VOLUME" ] && ! /sbin/mount | grep -q " on ${LEFTOVER_VOLUME} "; then
  rmdir "$LEFTOVER_VOLUME" 2>/dev/null || true
fi
if [ -e "$LEFTOVER_VOLUME" ]; then
  /usr/bin/hdiutil detach "$LEFTOVER_VOLUME" -quiet \
    || /usr/bin/hdiutil detach "$LEFTOVER_VOLUME" -force -quiet || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ ! -e "$LEFTOVER_VOLUME" ] && break
    sleep 1
  done
  [ ! -e "$LEFTOVER_VOLUME" ] || {
    echo "卷名仍被占：$LEFTOVER_VOLUME，先弹出再出包" >&2
    exit 1
  }
fi
/usr/bin/hdiutil create -quiet -ov -format UDRW -fs HFS+ \
  -volname "$VOLUME_NAME" -srcfolder "$STAGE_DIR" \
  -size "$IMAGE_KB"k "$RW_DMG"
/bin/rm -rf "$STAGE_DIR"

echo "==> 挂载并摆放窗口"
ATTACH_PLIST="$WORK_DIR/attach.plist"
/usr/bin/hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen -plist > "$ATTACH_PLIST"
PARSE_PY="$WORK_DIR/parse_attach.py"
cat > "$PARSE_PY" <<'PARSER'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    data = plistlib.load(handle)

dev_node = ""
mount_point = ""
for entity in data.get("system-entities", []):
    point = entity.get("mount-point")
    if point and not mount_point:
        mount_point = point
        dev_node = entity.get("dev-entry", "")
if not dev_node:
    for entity in data.get("system-entities", []):
        entry = entity.get("dev-entry", "")
        if entry:
            dev_node = entry
            break
print(dev_node)
print(mount_point)
PARSER
ATTACH_INFO="$(/usr/bin/python3 "$PARSE_PY" "$ATTACH_PLIST")"
DEV_NODE="$(printf '%s\n' "$ATTACH_INFO" | sed -n '1p')"
MOUNT_POINT="$(printf '%s\n' "$ATTACH_INFO" | sed -n '2p')"
[ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ] || { echo "挂载失败" >&2; exit 1; }
VOLUME_LABEL="$(basename "$MOUNT_POINT")"
echo "    挂载点：$MOUNT_POINT"

echo "    等 Finder 认盘"
FINDER_READY=0
for i in $(seq 1 120); do
  OSA_OUT="$(/usr/bin/osascript - "$VOLUME_LABEL" <<'APPLESCRIPT' 2>"$WORK_DIR/finder.err" || true
on run argv
  tell application "Finder" to return exists disk (item 1 of argv)
end run
APPLESCRIPT
)"
  if /bin/cat "$WORK_DIR/finder.err" 2>/dev/null | /usr/bin/grep -qiE 'errAEEventNotPermitted|\(-1743\)|Not authorized'; then
    echo "osascript 控制 Finder 被拒（自动化 TCC）。给运行本脚本的宿主勾选 Finder 后重出。" >&2
    exit 78
  fi
  if printf '%s\n' "$OSA_OUT" | /usr/bin/grep -q '^true$'; then
    FINDER_READY=1
    break
  fi
  sleep 0.25
done
[ "$FINDER_READY" = 1 ] || { echo "Finder 30 秒没认盘：$VOLUME_LABEL" >&2; exit 79; }

SCRIPT_FILE="$WORK_DIR/layout.applescript"
cat > "$SCRIPT_FILE" <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLUME_LABEL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set sidebar width of container window to 0
    set the bounds of container window to {200, 360, 860, 760}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 128
    set text size of theViewOptions to 13
    set label position of theViewOptions to bottom
    set shows item info of theViewOptions to false
    set shows icon preview of theViewOptions to true
    set background picture of theViewOptions to file ".background:bg.png"
    set position of item "$APP_NAME" of container window to {180, 170}
    set position of item "Applications" of container window to {480, 170}
    update without registering applications
    delay 2
    close
    open
    set the bounds of container window to {200, 360, 860, 760}
    delay 1
    close
  end tell
end tell
APPLESCRIPT
/usr/bin/osascript "$SCRIPT_FILE" >/dev/null

/bin/sync
sleep 2
[ -f "$MOUNT_POINT/.DS_Store" ] || { echo "Finder 没写出 .DS_Store，版式不会生效" >&2; exit 1; }
# Finder 开标签栏时会把 set position 的纵坐标 +36 写进 .DS_Store，拨回脚本值。
/usr/bin/python3 "$DS_PATCH" --ds-store "$MOUNT_POINT/.DS_Store" --app-name "$APP_NAME"
# 锁住，防 Finder 卸载时把内存里的旧坐标写回去。
/usr/bin/chflags uchg "$MOUNT_POINT/.DS_Store"
/bin/chmod -Rf go-w "$MOUNT_POINT" 2>/dev/null || true
/bin/sync

echo "==> 卸载可写盘"
/usr/bin/hdiutil detach "$DEV_NODE" -quiet \
  || /usr/bin/hdiutil detach "$DEV_NODE" -force -quiet
DEV_NODE=""

echo "==> 压缩成只读 DMG（${DMG_FORMAT}）"
/bin/rm -f "$OUTPUT_PATH"
/usr/bin/hdiutil convert "$RW_DMG" -format "$DMG_FORMAT" -o "$OUTPUT_PATH" -quiet
/bin/rm -f "$RW_DMG"

[ -f "$OUTPUT_PATH" ] || { echo "转换失败" >&2; exit 1; }

echo "==> 核交付盘"
FORMAT_OUT="$(/usr/bin/hdiutil imageinfo -format "$OUTPUT_PATH" 2>/dev/null | sed -n '2p' | xargs)"
[ "$FORMAT_OUT" = "$DMG_FORMAT" ] || { echo "交付盘格式不是 ${DMG_FORMAT}：$FORMAT_OUT" >&2; exit 1; }
CHECK_MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/sentinel-dmg-check.XXXXXX")"
/usr/bin/hdiutil attach "$OUTPUT_PATH" -readonly -nobrowse -mountpoint "$CHECK_MOUNT" -quiet
[ -d "$CHECK_MOUNT/$APP_NAME" ] || { echo "盘里没有 $APP_NAME" >&2; /usr/bin/hdiutil detach "$CHECK_MOUNT" -quiet; exit 1; }
[ -L "$CHECK_MOUNT/Applications" ] || { echo "盘里没有 Applications 快捷方式" >&2; /usr/bin/hdiutil detach "$CHECK_MOUNT" -quiet; exit 1; }
/usr/bin/hdiutil detach "$CHECK_MOUNT" -quiet

echo ""
echo "完成：$OUTPUT_PATH"
/usr/bin/du -h "$OUTPUT_PATH" | awk '{print "  大小：" $1}'
