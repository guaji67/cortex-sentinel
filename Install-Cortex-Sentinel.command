#!/bin/bash

set -u

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$package_dir"

app_source=""
for app_source in \
  "$package_dir/Payload/Cortex哨兵.app" \
  "$package_dir/Cortex哨兵.app"
do
  if [ -d "$app_source" ]; then
    break
  fi
  app_source=""
done

if [ -n "$app_source" ]; then
  bash scripts/install-app.sh --app-source "$app_source"
else
  bash scripts/install-app.sh
fi
status=$?

if [ "$status" -eq 0 ]; then
  echo
  echo "Cortex 哨兵已安装并恢复为单实例，可关闭此窗口。"
  exit 0
fi

echo
echo "安装未完成，退出码：$status"
read -r -p "按回车键关闭窗口。"
exit "$status"
