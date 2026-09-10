import CryptoKit
import Foundation
import XCTest
@testable import CortexSentinelBar

/// 哨兵自更新：版本比较、release 解析、sha 校验、安装流程编排（假 shell 不连网）。
final class SentinelUpdaterTests: XCTestCase {
    // MARK: 版本比较

    func testVersionParseAndCompare() {
        XCTAssertEqual(SentinelUpdateVersion.parse("0.1.8")?.major, 0)
        XCTAssertEqual(SentinelUpdateVersion.parse("v0.1.8")?.patch, 8)
        XCTAssertNil(SentinelUpdateVersion.parse("0.1"))
        XCTAssertNil(SentinelUpdateVersion.parse("dev"))

        XCTAssertTrue(SentinelUpdateVersion.isNewer("0.1.8", than: "0.1.7"))
        XCTAssertTrue(SentinelUpdateVersion.isNewer("v0.2.0", than: "0.1.9"))
        XCTAssertTrue(SentinelUpdateVersion.isNewer("1.0.0", than: "0.99.99"))
        XCTAssertFalse(SentinelUpdateVersion.isNewer("0.1.7", than: "0.1.7"))
        XCTAssertFalse(SentinelUpdateVersion.isNewer("0.1.6", than: "0.1.7"))
        XCTAssertFalse(SentinelUpdateVersion.isNewer("dev", than: "0.1.7"))
    }

    // MARK: release 解析

    private func makeReleasePayload(tag: String) -> Data {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Data(
            """
            {
              "tag_name": "\(tag)",
              "body": "更新说明",
              "draft": false,
              "prerelease": false,
              "assets": [
                {"name": "Cortex.-\(version).dmg", "browser_download_url": "https://github.com/download/\(tag).dmg"},
                {"name": "Cortex.-\(version).dmg.sha256", "browser_download_url": "https://github.com/download/\(tag).sha256"},
                {"name": "Cortex.-\(version).manifest.json", "browser_download_url": "https://github.com/download/\(tag).json"}
              ]
            }
            """.utf8
        )
    }

    func testParseReleasePicksDMGAndShaAssets() throws {
        let info = try XCTUnwrap(
            SentinelUpdateChecker.parse(data: makeReleasePayload(tag: "v0.1.8"), currentVersion: "0.1.7")
        )
        XCTAssertEqual(info.version, "0.1.8")
        XCTAssertEqual(info.notes, "更新说明")
        XCTAssertEqual(info.dmgURL.absoluteString, "https://github.com/download/v0.1.8.dmg")
        XCTAssertEqual(info.dmgName, "Cortex.-0.1.8.dmg")
        XCTAssertEqual(info.shaURL?.absoluteString, "https://github.com/download/v0.1.8.sha256")
    }

    func testParseReleaseReturnsNilWhenNotNewer() throws {
        XCTAssertNil(
            try SentinelUpdateChecker.parse(data: makeReleasePayload(tag: "v0.1.7"), currentVersion: "0.1.7")
        )
        XCTAssertNil(
            try SentinelUpdateChecker.parse(data: makeReleasePayload(tag: "v0.1.6"), currentVersion: "0.1.7")
        )
        // tag 解析不了的（比如 dev build）当没有更新。
        XCTAssertNil(
            try SentinelUpdateChecker.parse(
                data: Data(#"{"tag_name": "dev-20260911", "assets": []}"#.utf8),
                currentVersion: "0.1.7"
            )
        )
    }

    func testParseReleaseThrowsOnGarbage() {
        XCTAssertThrowsError(
            try SentinelUpdateChecker.parse(data: Data("<html>".utf8), currentVersion: "0.1.7")
        ) { error in
            XCTAssertEqual(error as? SentinelUpdateError, .invalidResponse)
        }
    }

    func testCheckerReportsMissingDMGAsset() throws {
        XCTAssertNil(
            try SentinelUpdateChecker.parse(
                data: Data(#"{"tag_name": "v0.1.8", "assets": [{"name": "wrong.dmg", "browser_download_url": "https://x/wrong.dmg"}]}"#.utf8),
                currentVersion: "0.1.7"
            )
        )
    }

    // MARK: sha 解析

    func testSha256HexParsing() {
        let hex = String(repeating: "a1", count: 32)
        XCTAssertEqual(SentinelUpdateInstaller.sha256Hex(from: "\(hex)  Cortex.-0.1.8.dmg\n"), hex)
        XCTAssertEqual(SentinelUpdateInstaller.sha256Hex(from: "\(hex)\n"), hex)
        XCTAssertNil(SentinelUpdateInstaller.sha256Hex(from: "short  file.dmg"))
        XCTAssertNil(SentinelUpdateInstaller.sha256Hex(from: ""))
        XCTAssertNil(SentinelUpdateInstaller.sha256Hex(from: String(repeating: "g", count: 64) + "  x"))
    }

    // MARK: 安装编排

    func testInstallerAbortsWhenGateRejects() async throws {
        let shell = ScriptedShellRunner(attachOutput: makeAttachPlist(mount: "/Volumes/Cortex 哨兵"), gateAccepted: false)
        let installer = SentinelUpdateInstaller(
            loader: makeLoader(
                dmgBytes: Data("dmg-bytes".utf8),
                shaHex: sha256Hex(of: Data("dmg-bytes".utf8))
            ),
            shell: shell
        )
        do {
            _ = try await installer.install(makeUpdate())
            XCTFail("闸没拦住应当抛错")
        } catch let error as SentinelUpdateError {
            XCTAssertEqual(error, .gateRejected)
        }
        XCTAssertTrue(shell.didRunAttach)
    }

    func testInstallerAbortsOnShaMismatchBeforeMounting() async throws {
        let shell = ScriptedShellRunner(attachOutput: makeAttachPlist(mount: "/Volumes/Cortex 哨兵"), gateAccepted: true)
        let installer = SentinelUpdateInstaller(
            loader: makeLoader(dmgBytes: Data("dmg-bytes".utf8), shaHex: String(repeating: "00", count: 32)),
            shell: shell
        )
        do {
            _ = try await installer.install(makeUpdate())
            XCTFail("sha 不对应当抛错")
        } catch let error as SentinelUpdateError {
            XCTAssertEqual(error, .shaMismatch)
        }
        // sha 没过：连挂载都不该发生。
        XCTAssertFalse(shell.didRunAttach)
    }

    /// 换装失败自愈：补 bootstrap + kickstart 把 launchd 任务和哨兵拉回来。
    func testRecoveryBootstrapsAndKickstartsLaunchd() {
        let shell = ScriptedShellRunner(attachOutput: "", gateAccepted: true)
        SentinelUpdateInstaller(
            loader: makeLoader(dmgBytes: Data(), shaHex: String(repeating: "0", count: 64)),
            shell: shell
        ).recoverAfterFailedInstall()
        XCTAssertTrue(shell.invocations.contains { invocation in
            invocation.launchPath == "/bin/launchctl" && invocation.arguments.first == "bootstrap"
        })
        XCTAssertTrue(shell.invocations.contains { invocation in
            invocation.launchPath == "/bin/launchctl"
                && invocation.arguments.first == "kickstart"
                && invocation.arguments.last == "gui/\(getuid())/com.cortex.sentinelbar"
        })
    }

    func testInstallerHandsOffToLaunchdJobOnMount() async throws {
        let dmgBytes = Data("real-dmg".utf8)
        let digest = SHA256.hash(data: dmgBytes).map { String(format: "%02x", $0) }.joined()
        let shell = ScriptedShellRunner(attachOutput: makeAttachPlist(mount: "/Volumes/Cortex 哨兵"), gateAccepted: true)
        let plistURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-test-\(UUID().uuidString)/com.cortex.sentinelbar.update.plist")
        let installer = SentinelUpdateInstaller(
            loader: makeLoader(dmgBytes: dmgBytes, shaHex: digest),
            shell: shell,
            updateJobPlistURL: plistURL
        )
        try await installer.install(makeUpdate())

        // 闸跑过：spctl 校验挂载点里的 app。
        XCTAssertEqual(shell.invocations.filter { $0.launchPath == "/usr/sbin/spctl" }.count, 1)
        // 移交换装：bootstrap 一次性任务。
        XCTAssertTrue(shell.invocations.contains { invocation in
            invocation.launchPath == "/bin/launchctl" && invocation.arguments.first == "bootstrap"
        })
        // 移交成功后 DMG 保持挂载（任务自己卸），这里不许 detach。
        XCTAssertFalse(shell.invocations.contains { $0.arguments.first == "detach" })
        // 任务 plist 指向 DMG 里的安装脚本，自带失败自愈和自我清理。
        let plistData = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as! [String: Any]
        let arguments = try XCTUnwrap(plist["ProgramArguments"] as? [String])
        XCTAssertEqual(arguments.first, "/bin/bash")
        let script = try XCTUnwrap(arguments.last)
        XCTAssertTrue(script.contains("/Volumes/Cortex 哨兵/scripts/install-app.sh"))
        XCTAssertTrue(script.contains("--app-source '/Volumes/Cortex 哨兵/Cortex哨兵.app'"))
        XCTAssertTrue(script.contains("install-app.sh"))
        XCTAssertTrue(script.contains("bootstrap"))
        XCTAssertTrue(script.contains("detach"))
    }

    func testInstallerDetachesWhenHandOffFails() async throws {
        let dmgBytes = Data("real-dmg".utf8)
        let digest = SHA256.hash(data: dmgBytes).map { String(format: "%02x", $0) }.joined()
        let shell = ScriptedShellRunner(attachOutput: makeAttachPlist(mount: "/Volumes/Cortex 哨兵"), gateAccepted: true)
        shell.bootstrapFails = true
        let installer = SentinelUpdateInstaller(
            loader: makeLoader(dmgBytes: dmgBytes, shaHex: digest),
            shell: shell,
            updateJobPlistURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("cc-test-\(UUID().uuidString)/update.plist")
        )
        do {
            _ = try await installer.install(makeUpdate())
            XCTFail("bootstrap 失败应当抛错")
        } catch let error as SentinelUpdateError {
            XCTAssertEqual(error, .installScriptFailed)
        }
        // 移交失败：这里负责把 DMG 卸干净。
        XCTAssertTrue(shell.invocations.contains { $0.arguments.first == "detach" })
    }

    func testInstallerFailsWhenMountPointMissing() async throws {
        let installer = SentinelUpdateInstaller(
            loader: makeLoader(
                dmgBytes: Data("dmg".utf8),
                shaHex: sha256Hex(of: Data("dmg".utf8))
            ),
            shell: ScriptedShellRunner(attachOutput: "not a plist", gateAccepted: true)
        )
        do {
            _ = try await installer.install(makeUpdate())
            XCTFail("解析不出挂载点应当抛错")
        } catch let error as SentinelUpdateError {
            XCTAssertEqual(error, .installScriptFailed)
        }
    }

    // MARK: 测试替身与工具

    private func makeUpdate() -> SentinelUpdateInfo {
        SentinelUpdateInfo(
            version: "0.1.8",
            notes: nil,
            dmgURL: URL(string: "https://example.test/Cortex.-0.1.8.dmg")!,
            dmgName: "Cortex.-0.1.8.dmg",
            shaURL: URL(string: "https://example.test/Cortex.-0.1.8.dmg.sha256")!,
            checkedAt: Date()
        )
    }

    /// 按调用顺序回放：第一次请求回 DMG 字节，第二次回 sha 文本。
    private func makeLoader(dmgBytes: Data, shaHex: String) -> SentinelUpdateLoading {
        SequencedUpdateLoader(responses: [
            { request in
                (dmgBytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            { request in
                ("\(shaHex)  Cortex.-0.1.8.dmg\n".data(using: .utf8)!, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
        ])
    }

    private func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeAttachPlist(mount: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>system-entities</key><array>
        <dict><key>mount-point</key><string>\(mount)</string></dict>
        </array></dict></plist>
        """
    }

    private final class SequencedUpdateLoader: SentinelUpdateLoading, @unchecked Sendable {
        private let responses: [(URLRequest) throws -> (Data, URLResponse)]
        private let lock = NSLock()
        private var cursor = 0

        init(responses: [(URLRequest) throws -> (Data, URLResponse)]) {
            self.responses = responses
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            lock.lock()
            defer { lock.unlock() }
            guard cursor < responses.count else {
                throw SentinelUpdateError.downloadFailed
            }
            let response = try responses[cursor](request)
            cursor += 1
            return response
        }
    }

    /// 记录调用、可编程 spctl/bootstrap 结果的假 shell。
    private final class ScriptedShellRunner: SentinelShellRunning, @unchecked Sendable {
        struct Invocation: Equatable {
            let launchPath: String
            let arguments: [String]
        }

        let attachOutput: String
        let gateAccepted: Bool
        var bootstrapFails = false
        private let lock = NSLock()
        private var recorded: [Invocation] = []

        var invocations: [Invocation] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        var didRunAttach: Bool {
            invocations.contains { $0.arguments.first == "attach" }
        }

        init(attachOutput: String, gateAccepted: Bool) {
            self.attachOutput = attachOutput
            self.gateAccepted = gateAccepted
        }

        func run(launchPath: String, arguments: [String]) throws -> (stdout: String, status: Int32) {
            lock.lock()
            recorded.append(Invocation(launchPath: launchPath, arguments: arguments))
            lock.unlock()
            switch launchPath {
            case "/usr/bin/hdiutil":
                return (arguments.first == "attach" ? attachOutput : "", 0)
            case "/usr/sbin/spctl":
                return ("", gateAccepted ? 0 : 1)
            case "/bin/launchctl":
                return ("", arguments.first == "bootstrap" && bootstrapFails ? 1 : 0)
            default:
                return ("", 0)
            }
        }
    }
}
