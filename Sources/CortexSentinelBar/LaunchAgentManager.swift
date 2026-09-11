import Foundation

/// LaunchAgent 托管：拖进 /Applications 首次启动自装，设置里的
/// 「开机时自动启动」开关负责装 / 卸。取代老流程的 Install-*.command 脚本。
enum LaunchAgentManager {
    static let label = LoginItemConstants.launchAgentLabel

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("LaunchAgents")
            .appendingPathComponent("\(label).plist")
    }

    static func isInstalled(fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: plistURL.path)
    }

    /// 生成 LaunchAgent 内容：KeepAlive + Interactive，跟老安装器一致。
    static func makePlist(executablePath: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executablePath],
            "KeepAlive": true,
            "ProcessType": "Interactive",
        ]
    }

    /// 自装条件：以 /Applications 里的 bundle 形态运行，且不是诊断 CLI。
    /// 直接从 DMG 里跑或 debug 二进制都不装，免得把临时路径钉进 launchd。
    static func canSelfInstall(
        bundlePath: String? = Bundle.main.bundlePath,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        guard let bundlePath, bundlePath.hasSuffix(".app"),
              bundlePath.hasPrefix("/Applications/") else {
            return false
        }
        return LoginItemRuntime.diagnosticArguments.isDisjoint(with: arguments)
    }

    /// 首启自装：plist 不存在才写并挂载。幂等，条件不满足时静默跳过。
    @discardableResult
    static func installOnFirstLaunch(
        fileManager: FileManager = .default,
        runner: (String, [String]) throws -> Void = runLaunchctl
    ) -> Bool {
        guard canSelfInstall(), !isInstalled(fileManager: fileManager) else {
            return false
        }
        return install(fileManager: fileManager, runner: runner)
    }

    /// 写 plist 并挂载；已挂载的先卸再挂，幂等。
    @discardableResult
    static func install(
        fileManager: FileManager = .default,
        runner: (String, [String]) throws -> Void = runLaunchctl
    ) -> Bool {
        guard canSelfInstall(), let executable = Bundle.main.executableURL?.path else {
            return false
        }
        return writeAndBootstrap(executablePath: executable, fileManager: fileManager, runner: runner)
    }

    /// 开关关闭：只删 plist，不 bootout——bootout 会把正在跑的哨兵一起杀掉。
    /// 当前会话照常运行，下次开机不再拉起。
    @discardableResult
    static func removePlist(fileManager: FileManager = .default) -> Bool {
        guard fileManager.fileExists(atPath: plistURL.path) else {
            return false
        }
        do {
            try fileManager.removeItem(at: plistURL)
            return true
        } catch {
            return false
        }
    }

    private static func writeAndBootstrap(
        executablePath: String,
        fileManager: FileManager,
        runner: (String, [String]) throws -> Void
    ) -> Bool {
        let plist: [String: Any] = makePlist(executablePath: executablePath)
        let data: Data
        do {
            data = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
        } catch {
            return false
        }
        do {
            try fileManager.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: plistURL, options: .atomic)
        } catch {
            return false
        }
        let uid = getuid()
        _ = try? runner("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        do {
            try runner("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistURL.path])
            return true
        } catch {
            return false
        }
    }

    private static func runLaunchctl(_ path: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LaunchAgentError.nonZeroExit
        }
    }
}

enum LaunchAgentError: Error {
    case nonZeroExit
}
