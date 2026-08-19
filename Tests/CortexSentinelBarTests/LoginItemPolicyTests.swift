import Foundation
import XCTest
@testable import CortexSentinelBar

final class LoginItemPolicyTests: XCTestCase {
    func testLaunchdManagedDoesNotRegister() {
        let registrar = FakeLoginItemRegistrar(status: .notRegistered)
        let plan = LoginItemReconciler.plan(
            signals: LaunchdSupervisionSignals(
                plistTargetsThisApp: true,
                parentIsLaunchd: true,
                environmentMatchesPlist: true
            ),
            status: registrar.status
        )

        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.presentation, .systemManaged)
        XCTAssertEqual(plan.presentation.copy, LoginItemConstants.copySystemManaged)
        XCTAssertFalse(plan.presentation.showsToggle)

        let presentation = LoginItemReconciler.apply(plan: plan, registrar: registrar)
        XCTAssertEqual(registrar.registerCallCount, 0)
        XCTAssertEqual(presentation.kind, .systemManaged)
        XCTAssertEqual(presentation.copy, LoginItemConstants.copySystemManaged)
    }

    func testUnmanagedRegistersAndShowsEnabled() throws {
        let registrar = FakeLoginItemRegistrar(status: .notRegistered)
        let plan = LoginItemReconciler.plan(
            signals: .none,
            status: registrar.status
        )

        XCTAssertEqual(plan.action, .register)
        XCTAssertEqual(plan.presentation.kind, .disabled)

        let presentation = LoginItemReconciler.apply(plan: plan, registrar: registrar)
        XCTAssertEqual(registrar.registerCallCount, 1)
        XCTAssertEqual(presentation, .enabled)
        XCTAssertEqual(presentation.copy, LoginItemConstants.copyEnabled)
        XCTAssertFalse(presentation.showsToggle)
        XCTAssertEqual(registrar.status, .enabled)
    }

    func testRegisterFailureShowsDisabledWithoutThrowing() {
        let registrar = FakeLoginItemRegistrar(
            status: .notRegistered,
            error: FakeLoginItemError()
        )
        let plan = LoginItemReconciler.plan(
            signals: .none,
            status: registrar.status
        )

        let presentation = LoginItemReconciler.apply(plan: plan, registrar: registrar)
        XCTAssertEqual(registrar.registerCallCount, 1)
        XCTAssertEqual(presentation, .disabled)
        XCTAssertEqual(presentation.copy, LoginItemConstants.copyDisabled)
        XCTAssertTrue(presentation.showsToggle)
        XCTAssertEqual(registrar.status, .notRegistered)
    }

    func testSingleSignalDoesNotCountAsLaunchdManaged() {
        let parentOnly = LaunchdSupervisionSignals(
            plistTargetsThisApp: false,
            parentIsLaunchd: true,
            environmentMatchesPlist: false
        )
        XCTAssertEqual(parentOnly.matchingCount, 1)
        XCTAssertFalse(parentOnly.isLaunchdManaged)
        XCTAssertEqual(
            LoginItemReconciler.plan(signals: parentOnly, status: .notRegistered).action,
            .register
        )

        let plistAndEnv = LaunchdSupervisionSignals(
            plistTargetsThisApp: true,
            parentIsLaunchd: false,
            environmentMatchesPlist: true
        )
        XCTAssertTrue(plistAndEnv.isLaunchdManaged)
        XCTAssertEqual(
            LoginItemReconciler.plan(signals: plistAndEnv, status: .notRegistered).action,
            .none
        )
    }

    func testProbeMatchesPlistProgramAndEnvironment() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("login-item-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let app = home.appendingPathComponent("Applications/Cortex哨兵.app")
        let executable = app.appendingPathComponent("Contents/MacOS/CortexSentinelBar")
        let plistURL = LaunchdSupervisionProbe.plistURL(homeDirectory: home)
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: executable)

        let environment = ["CORTEX_REPO_ROOT": "/Users/falcon/Documents/Code/cortex"]
        let plist: [String: Any] = [
            "Label": LoginItemConstants.launchAgentLabel,
            "ProgramArguments": [executable.path],
            "KeepAlive": true,
            "RunAtLoad": true,
            "EnvironmentVariables": environment,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: plistURL)

        let managed = LaunchdSupervisionProbe.collect(
            executableURL: executable,
            environment: environment,
            parentProcessID: 1,
            plistURL: plistURL,
            plistData: data
        )
        XCTAssertTrue(managed.signals.isLaunchdManaged)
        XCTAssertEqual(managed.signals.matchingCount, 3)

        let otherBinary = home.appendingPathComponent(".build/release/CortexSentinelBar")
        let unmanaged = LaunchdSupervisionProbe.collect(
            executableURL: otherBinary,
            environment: [:],
            parentProcessID: 99,
            plistURL: plistURL,
            plistData: data
        )
        XCTAssertFalse(unmanaged.signals.plistTargetsThisApp)
        XCTAssertFalse(unmanaged.signals.isLaunchdManaged)
        XCTAssertEqual(unmanaged.signals.matchingCount, 0)
        XCTAssertTrue(
            LoginItemDiagnostics.dumpLines(
                details: unmanaged,
                loginItemStatus: .notRegistered,
                menuBarWouldRegister: true
            ).contains(where: { $0.contains("不调用 register") })
        )
    }

    func testCLIAndTestsNeverReconcileLoginItem() {
        XCTAssertFalse(
            LoginItemRuntime.shouldReconcileOnLaunch(
                arguments: ["/tmp/CortexSentinelBar", "--dump-state"],
                environment: [:]
            )
        )
        XCTAssertFalse(
            LoginItemRuntime.shouldReconcileOnLaunch(
                arguments: ["/tmp/CortexSentinelBar"],
                environment: ["XCTestConfigurationFilePath": "/tmp/xctest"]
            )
        )
        XCTAssertTrue(
            LoginItemRuntime.shouldReconcileOnLaunch(
                arguments: ["/Applications/Cortex哨兵.app/Contents/MacOS/CortexSentinelBar"],
                environment: [:]
            )
        )
    }

    func testColdLaunchPresentsOnlyWhenUserOpenedUnmanagedApp() {
        let managed = LaunchdSupervisionSignals(
            plistTargetsThisApp: true,
            parentIsLaunchd: true,
            environmentMatchesPlist: true
        )
        XCTAssertFalse(
            PanelOpenPolicy.shouldPresentOnColdLaunch(
                signals: managed,
                automaticallyLaunched: false
            )
        )
        XCTAssertFalse(
            PanelOpenPolicy.shouldPresentOnColdLaunch(
                signals: managed,
                automaticallyLaunched: true
            )
        )
        XCTAssertFalse(
            PanelOpenPolicy.shouldPresentOnColdLaunch(
                signals: .none,
                automaticallyLaunched: true
            )
        )
        XCTAssertTrue(
            PanelOpenPolicy.shouldPresentOnColdLaunch(
                signals: .none,
                automaticallyLaunched: false
            )
        )
        // 单信号不算托管：用户点图标仍应弹（reopen 另走，冷启动也弹）
        XCTAssertTrue(
            PanelOpenPolicy.shouldPresentOnColdLaunch(
                signals: LaunchdSupervisionSignals(
                    plistTargetsThisApp: false,
                    parentIsLaunchd: true,
                    environmentMatchesPlist: false
                ),
                automaticallyLaunched: false
            )
        )
    }

    func testMissingAppleEventCountsAsAutomaticLaunch() {
        XCTAssertTrue(LaunchAppleEventSummary.isAutomaticLaunch(nil))
        XCTAssertTrue(
            LaunchAppleEventSummary(
                launchedAsLoginItem: true,
                launchedAsServiceItem: false
            ).isAutomaticLaunch
        )
        XCTAssertTrue(
            LaunchAppleEventSummary(
                launchedAsLoginItem: false,
                launchedAsServiceItem: true
            ).isAutomaticLaunch
        )
        XCTAssertFalse(
            LaunchAppleEventSummary(
                launchedAsLoginItem: false,
                launchedAsServiceItem: false
            ).isAutomaticLaunch
        )
        XCTAssertFalse(
            LaunchAppleEventSummary.isAutomaticLaunch(
                LaunchAppleEventSummary(
                    launchedAsLoginItem: false,
                    launchedAsServiceItem: false
                )
            )
        )
    }
}

private struct FakeLoginItemError: Error {}

private final class FakeLoginItemRegistrar: LoginItemRegistrar {
    var status: LoginItemRegistrationStatus
    var registerCallCount = 0
    var error: Error?

    init(status: LoginItemRegistrationStatus, error: Error? = nil) {
        self.status = status
        self.error = error
    }

    func register() throws {
        registerCallCount += 1
        if let error {
            throw error
        }
        status = .enabled
    }
}
