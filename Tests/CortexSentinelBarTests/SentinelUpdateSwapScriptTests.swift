import XCTest
@testable import CortexSentinelBar

/// 换装脚本真跑测试：临时目录代替 /Applications，外部命令可注入替身
/// （false 当必败、true 当必成、mv 包一层让第二个换名失败、launchctl 用 stub）。
/// 跑的都是 /bin/bash -c 真脚本，验的是脚本本身的换装行为。
final class SentinelUpdateSwapScriptTests: XCTestCase {
    private var workRoot: URL!
    private var appsDirectory: URL!
    private var mountDirectory: URL!
    private var stubBin: URL!
    private var mainJobPlist: URL!

    override func setUpWithError() throws {
        workRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cor9792-swap-\(UUID().uuidString)", isDirectory: true)
        appsDirectory = workRoot.appendingPathComponent("Applications", isDirectory: true)
        mountDirectory = workRoot.appendingPathComponent("mnt", isDirectory: true)
        stubBin = workRoot.appendingPathComponent("stubbin", isDirectory: true)
        let directories: [URL] = [appsDirectory, mountDirectory, stubBin]
        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // 主任务 plist 占位文件：脚本只看它在不在，bootstrap 由 stub 接住。
        mainJobPlist = workRoot.appendingPathComponent("com.cortex.sentinelbar.plist")
        try Data("<plist/>".utf8).write(to: mainJobPlist)
        try writeStubLaunchctl()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workRoot)
    }

    // MARK: 路径速记

    private var targetApp: URL { appsDirectory.appendingPathComponent("Cortex哨兵.app", isDirectory: true) }
    private var incomingApp: URL {
        URL(fileURLWithPath: SentinelUpdateInstaller.incomingStagingPath(appsDirectory: appsDirectory.path))
    }
    private var previousApp: URL {
        URL(fileURLWithPath: SentinelUpdateInstaller.previousBackupPath(appsDirectory: appsDirectory.path))
    }
    private var targetMarker: URL { targetApp.appendingPathComponent("VersionMarker") }

    // MARK: 夹具

    /// 造一个最小 app 夹具：Contents/MacOS/CortexSentinelBar 脚本可执行 + 版本标记。
    private func makeApp(at url: URL, marker: String) throws {
        let executable = url.appendingPathComponent("Contents/MacOS/CortexSentinelBar")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "#!/bin/sh\necho \(marker)\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path
        )
        try marker.data(using: .utf8)!.write(to: url.appendingPathComponent("VersionMarker"))
    }

    /// 安装位放旧版。
    private func installOldApp() throws {
        try makeApp(at: targetApp, marker: "old-0.1.52")
    }

    /// DMG 挂载点放新版。
    private func putNewAppInMount() throws {
        try makeApp(at: mountDirectory.appendingPathComponent("Cortex哨兵.app", isDirectory: true), marker: "new-0.1.53")
    }

    /// launchctl 替身：bootout/bootstrap 一律成功，print 回一个固定 pid，
    /// 让换装后核验走到「新版已在开机任务名下」的分支，不碰真 launchd。
    private func writeStubLaunchctl() throws {
        let stub = stubBin.appendingPathComponent("launchctl")
        try """
        #!/bin/bash
        case "$1" in
          print)
            echo "\tpid = 424242"
            echo "\tstate = running"
            ;;
        esac
        exit 0
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
    }

    /// 默认替身组：codesign/spctl 必成（夹具 app 没签名，真验签必挂），
    /// launchctl 走 stub；ditto/mv 用真的。
    private func stubbedTools() -> SentinelUpdateInstaller.SwapScriptTools {
        var tools = SentinelUpdateInstaller.SwapScriptTools()
        tools.codesign = "/usr/bin/true"
        tools.spctl = "/usr/bin/true"
        tools.launchctl = stubBin.appendingPathComponent("launchctl").path
        return tools
    }

    /// 用测试夹具路径生成脚本。
    private func makeScript(
        initiatingPid: Int32 = Int32.max,
        tools: SentinelUpdateInstaller.SwapScriptTools,
        stopTimeoutSeconds: Int = 2,
        postCheckTimeoutSeconds: Int = 2
    ) -> String {
        SentinelUpdateInstaller.makeSwapScript(
            appsDirectory: appsDirectory.path,
            newAppPath: mountDirectory.appendingPathComponent("Cortex哨兵.app").path,
            mountPoint: mountDirectory.path,
            mainJobPlistPath: mainJobPlist.path,
            updateJobPlistPath: workRoot.appendingPathComponent("update.plist").path,
            mainJobLabel: "test.cortex.sentinelbar",
            updateJobLabel: "test.cortex.sentinelbar.update",
            uid: getuid(),
            initiatingPid: initiatingPid,
            tools: tools,
            stopTimeoutSeconds: stopTimeoutSeconds,
            postCheckTimeoutSeconds: postCheckTimeoutSeconds
        )
    }

    @discardableResult
    private func runScript(_ script: String) throws -> (output: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        // 照开机任务的环境跑：launchd 只给 PATH / HOME / USER / TMPDIR，不给 LANG / LC_*。
        // 继承测试进程的语言环境会掩盖 ps 在 C 语言环境下把路径里的中文转义成 M-e… 的问题。
        let inherited = ProcessInfo.processInfo.environment
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": inherited["HOME"] ?? NSHomeDirectory(),
            "USER": inherited["USER"] ?? NSUserName(),
            "TMPDIR": inherited["TMPDIR"] ?? NSTemporaryDirectory(),
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
    }

    private func marker(of app: URL) throws -> String {
        try String(contentsOf: app.appendingPathComponent("VersionMarker"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 用例 ①：正常换装

    func testHappyPathSwapsInStagedAppAndRemovesPrevious() throws {
        try installOldApp()
        try putNewAppInMount()
        let result = try runScript(makeScript(tools: stubbedTools()))

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(try marker(of: targetApp), "new-0.1.53", result.output)
        // 暂存清掉；换装后核验过了才删 .previous。
        XCTAssertFalse(FileManager.default.fileExists(atPath: incomingApp.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: previousApp.path))
        XCTAssertTrue(result.output.contains("postcheck ok"), result.output)
        XCTAssertTrue(result.output.contains("previous backup removed"), result.output)
        XCTAssertTrue(result.output.contains("atomic rename"), result.output)
    }

    // MARK: 用例 ②：ditto 暂存失败 → 旧版原样在、拉回主任务、非零退出

    func testDittoFailureKeepsOldAppAndRestartsMainJob() throws {
        try installOldApp()
        try putNewAppInMount()
        var tools = stubbedTools()
        tools.ditto = "/usr/bin/false"
        let result = try runScript(makeScript(tools: tools))

        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(try marker(of: targetApp), "old-0.1.52", result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: incomingApp.path))
        XCTAssertTrue(result.output.contains("ditto staging failed"), result.output)
        XCTAssertTrue(result.output.contains("main job bootstrapped from plist"), result.output)
    }

    // MARK: 用例 ③：验签不过 → 删暂存、留旧版、非零退出

    func testCodesignFailureKeepsOldAppAndDropsStaging() throws {
        try installOldApp()
        try putNewAppInMount()
        var tools = stubbedTools()
        tools.codesign = "/usr/bin/false"
        let result = try runScript(makeScript(tools: tools))

        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(try marker(of: targetApp), "old-0.1.52", result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: incomingApp.path))
        XCTAssertTrue(result.output.contains("codesign verify failed"), result.output)
        // 验签没过：不许再碰 spctl，更不许换名。
        XCTAssertFalse(result.output.contains("atomic rename"), result.output)
    }

    /// spctl 这道闸单独拦：codesign 过了、spctl 拒了，同样留旧版。
    func testSpctlFailureKeepsOldApp() throws {
        try installOldApp()
        try putNewAppInMount()
        var tools = stubbedTools()
        tools.spctl = "/usr/bin/false"
        let result = try runScript(makeScript(tools: tools))

        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(try marker(of: targetApp), "old-0.1.52", result.output)
        XCTAssertTrue(result.output.contains("spctl rejected staged app"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: incomingApp.path))
    }

    // MARK: 用例 ④：第二个 mv 失败 → .previous 挪回正式位

    /// mv 替身：旧版挪去 .previous 放行，暂存挪上正式位这次模拟失败。
    private func writeSecondMoveFailingMv() throws -> String {
        let wrapper = stubBin.appendingPathComponent("mv")
        try """
        #!/bin/bash
        if [ "$1" = '\(incomingApp.path)' ]; then
          exit 42
        fi
        exec /bin/mv "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return wrapper.path
    }

    func testSecondMoveFailureRestoresPrevious() throws {
        try installOldApp()
        try putNewAppInMount()
        var tools = stubbedTools()
        tools.mv = try writeSecondMoveFailingMv()
        let result = try runScript(makeScript(tools: tools))

        XCTAssertNotEqual(result.status, 0, result.output)
        // 正式位回到旧版，.previous 已挪回，暂存清掉。
        XCTAssertEqual(try marker(of: targetApp), "old-0.1.52", result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: previousApp.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: incomingApp.path))
        XCTAssertTrue(result.output.contains("rolling back"), result.output)
        XCTAssertTrue(result.output.contains("old app restored"), result.output)
    }

    // MARK: 用例 ⑤：上次残留的暂存与 .previous 在换装开头被清掉

    func testLeftoverStagingAndPreviousAreClearedAtStart() throws {
        try installOldApp()
        try putNewAppInMount()
        try FileManager.default.createDirectory(at: incomingApp, withIntermediateDirectories: true)
        try "stale".write(to: incomingApp.appendingPathComponent("stale-file"), atomically: true, encoding: .utf8)
        try makeApp(at: previousApp, marker: "ancient-0.1.40")
        let result = try runScript(makeScript(tools: stubbedTools()))

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(try marker(of: targetApp), "new-0.1.53", result.output)
        // 换装照常走完，两处残留都不在了。
        XCTAssertFalse(FileManager.default.fileExists(atPath: incomingApp.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: previousApp.path))
        XCTAssertTrue(result.output.contains("leftover staging and previous cleared"), result.output)
    }

    // MARK: 用例 ⑥：发起实例不在开机任务名下 → 脚本按 pid 补停再换

    /// stub launchctl 的 bootout 什么都不停，模拟「bootout 停不到」；
    /// 发起实例用真进程替身（/bin/sleep 拷进夹具安装位，comm 才对得上安装位路径）。
    func testInitiatingInstanceOutsideLaunchdJobIsStoppedBeforeSwap() throws {
        let executable = targetApp.appendingPathComponent("Contents/MacOS/CortexSentinelBar")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: executable.path)
        try "old-0.1.52".write(to: targetMarker, atomically: true, encoding: .utf8)
        try putNewAppInMount()

        let instance = Process()
        instance.executableURL = executable
        instance.arguments = ["30"]
        try instance.run()
        defer {
            if instance.isRunning {
                instance.terminate()
                instance.waitUntilExit()
            }
        }

        let result = try runScript(
            makeScript(initiatingPid: Int32(instance.processIdentifier), tools: stubbedTools(), stopTimeoutSeconds: 3)
        )

        XCTAssertEqual(result.status, 0, result.output)
        instance.waitUntilExit()
        XCTAssertEqual(instance.terminationStatus, Int32(SIGTERM), "发起实例应被 TERM 停掉")
        XCTAssertEqual(try marker(of: targetApp), "new-0.1.53", result.output)
        XCTAssertTrue(result.output.contains("stopping initiating instance pid=\(instance.processIdentifier)"), result.output)
        XCTAssertTrue(result.output.contains("initiating instance stopped"), result.output)
    }

    // MARK: 用例 ⑦：传进来的 pid 可执行路径不对 → 不停它、照旧换装、记一行

    /// 拿测试进程自己的 pid 当发起 pid：它的可执行文件是测试宿主，
    /// 不是夹具安装位，脚本不该动它（动了测试自己就没了），只记一行照旧换装。
    func testPidWithWrongExecutablePathIsLeftAloneAndLogged() throws {
        try installOldApp()
        try putNewAppInMount()
        let result = try runScript(
            makeScript(initiatingPid: ProcessInfo.processInfo.processIdentifier, tools: stubbedTools())
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(try marker(of: targetApp), "new-0.1.53", result.output)
        XCTAssertTrue(
            result.output.contains("step3 initiating pid \(ProcessInfo.processInfo.processIdentifier) runs from"),
            "应有 pid 可执行路径不符的记录"
        )
        XCTAssertTrue(result.output.contains("leave it alone"), result.output)
        XCTAssertFalse(result.output.contains("stopping initiating instance"), result.output)
    }
}
