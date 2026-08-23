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

mkdir -p "$(dirname "$manifest_path")"
cat > "$manifest_path" <<EOF
{
  "schema_version": 1,
  "installer_path": "scripts/install-app.sh",
  "installer_sha256": "$installer_sha256"
}
EOF

echo "installer_manifest=$manifest_path"
echo "installer_sha256=$installer_sha256"
