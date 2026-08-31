import AppKit
import Darwin
import Foundation
import ServiceManagement

/// 开机自启唯一由安装器写入 LaunchAgent；app 只读取托管状态，不注册登录项。
///
/// 「是不是 launchd 托管」用三个独立信号，**至少两个为真**才判定托管：
///   1. `~/Library/LaunchAgents/com.cortex.sentinelbar.plist` 存在、Label 对得上、
///      ProgramArguments 指向**当前这份**可执行文件 / 同一个 `.app`
///   2. 父进程是 launchd（ppid == 1；本机正式实例已核过）
///   3. plist 里写入的环境变量（`CORTEX_SENTINEL_WATCH_DIR` / `CORTEX_REPO_ROOT`）
///      与当前进程环境一致——说明这份进程是按那张 plist 拉起来的
///
/// 任一信号单独为真都**不**下「托管」结论：
///   - 只有 2：Finder / LaunchServices 拉起的 app 父进程也经常是 launchd，
///     拖拽安装用户正是这种情况，必须还能注册登录项
///   - 只有 1：开发者在终端里直接跑 `/Applications/.../CortexSentinelBar` 时
///     会撞上；菜单栏常驻仍可能去注册。CLI（`--dump-state` 等）不会注册。
///   - 只有 3：shell 里 export 了同样的监视目录变量，跟 launchd 无关
///
/// 两个信号都失效时：若还剩一个真信号，按「未托管」走（可能误注册）；
/// 若三个全灭，拖拽安装用户会去注册，这是要的。
/// Falcon 正式实例三个信号都会亮，单个探测抖动不会让它去注册登录项。
///
/// 判定为托管 → 什么都不做：不 `register`，也不去动那张 plist。
enum LoginItemConstants {
    static let launchAgentLabel = "com.cortex.sentinelbar"
    static let copyEnabled = "已开机自启"
    static let copyDisabled = "开机自启"
    static let copySystemManaged = "自启由系统托管"
}

struct LaunchdSupervisionSignals: Equatable {
    var plistTargetsThisApp: Bool
    var parentIsLaunchd: Bool
    var environmentMatchesPlist: Bool

    var matchingCount: Int {
        [plistTargetsThisApp, parentIsLaunchd, environmentMatchesPlist].filter { $0 }.count
    }

    var isLaunchdManaged: Bool {
        matchingCount >= 2
    }

    static let none = LaunchdSupervisionSignals(
        plistTargetsThisApp: false,
        parentIsLaunchd: false,
        environmentMatchesPlist: false
    )
}

struct LaunchdSupervisionDetails: Equatable {
    var plistPath: String
    var plistExists: Bool
    var labelMatches: Bool
    var programArgumentsTargetThisApp: Bool
    var parentProcessID: Int32
    var parentIsLaunchd: Bool
    var environmentMatchesPlist: Bool

    var signals: LaunchdSupervisionSignals {
        LaunchdSupervisionSignals(
            plistTargetsThisApp: plistExists && labelMatches && programArgumentsTargetThisApp,
            parentIsLaunchd: parentIsLaunchd,
            environmentMatchesPlist: environmentMatchesPlist
        )
    }
}

enum LoginItemRegistrationStatus: Equatable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
    case unknown

    var dumpName: String {
        switch self {
        case .enabled:
            return "enabled"
        case .notRegistered:
            return "notRegistered"
        case .requiresApproval:
            return "requiresApproval"
        case .notFound:
            return "notFound"
        case .unknown:
            return "unknown"
        }
    }

    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled:
            self = .enabled
        case .requiresApproval:
            self = .requiresApproval
        case .notFound:
            self = .notFound
        case .notRegistered:
            self = .notRegistered
        @unknown default:
            self = .unknown
        }
    }
}

enum LoginItemPanelKind: Equatable {
    case enabled
    case disabled
    case systemManaged
}

struct LoginItemPanelPresentation: Equatable {
    var kind: LoginItemPanelKind
    var copy: String
    var showsToggle: Bool

    static let enabled = LoginItemPanelPresentation(
        kind: .enabled,
        copy: LoginItemConstants.copyEnabled,
        showsToggle: false
    )
    static let disabled = LoginItemPanelPresentation(
        kind: .disabled,
        copy: LoginItemConstants.copyDisabled,
        showsToggle: true
    )
    static let systemManaged = LoginItemPanelPresentation(
        kind: .systemManaged,
        copy: LoginItemConstants.copySystemManaged,
        showsToggle: false
    )
}

enum LoginItemReconcileAction: Equatable {
    case none
    case register
    case unregister
}

struct LoginItemReconcilePlan: Equatable {
    var presentation: LoginItemPanelPresentation
    var action: LoginItemReconcileAction
}

protocol LoginItemRegistrar {
    var status: LoginItemRegistrationStatus { get }
    func register() throws
    func unregister() throws
}

struct SMAppServiceLoginItemRegistrar: LoginItemRegistrar {
    var status: LoginItemRegistrationStatus {
        LoginItemRegistrationStatus(SMAppService.mainApp.status)
    }

    func register() throws {
        // COR-2550：保留协议供旧测试/诊断编译，产品路径不再调用 SMAppService。
    }

    func unregister() throws {
        // COR-2550：登录项清理由 install-app.sh / uninstall-app.sh 按路径完成。
    }
}

enum LoginItemReconciler {
    static func plan(
        signals: LaunchdSupervisionSignals,
        status: LoginItemRegistrationStatus,
        wantsEnabled: Bool = true
    ) -> LoginItemReconcilePlan {
        if signals.isLaunchdManaged {
            return LoginItemReconcilePlan(presentation: .systemManaged, action: .none)
        }
        if !wantsEnabled {
            if status == .enabled {
                return LoginItemReconcilePlan(presentation: .disabled, action: .unregister)
            }
            return LoginItemReconcilePlan(presentation: .disabled, action: .none)
        }
        switch status {
        case .enabled:
            return LoginItemReconcilePlan(presentation: .enabled, action: .none)
        case .requiresApproval:
            return LoginItemReconcilePlan(presentation: .disabled, action: .none)
        case .notRegistered, .notFound, .unknown:
            return LoginItemReconcilePlan(presentation: .disabled, action: .register)
        }
    }

    /// 执行计划。`register` / `unregister` 失败时不抛给调用方。
    static func apply(
        plan: LoginItemReconcilePlan,
        registrar: LoginItemRegistrar
    ) -> LoginItemPanelPresentation {
        switch plan.action {
        case .none:
            return plan.presentation
        case .register:
            do {
                try registrar.register()
            } catch {
                return .disabled
            }
            if registrar.status == .enabled {
                return .enabled
            }
            return .disabled
        case .unregister:
            do {
                try registrar.unregister()
            } catch {
                return registrar.status == .enabled ? .enabled : .disabled
            }
            return .disabled
        }
    }
}

enum LoginItemRuntime {
    static let diagnosticArguments: Set<String> = [
        "--dump-state",
        "--idle-refresh",
        "--smoke-window",
        "--smoke-popover",
        "--smoke-lines",
        "--smoke-expand",
        "--cleanup-dry-run",
        "--cleanup-run",
        "--render-statusbar",
        "--render-settings-png",
        "--render-panel-png",
        "--smoke-settings",
        "--open-settings",
    ]

    /// CLI / smoke / XCTest 以及菜单栏常驻都不注册登录项；唯一注册路是安装器。
    static func shouldReconcileOnLaunch(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil {
            return false
        }
        return false
    }
}

enum LaunchdSupervisionProbe {
    static func plistURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library")
            .appendingPathComponent("LaunchAgents")
            .appendingPathComponent("\(LoginItemConstants.launchAgentLabel).plist")
    }

    static func collectFromCurrentProcess() -> LaunchdSupervisionDetails {
        let executable = Bundle.main.executableURL
            ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let url = plistURL()
        return collect(
            executableURL: executable,
            environment: ProcessInfo.processInfo.environment,
            parentProcessID: getppid(),
            plistURL: url,
            plistData: try? Data(contentsOf: url)
        )
    }

    static func collect(
        executableURL: URL,
        environment: [String: String],
        parentProcessID: Int32,
        plistURL: URL,
        plistData: Data?
    ) -> LaunchdSupervisionDetails {
        let parentIsLaunchd = parentProcessID == 1
        guard let plistData else {
            return LaunchdSupervisionDetails(
                plistPath: plistURL.path,
                plistExists: false,
                labelMatches: false,
                programArgumentsTargetThisApp: false,
                parentProcessID: parentProcessID,
                parentIsLaunchd: parentIsLaunchd,
                environmentMatchesPlist: false
            )
        }

        let parsed = parseAgentPlist(plistData)
        let labelMatches = parsed.label == LoginItemConstants.launchAgentLabel
        let programArgumentsTargetThisApp: Bool
        if labelMatches, let program = parsed.program {
            programArgumentsTargetThisApp = isSameApp(
                executableURL: executableURL,
                programArgument: program
            )
        } else {
            programArgumentsTargetThisApp = false
        }

        let environmentMatchesPlist: Bool
        if labelMatches {
            environmentMatchesPlist = environmentMatches(
                plistEnvironment: parsed.environment,
                processEnvironment: environment
            )
        } else {
            environmentMatchesPlist = false
        }

        return LaunchdSupervisionDetails(
            plistPath: plistURL.path,
            plistExists: true,
            labelMatches: labelMatches,
            programArgumentsTargetThisApp: programArgumentsTargetThisApp,
            parentProcessID: parentProcessID,
            parentIsLaunchd: parentIsLaunchd,
            environmentMatchesPlist: environmentMatchesPlist
        )
    }

    static func isSameApp(executableURL: URL, programArgument: String) -> Bool {
        let listed = URL(fileURLWithPath: programArgument)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let ours = executableURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        if listed.path == ours.path {
            return true
        }
        guard let listedBundle = appBundleURL(containing: listed),
              let ourBundle = appBundleURL(containing: ours)
        else {
            return false
        }
        return listedBundle.path == ourBundle.path
    }

    private static func appBundleURL(containing url: URL) -> URL? {
        var current = url
        for _ in 0..<10 {
            if current.pathExtension == "app" {
                return current.resolvingSymlinksInPath().standardizedFileURL
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return nil
            }
            current = parent
        }
        return nil
    }

    private static func environmentMatches(
        plistEnvironment: [String: String],
        processEnvironment: [String: String]
    ) -> Bool {
        guard !plistEnvironment.isEmpty else {
            return false
        }
        for (key, value) in plistEnvironment {
            if processEnvironment[key] != value {
                return false
            }
        }
        return true
    }

    private static func parseAgentPlist(_ data: Data) -> (
        label: String?,
        program: String?,
        environment: [String: String]
    ) {
        guard let root = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            return (nil, nil, [:])
        }
        let label = root["Label"] as? String
        let arguments = root["ProgramArguments"] as? [String]
        let program = arguments?.first
        let environment = root["EnvironmentVariables"] as? [String: String] ?? [:]
        return (label, program, environment)
    }
}

/// 用户从「应用程序」点图标时要不要弹出菜单栏面板。
///
/// 冷启动：复用 `LaunchdSupervisionProbe` 的托管判定；登录项自动拉起靠
/// Open Application 事件上的 `lgit` / `svit`（没事件也当成自动拉起）。
/// 已经在跑时走 `applicationShouldHandleReopen`，不经过这里，一律弹。
enum PanelOpenPolicy {
    static func shouldPresentOnColdLaunch(
        signals: LaunchdSupervisionSignals,
        automaticallyLaunched: Bool
    ) -> Bool {
        if signals.isLaunchdManaged {
            return false
        }
        if automaticallyLaunched {
            return false
        }
        return true
    }
}

/// 启动当下那条 Apple Event 的摘要。真正读事件只在
/// `applicationWillFinishLaunching`，那时 `currentAppleEvent` 还在。
struct LaunchAppleEventSummary: Equatable {
    /// `keyAELaunchedAsLogInItem` / `'lgit'`
    static let launchedAsLoginItemKeyword: AEKeyword = 0x6C676974
    /// `keyAELaunchedAsServiceItem` / `'svit'`
    static let launchedAsServiceItemKeyword: AEKeyword = 0x73766974

    var launchedAsLoginItem: Bool
    var launchedAsServiceItem: Bool

    var isAutomaticLaunch: Bool {
        launchedAsLoginItem || launchedAsServiceItem
    }

    /// 没有 Open Application 事件 → 典型是 launchd / 登录项静默拉起。
    static func isAutomaticLaunch(_ summary: LaunchAppleEventSummary?) -> Bool {
        summary?.isAutomaticLaunch ?? true
    }

    static func fromCurrentAppleEvent(
        event: NSAppleEventDescriptor? = NSAppleEventManager.shared().currentAppleEvent
    ) -> LaunchAppleEventSummary? {
        guard let event else {
            return nil
        }
        return LaunchAppleEventSummary(
            launchedAsLoginItem: event.paramDescriptor(
                forKeyword: launchedAsLoginItemKeyword
            )?.booleanValue ?? false,
            launchedAsServiceItem: event.paramDescriptor(
                forKeyword: launchedAsServiceItemKeyword
            )?.booleanValue ?? false
        )
    }
}

enum LoginItemDiagnostics {
    static func dumpLines(
        details: LaunchdSupervisionDetails,
        loginItemStatus: LoginItemRegistrationStatus,
        menuBarWouldRegister: Bool
    ) -> [String] {
        [
            "开机自启：",
            "  launchd plist：\(details.plistPath)",
            "  plist 存在：\(yesNo(details.plistExists))",
            "  Label 为本服务：\(yesNo(details.labelMatches))",
            "  ProgramArguments 指向本程序：\(yesNo(details.programArgumentsTargetThisApp))",
            "  父进程是 launchd（ppid=\(details.parentProcessID)）：\(yesNo(details.parentIsLaunchd))",
            "  plist 环境变量与当前进程一致：\(yesNo(details.environmentMatchesPlist))",
            "  命中信号：\(details.signals.matchingCount)/3（≥2 才判定为 launchd 托管）",
            "  判定：\(details.signals.isLaunchdManaged ? "由 launchd 托管" : "未托管")",
            "  SMAppService：\(loginItemStatus.dumpName)",
            "  菜单栏常驻会注册登录项：\(yesNo(menuBarWouldRegister))",
            "  本进程是否注册登录项：否（CLI 只诊断，不调用 register）",
        ]
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "是" : "否"
    }
}
