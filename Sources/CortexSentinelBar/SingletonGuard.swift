import AppKit
import Foundation

struct SentinelRunningApplication: Equatable {
    let processIdentifier: Int32
    let bundleIdentifier: String?
    let localizedName: String?
    let executableName: String?
}

enum SentinelSingletonGuard {
    /// 两个历史身份都视为同一个产品，避免旧包与归一后的包并存。
    static let knownBundleIdentifiers: Set<String> = [
        "com.cortex.sentinelbar",
        "com.falcon.cortex.sentinelbar",
    ]
    static let ownerProcessName = "CortexSentinelBar"
    static let ownerDisplayNames: Set<String> = [ownerProcessName, "Cortex 哨兵"]
    static let duplicateMessage = "Cortex 哨兵已经在运行了，本次启动已退出。"

    static func hasExistingInstance(
        applications: [SentinelRunningApplication],
        currentProcessIdentifier: Int32
    ) -> Bool {
        applications.contains { application in
            guard application.processIdentifier != currentProcessIdentifier else {
                return false
            }
            let matchesBundle = application.bundleIdentifier.map(knownBundleIdentifiers.contains) ?? false
            let matchesOwner = application.executableName.map(ownerDisplayNames.contains) ?? false
                || application.localizedName.map(ownerDisplayNames.contains) ?? false
            return matchesBundle || matchesOwner
        }
    }

    @MainActor
    static func enforce(
        applications: [SentinelRunningApplication]? = nil,
        currentProcessIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        alert: @MainActor @escaping (String) -> Void = presentDuplicateAlert
    ) -> Bool {
        let candidates = applications ?? liveApplications()
        guard hasExistingInstance(
            applications: candidates,
            currentProcessIdentifier: currentProcessIdentifier
        ) else {
            return true
        }
        alert(duplicateMessage)
        return false
    }

    @MainActor
    static func liveApplications() -> [SentinelRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.cortex.sentinelbar")
            .map(snapshot)
            + NSRunningApplication.runningApplications(withBundleIdentifier: "com.falcon.cortex.sentinelbar")
            .map(snapshot)
            + NSWorkspace.shared.runningApplications
            .map(snapshot)
            + processTableApplications()
    }

    private static func snapshot(_ application: NSRunningApplication) -> SentinelRunningApplication {
        SentinelRunningApplication(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            localizedName: application.localizedName,
            executableName: application.executableURL?.lastPathComponent
        )
    }

    /// LaunchAgent 直接 exec 的 LSUIElement 可能没有 LaunchServices 运行记录；
    /// 用一次精确的 `ps` 进程名扫描补齐这个 macOS 边界，不按名称终止任何进程。
    private static func processTableApplications() -> [SentinelRunningApplication] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,comm="]
        process.standardOutput = output
        guard (try? process.run()) != nil else {
            return []
        }
        process.waitUntilExit()
        guard let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return []
        }
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 1, omittingEmptySubsequences: true) { $0 == " " || $0 == "\t" }
            guard fields.count == 2, let pid = Int32(fields[0]) else {
                return nil
            }
            let command = String(fields[1])
            let executableName = URL(fileURLWithPath: command).lastPathComponent
            guard executableName == ownerProcessName else {
                return nil
            }
            return SentinelRunningApplication(
                processIdentifier: pid,
                bundleIdentifier: nil,
                localizedName: nil,
                executableName: executableName
            )
        }
    }

    @MainActor
    private static func presentDuplicateAlert(message: String) {
        // 终端/LaunchAgent 日志是第二条可见通道；即使 WindowServer 暂时不展示模态框，
        // 启动者也能看到拒绝原因，而不是把它误判成静默秒退。
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.finishLaunching()
        application.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Cortex 哨兵已在运行"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.window.center()
        alert.window.level = .floating
        alert.window.makeKeyAndOrderFront(nil)
        alert.runModal()
    }
}
