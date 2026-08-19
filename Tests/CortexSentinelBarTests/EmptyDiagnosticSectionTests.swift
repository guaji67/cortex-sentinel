import Foundation
import XCTest
@testable import CortexSentinelBar

final class EmptyDiagnosticSectionTests: XCTestCase {
    func testAllZeroSamplesCollapseInputToOneLine() {
        let probes = InputStatusSnapshot.empty.displayProbes()
        XCTAssertEqual(probes.count, 3)
        XCTAssertTrue(probes.allSatisfy { $0.probe.sampleCountText == "0/60" })
        XCTAssertEqual(
            InputServiceSectionPresentation.resolve(probes: probes),
            .compact(statusText: "暂无数据")
        )
    }

    func testOneModelWithSamplesKeepsInputExpanded() {
        let probes = [
            InputStatusDisplayProbe(
                probe: InputStatusProbe(
                    model: "gpt-5.6-sol",
                    uptimePercentage: 99.1,
                    isOK: true,
                    latencyMilliseconds: 120,
                    history: [
                        InputStatusHistoryPoint(
                            timestamp: 1,
                            isOK: true,
                            latencyMilliseconds: 120
                        )
                    ]
                ),
                state: .connected
            ),
            InputStatusDisplayProbe(
                probe: InputStatusProbe(
                    model: "gpt-5.6-terra",
                    uptimePercentage: nil,
                    isOK: nil,
                    latencyMilliseconds: nil
                ),
                state: .unknown
            ),
            InputStatusDisplayProbe(
                probe: InputStatusProbe(
                    model: "gpt-5.5",
                    uptimePercentage: nil,
                    isOK: nil,
                    latencyMilliseconds: nil
                ),
                state: .unknown
            ),
        ]
        XCTAssertEqual(probes[0].probe.sampleCountText, "1/60")
        XCTAssertEqual(probes[1].probe.sampleCountText, "0/60")
        XCTAssertEqual(
            InputServiceSectionPresentation.resolve(probes: probes),
            .expanded
        )
    }

    func testBalanceWithOfficialNumberStaysExpanded() {
        let official = OfficialUsageSnapshot(
            planType: "pro",
            email: "fixture@example.test",
            weeklyWindow: OfficialUsageWindow(
                usedPercentage: 12,
                limitWindowSeconds: 604800,
                resetAt: nil,
                resetAfterSeconds: nil
            ),
            fiveHourWindow: nil,
            checkedAt: Date(timeIntervalSince1970: 1_787_000_000),
            stale: false,
            errorMessage: nil,
            refreshFailedAt: nil
        )
        XCTAssertEqual(official.weeklyRemainingPercentage, 88)
        XCTAssertEqual(
            BalanceSectionPresentation.resolve(official: official, aio: .unconfigured),
            .expanded
        )
    }

    func testBalanceWithRelayNumberStaysExpanded() {
        let provider = AIOProvider(
            id: 12,
            name: "中转甲",
            baseURL: "https://aio.fixture.test/v1",
            enabled: true,
            routeOrder: 0,
            providerOrder: 0,
            note: "",
            circuitState: .closed,
            failureCount: 0,
            usage: .success(
                AIOUsage(
                    response: AIOUsageResponse(
                        remaining: 36.5,
                        unit: "USD",
                        planName: "钱包余额",
                        subscription: nil,
                        isValid: true
                    )
                )
            )
        )
        let aio = AIOSnapshot(
            sourceState: .available,
            gatewayEnabled: true,
            routeMode: .aggregate,
            providers: [provider],
            lastHitProviderID: 12,
            lastHitProviderName: "中转甲",
            readAt: Date(),
            errorMessage: nil
        )
        XCTAssertTrue(provider.usage.hasDisplayableBalanceNumber)
        XCTAssertEqual(
            BalanceSectionPresentation.resolve(official: .empty, aio: aio),
            .expanded
        )
    }

    func testMissingAIOWithoutNumbersCollapsesBalance() {
        XCTAssertEqual(
            BalanceSectionPresentation.resolve(official: .empty, aio: .unconfigured),
            .compact(statusText: "未找到 AIO 数据库")
        )
    }

    func testAvailableAIOStillQueryingCollapsesBalance() {
        let provider = AIOProvider(
            id: 8,
            name: "中转乙",
            baseURL: "https://aio.fixture.test/v1",
            enabled: true,
            routeOrder: 0,
            providerOrder: 0,
            note: "",
            circuitState: .closed,
            failureCount: 0,
            usage: .loading
        )
        let aio = AIOSnapshot(
            sourceState: .available,
            gatewayEnabled: true,
            routeMode: .aggregate,
            providers: [provider],
            lastHitProviderID: nil,
            lastHitProviderName: nil,
            readAt: Date(),
            errorMessage: nil
        )
        XCTAssertEqual(
            BalanceSectionPresentation.resolve(official: .empty, aio: aio),
            .compact(statusText: "查询中")
        )
    }

    @MainActor
    func testBusyFixtureHasNoInputSamplesAndNoAIOSoBothCollapse() throws {
        let session = try PanelPreviewFactory.makeSession(fixture: .busy)
        defer { session.tearDown() }

        let probes = session.store.inputStatus.displayProbes()
        XCTAssertTrue(probes.allSatisfy { $0.probe.sampleCountText == "0/60" })
        XCTAssertEqual(
            InputServiceSectionPresentation.resolve(probes: probes),
            .compact(statusText: "暂无数据")
        )
        XCTAssertEqual(session.store.aio.sourceState, .unconfigured)
        XCTAssertNil(session.store.officialUsage.weeklyRemainingPercentage)
        XCTAssertEqual(
            BalanceSectionPresentation.resolve(
                official: session.store.officialUsage,
                aio: session.store.aio
            ),
            .compact(statusText: "未找到 AIO 数据库")
        )
    }
}
