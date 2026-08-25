#!/bin/bash
# Finder 双击入口：哨兵卡住时不依赖哨兵自己的窗口。

set -euo pipefail

ctl="/Applications/Cortex哨兵.app/Contents/Resources/sentinel-ctl.sh"
if [ ! -x "$ctl" ]; then
  echo "找不到重启脚本：$ctl"
  echo "请先重新安装 Cortex 哨兵。"
  read -r -p "按回车关闭窗口……" _
  exit 1
fi

"$ctl" restart
echo
echo "哨兵已恢复。以后卡住时，直接双击“重启 Cortex 哨兵.command”即可。"
read -r -p "按回车关闭窗口……" _
