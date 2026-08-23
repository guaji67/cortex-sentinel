# COR-1940 安装器完整性校验工作记录

- 工作树：`/Users/falcon/Documents/Code/cortex-sentinel-worktrees/cor1940-installer-integrity`
- 分支：`codex/cor1940-installer-integrity`
- 执行范围：仅修改脚本与本记录；未调用 `build-dmg.sh`、`build-release.sh`，未触发签名、公证或发布产物流程。

## 1. 票面证据复核（以本仓 HEAD 为准）

复核命令与结果：

```text
$ git grep -n 'installer_sha256' HEAD -- scripts
# 无输出，0 命中

$ git grep -n 'binary_sha256' HEAD -- scripts
HEAD:scripts/build-dmg.sh:51:binary_sha256="$(shasum -a 256 "$source_app/Contents/MacOS/CortexSentinelBar" | awk '{print $1}')"
HEAD:scripts/build-dmg.sh:65:  "app_binary_sha256": "$binary_sha256"
HEAD:scripts/build-dmg.sh:96:mounted_binary_sha256="$(shasum -a 256 "$mount_dir/Cortex哨兵.app/Contents/MacOS/CortexSentinelBar" | awk '{print $1}')"
HEAD:scripts/build-dmg.sh:97:if [ "$mounted_binary_sha256" != "$binary_sha256" ]; then
# 4 命中（阳性对照）
```

| 项 | 本仓 HEAD 的复核结果 |
|---|---|
| `installer_sha256` | 0 命中；字段没有写入任何脚本生成的清单 |
| DMG manifest | `build-dmg.sh:21` 定位输出清单，`:54-68` 写 JSON；只有 `app_binary_sha256`（`:65`） |
| 构建期 app 校验 | `build-dmg.sh:96-100` 挂载后重算二进制 SHA-256，与构建期变量比较 |
| `install-app.sh` 装机校验 | `HEAD` 的 `:297`、`:301` 只做 `codesign --verify --deep --strict` 与 arm64 检查；没有读取 manifest |

这组结果与“搜 `installer_sha256` 得 0，同时 `binary_sha256` 得 4”的阳性对照一致，确认票面证据原先指向旧仓的问题。

## 2. 改动文件与构建顺序

### 改动文件

1. `scripts/write-installer-manifest.sh`（新增）：接收 `.app` 与安装器路径，计算 `shasum -a 256`，写入 `Contents/Resources/installer-manifest.json`。
2. `scripts/build-app.sh`：复制 app 资源后调用上述写入器，再执行 ad-hoc `codesign`。
3. `scripts/build-release.sh`：完成二进制、Info.plist、图标和版本字段后调用写入器，再执行 Developer ID 签名；DMG 现在同时携带 `Install-Cortex-Sentinel.command` 与 `scripts/install-app.sh`，挂载终验会比对 app 内摘要和卷内脚本。
4. `scripts/build-dmg.sh`：沿用 `build-app.sh` 生成的 app 内清单；DMG 卷加入安装器入口与脚本；人读的 `$candidate_id.manifest.json` 增加 `installer_sha256`，并在生成前、挂载后分别核对 app 内摘要与实际卷内脚本。
5. `scripts/install-app.sh`：在现有 `codesign --verify --deep --strict "$app_source"` 成功后，读取已签名 app 内的 `installer_sha256`，计算 `BASH_SOURCE[0]` 指向的实际安装器字节并比较；失败发生在备份、停止服务和复制 app 之前。增加 `--verify-installer-integrity --app-source ...` 仅用于独立验证这段哈希逻辑。

### 顺序与信任链

```text
源码 install-app.sh
  -> 写入 .app/Contents/Resources/installer-manifest.json
  -> Developer ID / ad-hoc codesign 覆盖整个 .app
  -> 生成 DMG（卷内复制同一份 install-app.sh）

install-app.sh
  -> codesign --verify --deep --strict app_source
  -> 读取 .app 内 installer-manifest.json
  -> shasum 实际 installer-app.sh 字节并比较
  -> 通过后才进入备份、停止旧实例、安装和 launchd 配置
```

清单写入点位于所有 app 文件就绪之后、签名命令之前。这样清单本身进入签名封装，签名验证先于清单读取；DMG 根清单只展示信息，装机流程不读取它作为依据。

## 3. 票面第 3 条判据与残余风险

把 `.app/Contents/Resources/installer-manifest.json` 的 `installer_sha256` 改成篡改后脚本的新哈希时，流程先在 `codesign --verify --deep --strict "$app_source"` 处返回非零，后续完整性函数没有读取机会，因此仍然拒装。篡改 `scripts/install-app.sh` 本身则会通过签名检查、进入哈希比较并报出 `manifest=...，实际=...` 的不匹配。

信任根是发行流程的 Developer ID 签名。`build-dmg.sh` 仍产出 ad-hoc、未公证包；具备重新签名能力的攻击者可以重建整个 `.app` 的签名封装，这是该分发形态的残余风险。主控的正式出包仍需使用 `build-release.sh` 的 Developer ID、公证和 stapling 链路。

## 4. 未打包验证：命令与真实输出

### Shell 语法和 diff 检查

```text
$ for f in scripts/build-app.sh scripts/build-dmg.sh scripts/build-release.sh scripts/install-app.sh scripts/write-installer-manifest.sh Install-Cortex-Sentinel.command; do /bin/bash -n "$f" || exit 1; done
shell syntax: PASS
$ git diff --check
git diff --check: PASS
```

### 手工 `.app` fixture（未签名、未打包，仅验证哈希逻辑）

```text
$ fixture=$(mktemp -d /tmp/cor1940-integrity-log.XXXXXX)
$ mkdir -p "$fixture/Cortex哨兵.app/Contents/Resources"
$ bash scripts/write-installer-manifest.sh "$fixture/Cortex哨兵.app" scripts/install-app.sh
installer_manifest=/tmp/cor1940-integrity-log.TQS06h/Cortex哨兵.app/Contents/Resources/installer-manifest.json
installer_sha256=fb2d461ca3831754e5bcd4ed10a5718a1477dba25704fb5f327c1cb5de54135a
$ jq empty "$fixture/Cortex哨兵.app/Contents/Resources/installer-manifest.json"
manifest_json: PASS
$ missing_fixture=$(mktemp -d /tmp/cor1940-integrity-missing.XXXXXX)
$ mkdir -p "$missing_fixture/Cortex哨兵.app/Contents/Resources"
$ /bin/bash scripts/install-app.sh --verify-installer-integrity --app-source "$missing_fixture/Cortex哨兵.app"
失败：app 内缺少安装器完整性清单：/tmp/cor1940-integrity-missing.FMhQS4/Cortex哨兵.app/Contents/Resources/installer-manifest.json
# 退出码 1
$ /bin/bash scripts/install-app.sh --verify-installer-integrity --app-source "$fixture/Cortex哨兵.app"
安装器完整性校验通过：sha256=fb2d461ca3831754e5bcd4ed10a5718a1477dba25704fb5f327c1cb5de54135a
$ expected_sha256="$(shasum -a 256 scripts/install-app.sh | awk '{print $1}')"
$ plutil -replace installer_sha256 -string "${expected_sha256%?}0" "$fixture/Cortex哨兵.app/Contents/Resources/installer-manifest.json"
$ /bin/bash scripts/install-app.sh --verify-installer-integrity --app-source "$fixture/Cortex哨兵.app"
失败：安装器完整性校验不匹配：manifest=fb2d461ca3831754e5bcd4ed10a5718a1477dba25704fb5f327c1cb5de541350，实际=fb2d461ca3831754e5bcd4ed10a5718a1477dba25704fb5f327c1cb5de54135a，文件=/Users/falcon/Documents/Code/cortex-sentinel-worktrees/cor1940-installer-integrity/scripts/install-app.sh
# 退出码 1
```

## 5. Swift 回归测试

```text
$ swift test
Test Suite 'All tests' passed ...
    Executed 325 tests, with 0 failures (0 unexpected)
```

本次实际运行数字为 **325 tests / 0 failures**；耗时约 67.2 秒。

## 6. 主控篡改实证步骤（可抄）

### A. 改安装器脚本 1 个字节

1. 主控完成正式出包并挂载 DMG，记下卷挂载点 `VOLUME`。
2. 为保持原签名 app 不变，把卷内容复制到临时目录：

   ```bash
   payload="$(mktemp -d /tmp/cor1940-tamper.XXXXXX)"
   ditto "$VOLUME" "$payload/Cortex 哨兵"
   mkdir -p "$payload/watch"
   ```

3. 只改 `scripts/install-app.sh` 的一个注释字节（语法保持有效）：

   ```bash
   python3 - "$payload/Cortex 哨兵/scripts/install-app.sh" <<'PY'
   from pathlib import Path
   import sys
   p = Path(sys.argv[1])
   b = bytearray(p.read_bytes())
   marker = b"# 构建、安装并托管唯一一份"
   i = b.index(marker) + 2
   b[i] = ord("X")
   p.write_bytes(b)
   PY
   ```

4. 执行临时副本的入口：

   ```bash
   CORTEX_SENTINEL_WATCH_DIR="$payload/watch" \
     bash "$payload/Cortex 哨兵/Install-Cortex-Sentinel.command"
   ```

   预期在任何安装动作前看到：

   ```text
   失败：安装器完整性校验不匹配：manifest=<app 内原哈希>，实际=<篡改脚本哈希>，文件=<payload>/Cortex 哨兵/scripts/install-app.sh
   安装未完成，退出码：1
   ```

### B. 把 app 内 manifest 改成篡改后的新哈希

在同一份临时副本中执行：

```bash
actual="$(shasum -a 256 "$payload/Cortex 哨兵/scripts/install-app.sh" | awk '{print $1}')"
plutil -replace installer_sha256 -string "$actual" \
  "$payload/Cortex 哨兵.app/Contents/Resources/installer-manifest.json"
CORTEX_SENTINEL_WATCH_DIR="$payload/watch" \
  bash "$payload/Cortex 哨兵/Install-Cortex-Sentinel.command"
```

预期 `codesign --verify --deep --strict` 先报 `a sealed resource is missing or invalid`（不同 macOS 小版本前缀可能不同），安装器随后以非零状态结束；完整性比较阶段不会被到达。这证明“顺手改 manifest”这条绕过路径被签名封装截断。
