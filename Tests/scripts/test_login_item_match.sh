#!/bin/bash
# 登录项名字+路径双判的 shell 夹具。不调用 osascript。

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SENTINEL_LOGIN_ITEM_LIB=1
# shellcheck source=../../scripts/install-app.sh
source "$repo_root/scripts/install-app.sh"

fail=0
target="/Applications/Cortex哨兵.app"

assert_remove() {
  local name="$1"
  local path="$2"
  local expect="$3"
  local label="$4"
  local got

  if login_item_should_remove "$name" "$path" "$target"; then
    got=0
  else
    got=1
  fi
  if [ "$got" -ne "$expect" ]; then
    echo "FAIL $label (got=$got expect=$expect name=$name path=$path)" >&2
    fail=1
  fi
}

acute="$(/usr/bin/python3 -c 'import sys; sys.stdout.write("Cafe\u0301")')"
if [ "$(nfc_normalize "$acute")" != "$(nfc_normalize "Café")" ]; then
  echo "FAIL nfc_normalize does not fold combining acute" >&2
  fail=1
fi

nfd_target="$(/usr/bin/python3 -c 'import sys,unicodedata; sys.stdout.write(unicodedata.normalize("NFD", sys.argv[1]))' "$target")"
assert_remove "Cortex哨兵" "$nfd_target" 0 "NFD path equals NFC target"
assert_remove "Cortex哨兵" "$target" 0 "compact display name + official path"
assert_remove "Cortex 哨兵" "$target" 0 "CFBundleDisplayName"
assert_remove "CortexSentinelBar" "/Users/me/.build/CortexSentinelBar.app" 0 "bundle name + historical .build"
assert_remove "Legacy" "/Users/me/.build/arm64/CortexSentinelBar.app" 0 "historical .build path"
assert_remove "Bartender 6" "/Applications/Bartender 6.app" 1 "unrelated login item"
assert_remove "Cortex" "/Applications/Cortex.app" 1 "must not delete Cortex.app by name"
assert_remove "Cortex.app" "/Applications/Cortex.app" 1 "must not delete Cortex.app bundle"
assert_remove "xctest" "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/xctest" 1 "xctest"
assert_remove "牛马AI" "" 1 "missing path unrelated name"

if [ "$fail" -ne 0 ]; then
  echo "login item match tests failed" >&2
  exit 1
fi
echo "login item match tests passed"
