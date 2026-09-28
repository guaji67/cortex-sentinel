import CryptoKit
import Foundation

/// 哨兵自更新。更新源是 GitHub Releases（不用储存桶不用域名，发布链路现成）：
///   GET /releases/latest → 拿最新正式版（draft / pre-release 天然排除）
///   下载 DMG → sha256 校验 → spctl 终验 → 跑 DMG 自带的 install-app.sh
///   （它负责换 /Applications 里的 app、重挂 launchd 并重启哨兵）。
/// 自动安装默认关：关着发现新版本只发系统通知提醒，开着才静默走完全程。
/// 哨兵是监控软件，被安装脚本重启不算事。
enum SentinelUpdateConstants {
    static let repositoryOwner = "guaji67"
    static let repositoryName = "cortex-sentinel"
    static var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(repositoryOwner)/\(repositoryName)/releases/latest")!
    }
    /// 更新是慢变量：跟官方额度同一定时器走，最短隔这么久才真查一次。
    static let checkInterval: TimeInterval = 60 * 60
    static let requestTimeout: TimeInterval = 15
    /// DMG 几 MB 到十几 MB，弱网下放宽。
    static let downloadTimeout: TimeInterval = 15 * 60
    static let versionTagPrefix = "v"
    /// 安装位所在目录：换装的暂存、旧版挪存、正式位都在这同一卷上，rename 才原子。
    static let applicationsDirectory = "/Applications"
    /// 资产命名与 build-release.sh 产物一致（GitHub 资产名用 ASCII，避开中文文件名的各种坑）。
    static func dmgAssetName(version: String) -> String { "Cortex.-\(version).dmg" }
    static func shaAssetName(version: String) -> String { "Cortex.-\(version).dmg.sha256" }
}

/// 一条可安装的更新。
struct SentinelUpdateInfo: Equatable, Sendable {
    let version: String
    let notes: String?
    let dmgURL: URL
    let dmgName: String
    let shaURL: URL?
    let checkedAt: Date
}

enum SentinelUpdateError: Error, Equatable {
    case network
    case unauthorized
    case invalidResponse
    case assetMissing
    case downloadFailed
    case shaMismatch
    case gateRejected
    case installScriptFailed
    case invalidStatus

    var userMessage: String {
        switch self {
        case .network:
            return "更新源暂不可达"
        case .unauthorized:
            return "更新源访问被拒"
        case .invalidResponse:
            return "更新源返回无法解析"
        case .assetMissing:
            return "新版本缺少安装包"
        case .downloadFailed:
            return "安装包下载失败"
        case .shaMismatch:
            return "安装包校验不过，已放弃更新"
        case .gateRejected:
            return "新版本未通过系统安全校验，已放弃更新"
        case .installScriptFailed:
            return "换装脚本执行失败"
        case .invalidStatus:
            return "更新服务返回异常状态"
        }
    }
}

// MARK: - 版本比较

enum SentinelUpdateVersion {
    /// 解析 x.y.z / v x.y.z；解析不了返回 nil（当未知版本处理）。
    static func parse(_ text: String) -> (major: Int, minor: Int, patch: Int)? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(SentinelUpdateConstants.versionTagPrefix) {
            trimmed.removeFirst()
        }
        let parts = trimmed.split(separator: ".")
        guard parts.count == 3 else {
            return nil
        }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 3 else {
            return nil
        }
        return (numbers[0], numbers[1], numbers[2])
    }

    /// 去掉 tag 前缀 v，返回纯净的 x.y.z 字符串；形状不对返回 nil。
    static func normalizedVersion(from tag: String) -> String? {
        guard parse(tag) != nil else {
            return nil
        }
        var trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(SentinelUpdateConstants.versionTagPrefix) {
            trimmed.removeFirst()
        }
        return trimmed
    }

    /// 只认严格更新：相同或更旧的 tag 不动。解析不了的候选一律不更。
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidateVersion = parse(candidate), let currentVersion = parse(current) else {
            return false
        }
        if candidateVersion.major != currentVersion.major {
            return candidateVersion.major > currentVersion.major
        }
        if candidateVersion.minor != currentVersion.minor {
            return candidateVersion.minor > currentVersion.minor
        }
        return candidateVersion.patch > currentVersion.patch
    }

    /// 算不算更新（候选 tag、当前短版本、当前构建号三件套）：
    /// 候选解析不了的不更；当前包是开发构建（判定在 SentinelAppVersion，
    /// 与设置窗版本行同一把尺）时任何一个合法正式版都算更新——开发版装上后
    /// 下一轮检查就升回正式版；正式版之间照旧严格比大小。
    static func shouldUpdate(_ candidate: String, current: String, build: String) -> Bool {
        guard parse(candidate) != nil else {
            return false
        }
        if SentinelAppVersion.isDevelopmentBuild(shortVersion: current, bundleVersion: build) {
            return true
        }
        return isNewer(candidate, than: current)
    }
}

// MARK: - 网络层

protocol SentinelUpdateLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: SentinelUpdateLoading {}

/// 从 GitHub Releases 拉最新正式版信息。
struct SentinelUpdateChecker: Sendable {
    private let endpoint: URL
    private let currentVersion: String
    private let currentBuild: String
    private let loader: any SentinelUpdateLoading

    init(
        endpoint: URL = SentinelUpdateConstants.latestReleaseURL,
        currentVersion: String = SentinelUpdateVersion.current,
        currentBuild: String = SentinelUpdateVersion.currentBuild,
        loader: any SentinelUpdateLoading = URLSession.shared
    ) {
        self.endpoint = endpoint
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
        self.loader = loader
    }

    /// 有更新返回 SentinelUpdateInfo；已是最新返回 nil；接口挂了抛错（调用方静默）。
    func fetchLatest() async throws -> SentinelUpdateInfo? {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = SentinelUpdateConstants.requestTimeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CortexSentinel/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await loader.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SentinelUpdateError.invalidResponse
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw SentinelUpdateError.unauthorized
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SentinelUpdateError.invalidStatus
        }
        return try Self.parse(data: data, currentVersion: currentVersion, currentBuild: currentBuild)
    }

    static func parse(data: Data, currentVersion: String, currentBuild: String) throws -> SentinelUpdateInfo? {
        guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
            throw SentinelUpdateError.invalidResponse
        }
        guard let version = SentinelUpdateVersion.normalizedVersion(from: release.tagName),
              SentinelUpdateVersion.shouldUpdate(release.tagName, current: currentVersion, build: currentBuild),
              let asset = release.asset(named: SentinelUpdateConstants.dmgAssetName(version: version))
        else {
            return nil
        }
        return SentinelUpdateInfo(
            version: version,
            notes: release.body,
            dmgURL: asset.browserDownloadURL,
            dmgName: asset.name,
            shaURL: release.asset(named: SentinelUpdateConstants.shaAssetName(version: version))?.browserDownloadURL,
            checkedAt: Date()
        )
    }
}

struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let body: String?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case assets
    }

    func asset(named name: String) -> Asset? {
        assets.first { $0.name == name }
    }

    struct Asset: Decodable, Sendable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}

extension SentinelUpdateVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// 当前包构建号（CFBundleVersion）。缺了按开发版处理，与设置窗版本行同口径。
    static var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? SentinelAppVersion.devBundleVersion
    }
}

// MARK: - 下载 / 校验 / 换装

protocol SentinelShellRunning: Sendable {
    func run(launchPath: String, arguments: [String]) throws -> (stdout: String, status: Int32)
}

struct SentinelShellRunner: SentinelShellRunning {
    func run(launchPath: String, arguments: [String]) throws -> (stdout: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            stdout: String(data: data, encoding: .utf8) ?? "",
            status: process.terminationStatus
        )
    }
}

/// 下载 → sha256 → spctl 闸 → 一次性 launchd 任务换装重启。步骤拆开注入，测试不连网。
///
/// 为什么换装要经 launchd 任务：install-app.sh 会 bootout 停掉哨兵，而 launchd
/// 停任务时杀的是整个进程组——换装脚本若是哨兵的子进程就跟着陪葬（0.1.8 首次
/// 自更新实锤：DMG 已挂载、脚本死在换装前，哨兵停机 + 任务被卸）。把换装挂到
/// 独立的一次性任务里，哨兵死活与它无关；这也是 Sparkle 官方对 launchd agent
/// 场景不支持后，社区通行的自更新做法。
struct SentinelUpdateInstaller: Sendable {
    private let loader: any SentinelUpdateLoading
    private let shell: any SentinelShellRunning
    private let workDirectory: URL
    /// 一次性换装任务的 plist 落点；测试注入临时目录。
    private let updateJobPlistURL: URL
    /// 主任务的 plist 路径，换装失败自愈时补 bootstrap 用。
    private let mainJobPlistPath: String
    /// DMG 挂载点解析；独立出来是为了测试替身。
    private let mountPointResolver: @Sendable (String) -> String?

    static let mainJobLabel = "com.cortex.sentinelbar"
    static let updateJobLabel = "com.cortex.sentinelbar.update"

    init(
        loader: any SentinelUpdateLoading = URLSession.shared,
        shell: any SentinelShellRunning = SentinelShellRunner(),
        workDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cortex-sentinel-update", isDirectory: true),
        updateJobPlistURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Self.updateJobLabel).plist"),
        mainJobPlistPath: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.cortex.sentinelbar.plist").path,
        mountPointResolver: @escaping @Sendable (String) -> String? = Self.hdiutilMountPoint
    ) {
        self.loader = loader
        self.shell = shell
        self.workDirectory = workDirectory
        self.updateJobPlistURL = updateJobPlistURL
        self.mainJobPlistPath = mainJobPlistPath
        self.mountPointResolver = mountPointResolver
    }

    /// 完整更新流程：下载校验 + 换装重启。脚本会重启哨兵，正常情况下
    /// 走到 install 这步本进程就没了。
    func install(_ update: SentinelUpdateInfo) async throws {
        let dmgURL = try await prepare(update)
        try commit(dmgURL: dmgURL)
    }

    /// 前半段：下载 DMG + sha256 校验。纯下载不碰系统，失败随时可重试。
    /// 返回本地 DMG 路径，交给 commit。
    func prepare(_ update: SentinelUpdateInfo) async throws -> URL {
        let dmgURL = try await download(update)
        try await verifySha256(dmgURL: dmgURL, shaURL: update.shaURL)
        return dmgURL
    }

    /// 后半段：挂载 → 系统安全闸 → 移交一次性 launchd 任务执行换装。
    /// 传入 prepare 返回的本地 DMG 路径。成功移交后 DMG 保持挂载，
    /// 由换装任务用完自行卸载；移交失败则这里负责卸载干净。
    func commit(dmgURL: URL) throws {
        let attachOutput = try shell.run(
            launchPath: "/usr/bin/hdiutil",
            arguments: ["attach", "-readonly", "-nobrowse", "-plist", dmgURL.path]
        ).stdout
        guard let mountPoint = mountPointResolver(attachOutput) else {
            throw SentinelUpdateError.installScriptFailed
        }
        var handedOff = false
        defer {
            if !handedOff {
                _ = try? shell.run(launchPath: "/usr/bin/hdiutil", arguments: ["detach", mountPoint])
            }
        }

        let appPath = mountPoint + "/Cortex哨兵.app"
        // 安全闸：不是 Developer ID 签名且系统认可的包，一个字节都不许换上来。
        let gate = try shell.run(launchPath: "/usr/sbin/spctl", arguments: ["-a", "-vv", "-t", "exec", appPath])
        guard gate.status == 0 else {
            throw SentinelUpdateError.gateRejected
        }
        handedOff = try handOffToLaunchdInstaller(mountPoint: mountPoint, appPath: appPath)
    }

    // MARK: - 换装脚本

    /// 换装脚本调用的外部命令。测试注入替身：false/true 当必败/必成，
    /// mv 包一层让第二个换名失败，launchctl 用 stub 回固定 pid。
    struct SwapScriptTools: Sendable {
        var ditto = "/usr/bin/ditto"
        var codesign = "/usr/bin/codesign"
        var spctl = "/usr/sbin/spctl"
        var mv = "/bin/mv"
        var launchctl = "/bin/launchctl"
    }

    /// 同卷暂存路径，每次换装开头先清掉上次的残留。
    static func incomingStagingPath(appsDirectory: String) -> String {
        appsDirectory + "/.Cortex哨兵.app.incoming"
    }

    /// 旧版挪存路径：换名时旧版先挪到这儿，新版起来才删，留着兜底回滚。
    static func previousBackupPath(appsDirectory: String) -> String {
        appsDirectory + "/.Cortex哨兵.app.previous"
    }

    /// 安装位可执行文件路径：停发起实例前先核它的可执行文件是不是这里，
    /// 不是就不动它（pid 可能被复用，杀错人比停不掉更糟）。
    static func expectedExecutablePath(appsDirectory: String) -> String {
        appsDirectory + "/Cortex哨兵.app/Contents/MacOS/CortexSentinelBar"
    }

    /// 生成换装脚本。路径、命令、超时全部可注入，单测拿临时目录代替 /Applications 真跑。
    ///
    /// 流程：卸主任务 → 清上次残留 → 停发起实例（bootout 只停开机任务名下的，
    /// 停不到的老实例按 pid 补刀：核可执行文件路径是安装位才发 TERM，超时不退再
    /// KILL；路径不对就不动它、记一行）→ ditto 暂存 → codesign + spctl 验签
    /// （不过删暂存、留旧版、拉回主任务、exit 非零）→ 旧版 mv 到 .previous、
    /// 暂存 mv 上正式位（同卷 rename，原子；第二个 mv 失败把 .previous 挪回来）
    /// → 拉主任务 → 核新版 pid 已换且在开机任务名下（不符记日志、.previous 留着）
    /// → 删 .previous。每步 echo，launchd 的 StandardOutPath 把 stdout 落进
    /// update-job.log。
    static func makeSwapScript(
        appsDirectory: String,
        newAppPath: String,
        mountPoint: String,
        mainJobPlistPath: String,
        updateJobPlistPath: String,
        mainJobLabel: String,
        updateJobLabel: String,
        uid: UInt32,
        initiatingPid: Int32,
        tools: SwapScriptTools = SwapScriptTools(),
        stopTimeoutSeconds: Int = 15,
        postCheckTimeoutSeconds: Int = 15
    ) -> String {
        let appPath = appsDirectory + "/Cortex哨兵.app"
        let incomingPath = incomingStagingPath(appsDirectory: appsDirectory)
        let previousPath = previousBackupPath(appsDirectory: appsDirectory)
        let expectedBinaryPath = expectedExecutablePath(appsDirectory: appsDirectory)
        return """
        # launchd 不给 LANG / LC_*：C 语言环境下 ps 会把路径里的中文转义成 M-e…，
        # 跟 EXPECTED_BIN 永远比不上，发起实例就停不掉。整段脚本钉 UTF-8。
        export LC_ALL=en_US.UTF-8
        log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
        APP='\(appPath)'
        INCOMING='\(incomingPath)'
        PREVIOUS='\(previousPath)'
        EXPECTED_BIN='\(expectedBinaryPath)'
        INIT_PID=\(initiatingPid)

        start_main() {
          if [ -f '\(mainJobPlistPath)' ]; then
            \(tools.launchctl) bootstrap gui/\(uid) '\(mainJobPlistPath)' >/dev/null 2>&1 || true
            log "main job bootstrapped from plist"
          else
            /usr/bin/open '\(appPath)' >/dev/null 2>&1 || true
            log "app opened directly, no main job plist"
          fi
        }

        finish() {
          /usr/bin/hdiutil detach '\(mountPoint)' >/dev/null 2>&1 || true
          rm -f '\(updateJobPlistPath)' >/dev/null 2>&1 || true
          \(tools.launchctl) bootout gui/\(uid)/\(updateJobLabel) >/dev/null 2>&1 || true
          exit "$1"
        }

        stop_initiating_instance() {
          kill -TERM "$INIT_PID" 2>/dev/null || true
          waited=0
          while [ "$waited" -lt \(stopTimeoutSeconds) ]; do
            st="$(ps -o stat= -p "$INIT_PID" 2>/dev/null)"
            if [ -z "$st" ] || case "$st" in Z*) true ;; *) false ;; esac; then
              return 0
            fi
            sleep 1
            waited=$((waited + 1))
          done
          kill -KILL "$INIT_PID" 2>/dev/null || true
        }

        log "step1 bootout main job \(mainJobLabel)"
        \(tools.launchctl) bootout gui/\(uid)/\(mainJobLabel) >/dev/null 2>&1 || true

        rm -rf "$INCOMING" "$PREVIOUS" 2>/dev/null || log "step2 leftover cleanup failed, continue anyway"
        log "step2 leftover staging and previous cleared"

        if kill -0 "$INIT_PID" 2>/dev/null; then
          RUNNING="$(ps -p "$INIT_PID" -o comm= 2>/dev/null)"
          if [ -z "$RUNNING" ]; then
            log "step3 initiating pid $INIT_PID gone between checks"
          elif [ "$RUNNING" = "$EXPECTED_BIN" ]; then
            log "step3 stopping initiating instance pid=$INIT_PID from $RUNNING"
            stop_initiating_instance
            log "step3 initiating instance stopped"
          else
            log "step3 initiating pid $INIT_PID runs from '$RUNNING' not the installed app, leave it alone"
          fi
        else
          log "step3 initiating pid $INIT_PID already stopped by main job bootout"
        fi

        \(tools.ditto) '\(newAppPath)' "$INCOMING"
        rc=$?
        if [ "$rc" -ne 0 ]; then
          log "step4 ditto staging failed rc=$rc, keep current version"
          rm -rf "$INCOMING" 2>/dev/null || true
          start_main
          finish "$rc"
        fi
        log "step4 new app staged at $INCOMING"

        \(tools.codesign) --verify --deep --strict "$INCOMING"
        rc=$?
        if [ "$rc" -ne 0 ]; then
          log "step5 codesign verify failed rc=$rc, keep current version"
          rm -rf "$INCOMING" 2>/dev/null || true
          start_main
          finish "$rc"
        fi
        \(tools.spctl) -a -t exec "$INCOMING"
        rc=$?
        if [ "$rc" -ne 0 ]; then
          log "step5 spctl rejected staged app rc=$rc, keep current version"
          rm -rf "$INCOMING" 2>/dev/null || true
          start_main
          finish "$rc"
        fi
        log "step5 staged app passed codesign and spctl"

        if [ -d "$APP" ]; then
          \(tools.mv) "$APP" "$PREVIOUS" || {
            log "step6 could not move old app aside, keep current version"
            start_main
            finish 1
          }
          log "step6 old app moved to $PREVIOUS"
        fi
        \(tools.mv) "$INCOMING" "$APP"
        rc=$?
        if [ "$rc" -ne 0 ]; then
          log "step6 rename staged app into place failed rc=$rc, rolling back"
          rm -rf "$INCOMING" 2>/dev/null || true
          if [ -d "$PREVIOUS" ]; then
            if \(tools.mv) "$PREVIOUS" "$APP"; then
              log "step6 old app restored from previous"
            else
              log "step6 FAILED to restore old app from previous"
            fi
          fi
          start_main
          finish 1
        fi
        log "step6 staged app moved into place by atomic rename"

        start_main
        log "step7 main job started with new version"

        new_pid=""
        waited=0
        while [ "$waited" -lt \(postCheckTimeoutSeconds) ]; do
          if [ -f '\(mainJobPlistPath)' ]; then
            new_pid="$(
              \(tools.launchctl) print gui/\(uid)/\(mainJobLabel) 2>/dev/null |
                grep -E '^[[:space:]]*pid = ' | head -1 | grep -oE '[0-9]+' | head -1
            )"
          else
            new_pid="$(/usr/bin/pgrep -f "$EXPECTED_BIN" 2>/dev/null | head -1)"
          fi
          if [ -n "$new_pid" ]; then
            break
          fi
          sleep 1
          waited=$((waited + 1))
        done
        if [ -n "$new_pid" ] && [ "$new_pid" != "$INIT_PID" ]; then
          log "step8 postcheck ok: new pid=$new_pid under main job, old pid was $INIT_PID"
          rm -rf "$PREVIOUS" 2>/dev/null || true
          log "step9 previous backup removed"
        else
          log "step8 postcheck FAILED: new_pid='$new_pid' old_pid=$INIT_PID, keeping previous backup for rollback"
        fi

        finish 0
        """
    }

    /// 写一次性换装任务的 plist 并 bootstrap。任务自带收尾：
    /// 失败补拉主任务、卸载 DMG、删自己的 plist、bootout 自己。
    /// 换装全程走暂存 + 验签 + 原子换名（makeSwapScript），不再先删再拷；
    /// 发起更新的就是本实例，把自己的 pid 一并传进脚本，
    /// bootout 停不到的在跑老实例由脚本按 pid 补停。
    private func handOffToLaunchdInstaller(mountPoint: String, appPath: String) throws -> Bool {
        let uid = getuid()
        let script = Self.makeSwapScript(
            appsDirectory: SentinelUpdateConstants.applicationsDirectory,
            newAppPath: appPath,
            mountPoint: mountPoint,
            mainJobPlistPath: mainJobPlistPath,
            updateJobPlistPath: updateJobPlistURL.path,
            mainJobLabel: Self.mainJobLabel,
            updateJobLabel: Self.updateJobLabel,
            uid: uid,
            initiatingPid: ProcessInfo.processInfo.processIdentifier
        )
        let plist: [String: Any] = [
            "Label": Self.updateJobLabel,
            "ProgramArguments": ["/bin/bash", "-c", script],
            "RunAtLoad": true,
            "StandardOutPath": workDirectory.appendingPathComponent("update-job.log").path,
            "StandardErrorPath": workDirectory.appendingPathComponent("update-job.log").path,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try FileManager.default.createDirectory(
            at: updateJobPlistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: updateJobPlistURL, options: .atomic)

        // 上一次的换装任务若还挂着先卸掉，再挂新的。
        _ = try? shell.run(
            launchPath: "/bin/launchctl",
            arguments: ["bootout", "gui/\(uid)/\(Self.updateJobLabel)"]
        )
        let boot = try shell.run(
            launchPath: "/bin/launchctl",
            arguments: ["bootstrap", "gui/\(uid)", updateJobPlistURL.path]
        )
        guard boot.status == 0 else {
            throw SentinelUpdateError.installScriptFailed
        }
        return true
    }

    /// 下载好的本地 DMG 是否还有效（文件在且非空）。重启后临时目录可能被清。
    func preparedDMGIsValid(at url: URL) -> Bool {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int else {
            return false
        }
        return size > 0
    }

    /// 换装失败后的自愈：一次性任务失败时可能已经 bootout 卸了主任务，
    /// 不兜底哨兵就躺平了。先补 bootstrap（任务还在位时该步报错无所谓），
    /// 再 kickstart 强制拉起。
    func recoverAfterFailedInstall() {
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.cortex.sentinelbar.plist").path
        _ = try? shell.run(
            launchPath: "/bin/launchctl",
            arguments: ["bootstrap", "gui/\(getuid())", plistPath]
        )
        _ = try? shell.run(
            launchPath: "/bin/launchctl",
            arguments: ["kickstart", "-k", "gui/\(getuid())/com.cortex.sentinelbar"]
        )
    }

    private func download(_ update: SentinelUpdateInfo) async throws -> URL {
        var request = URLRequest(url: update.dmgURL)
        request.timeoutInterval = SentinelUpdateConstants.downloadTimeout
        request.setValue("CortexSentinel/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await loader.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode), !data.isEmpty
        else {
            throw SentinelUpdateError.downloadFailed
        }
        let fileURL = workDirectory.appendingPathComponent(update.dmgName)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    /// sha 资产是 shasum 输出格式：`<hex>  <文件名>`。缺资产或对不上都拒装。
    private func verifySha256(dmgURL: URL, shaURL: URL?) async throws {
        guard let shaURL else {
            throw SentinelUpdateError.assetMissing
        }
        var request = URLRequest(url: shaURL)
        request.timeoutInterval = SentinelUpdateConstants.requestTimeout
        let (data, _) = try await loader.data(for: request)
        guard let expected = Self.sha256Hex(from: String(data: data, encoding: .utf8) ?? "") else {
            throw SentinelUpdateError.assetMissing
        }
        guard let dmgData = try? Data(contentsOf: dmgURL) else {
            throw SentinelUpdateError.downloadFailed
        }
        let digest = SHA256.hash(data: dmgData)
        let actual = digest.map { String(format: "%02x", $0) }.joined()
        guard actual.lowercased() == expected.lowercased() else {
            throw SentinelUpdateError.shaMismatch
        }
    }

    /// `abc123...  Cortex.-0.1.8.dmg` → `abc123...`
    static func sha256Hex(from shasumText: String) -> String? {
        let firstLine = shasumText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        let token = firstLine.trimmingCharacters(in: .whitespaces).split(separator: " ").first
        guard let token, token.count == 64,
              token.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return String(token)
    }

    /// hdiutil -plist 输出里挖挂载点。
    static func hdiutilMountPoint(_ plistText: String) -> String? {
        guard let data = plistText.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else {
            return nil
        }
        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String, !mountPoint.isEmpty {
                return mountPoint
            }
        }
        return nil
    }
}
