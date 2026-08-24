#!/bin/bash
# 在 app 签名之前，把安装器脚本的摘要写进 app 内部资源。

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "用法：$0 /path/to/Cortex哨兵.app /path/to/install-app.sh" >&2
  exit 2
fi

app_dir="$1"
installer_path="$2"
manifest_path="$app_dir/Contents/Resources/installer-manifest.json"

[ -d "$app_dir/Contents" ] || {
  echo "失败：app Contents 不存在：$app_dir/Contents" >&2
  exit 1
}
[ -f "$installer_path" ] || {
  echo "失败：安装器脚本不存在：$installer_path" >&2
  exit 1
}

installer_sha256="$(shasum -a 256 "$installer_path" | awk '{print $1}')"
case "$installer_sha256" in
  ''|*[!0-9a-fA-F]*)
    echo "失败：未得到安装器 SHA-256：$installer_path" >&2
    exit 1
    ;;
esac

repo_dir="$(cd "$(dirname "$installer_path")/.." && pwd)"
if ! git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "失败：安装器脚本不在 git 仓库内，无法写入溯源信息：$repo_dir" >&2
  exit 1
fi
repository="$(git -C "$repo_dir" remote get-url origin)"
commit="$(git -C "$repo_dir" rev-parse HEAD)"
commit_short="$(git -C "$repo_dir" rev-parse --short=12 HEAD)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist" 2>/dev/null || true)"
generated_at="$(TZ=Asia/Shanghai date +%Y-%m-%dT%H:%M:%S%z)"
[ -n "$repository" ] || {
  echo "失败：读不到 origin URL：$repo_dir" >&2
  exit 1
}
[ -n "$commit" ] || {
  echo "失败：读不到 HEAD commit：$repo_dir" >&2
  exit 1
}

mkdir -p "$(dirname "$manifest_path")"
cat > "$manifest_path" <<EOF
{
  "schema_version": 1,
  "installer_path": "scripts/install-app.sh",
  "installer_sha256": "$installer_sha256",
  "repository": "$repository",
  "commit": "$commit",
  "commit_short": "$commit_short",
  "version": "$version",
  "generated_at": "$generated_at"
}
EOF

echo "installer_manifest=$manifest_path"
echo "installer_sha256=$installer_sha256"
echo "repository=$repository"
echo "commit=$commit"
echo "version=$version"
