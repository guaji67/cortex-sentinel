import XCTest
@testable import CortexSentinelBar

final class SingletonGuardTests: XCTestCase {
    private let currentPID: Int32 = 100

    func testHeadlessWorkersDoNotOwnMenuInstance() {
        for flag in ["--managed-hook", "--workbench-serve", "--dump-state", "--singleton-status"] {
            XCTAssertTrue(SentinelSingletonGuard.isHeadlessCommand("/Applications/Cortex 哨兵.app/Contents/MacOS/CortexSentinelBar \(flag) /path with spaces"))
        }
    }

    func testGUIAndSimilarlyNamedArgumentsAreNotHelpers() {
        XCTAssertFalse(SentinelSingletonGuard.isHeadlessCommand("/Applications/Cortex哨兵.app/Contents/MacOS/CortexSentinelBar"))
        XCTAssertFalse(SentinelSingletonGuard.isHeadlessCommand("/test/CortexSentinelBar --managed-hook-other"))
        XCTAssertFalse(SentinelSingletonGuard.isHeadlessCommand("/test/CortexSentinelBar --smoke-window /tmp/--managed-hook"))
    }

    func testKnownBundleIdBlocksOtherProcess() {
        let applications = [
            SentinelRunningApplication(
                processIdentifier: 101,
                bundleIdentifier: "com.falcon.cortex.sentinelbar",
                localizedName: "旧哨兵",
                executableName: "OtherName"
            )
        ]

        XCTAssertTrue(
            SentinelSingletonGuard.hasExistingInstance(
                applications: applications,
                currentProcessIdentifier: currentPID
            )
        )
    }

    func testProcessNameFallbackBlocksDifferentBundleId() {
        let applications = [
            SentinelRunningApplication(
                processIdentifier: 101,
                bundleIdentifier: "com.fixture.other",
                localizedName: "CortexSentinelBar",
                executableName: nil
            )
        ]

        XCTAssertTrue(
            SentinelSingletonGuard.hasExistingInstance(
                applications: applications,
                currentProcessIdentifier: currentPID
            )
        )
    }

    func testCurrentProcessIsIgnored() {
        let applications = [
            SentinelRunningApplication(
                processIdentifier: currentPID,
                bundleIdentifier: "com.cortex.sentinelbar",
                localizedName: "Cortex 哨兵",
                executableName: "CortexSentinelBar"
            )
        ]

        XCTAssertFalse(
            SentinelSingletonGuard.hasExistingInstance(
                applications: applications,
                currentProcessIdentifier: currentPID
            )
        )
    }

    @MainActor
    func testEnforceReportsHumanMessageAndRejects() {
        var message = ""
        let accepted = SentinelSingletonGuard.enforce(
            applications: [
                SentinelRunningApplication(
                    processIdentifier: 101,
                    bundleIdentifier: "com.cortex.sentinelbar",
                    localizedName: nil,
                    executableName: nil
                )
            ],
            currentProcessIdentifier: currentPID,
            alert: { message = $0 }
        )

        XCTAssertFalse(accepted)
        XCTAssertEqual(message, SentinelSingletonGuard.duplicateMessage)
    }

    @MainActor
    func testEnforceAllowsFirstProcess() {
        XCTAssertTrue(
            SentinelSingletonGuard.enforce(
                applications: [],
                currentProcessIdentifier: currentPID,
                alert: { _ in XCTFail("首个实例不应弹重复提示") }
            )
        )
    }

}
