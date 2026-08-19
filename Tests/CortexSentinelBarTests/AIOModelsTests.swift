import Foundation
import XCTest
@testable import CortexSentinelBar

final class AIOModelsTests: XCTestCase {
    func testAggregateAttributionShowsLastSuccessfulProvider() {
        let line = LineStatus(
            sourceFile: URL(fileURLWithPath: "/tmp/line.status.json"),
            slug: "fixture-line",
            workdir: nil,
            branch: nil,
            state: .running,
            restarts: 0,
            rolloutAgeSeconds: 1,
            updatedAt: Date(),
            sourceModifiedAt: nil,
            relay: nil
        )
        let snapshot = AIOSnapshot(
            sourceState: .available,
            gatewayEnabled: true,
            routeMode: .aggregate,
            providers: [],
            lastHitProviderID: 12,
            lastHitProviderName: "fixture-alpha",
            readAt: Date(),
            errorMessage: nil
        )

        XCTAssertEqual(
            RelayAttribution.resolve(line: line, aio: snapshot),
            RelayAttribution(text: "聚合→fixture-alpha", isReported: true)
        )
    }

    func testDirectAttributionMatchesBaseURLWithoutTrailingV1() {
        let line = LineStatus(
            sourceFile: URL(fileURLWithPath: "/tmp/line.status.json"),
            slug: "fixture-line",
            workdir: nil,
            branch: nil,
            state: .running,
            restarts: 0,
            rolloutAgeSeconds: 1,
            updatedAt: Date(),
            sourceModifiedAt: nil,
            relay: LineRelay(
                activeID: nil,
                activeLabel: nil,
                switchCount: nil,
                lastSwitchAt: nil,
                baseURLAtSpawn: "https://aio.fixture.test/v1"
            )
        )
        let provider = AIOProvider(
            id: 12,
            name: "fixture-direct",
            baseURL: "https://aio.fixture.test",
            enabled: true,
            routeOrder: 0,
            providerOrder: 0,
            note: "",
            circuitState: .closed,
            failureCount: 0,
            usage: .idle
        )
        let snapshot = AIOSnapshot(
            sourceState: .available,
            gatewayEnabled: true,
            routeMode: .direct,
            providers: [provider],
            lastHitProviderID: nil,
            lastHitProviderName: nil,
            readAt: Date(),
            errorMessage: nil
        )

        XCTAssertEqual(
            RelayAttribution.resolve(line: line, aio: snapshot),
            RelayAttribution(text: "fixture-direct", isReported: true)
        )
    }

    func testLowBalanceAndOpenCircuitRaiseAggregateWarning() {
        let now = Date()
        let provider = AIOProvider(
            id: 12,
            name: "fixture-low",
            baseURL: "https://aio.fixture.test/v1",
            enabled: true,
            routeOrder: 0,
            providerOrder: 0,
            note: "",
            circuitState: .open,
            failureCount: 2,
            usage: .success(
                AIOUsage(
                    response: AIOUsageResponse(
                        remaining: 4,
                        unit: "USD",
                        planName: "钱包余额",
                        subscription: AIOUsageSubscription(expiresAt: nil),
                        isValid: true
                    )
                )
            )
        )
        let snapshot = AIOSnapshot(
            sourceState: .available,
            gatewayEnabled: true,
            routeMode: .aggregate,
            providers: [provider],
            lastHitProviderID: nil,
            lastHitProviderName: nil,
            readAt: Date(),
            errorMessage: nil
        )
        let line = LineStatus(
            sourceFile: URL(fileURLWithPath: "/tmp/line.status.json"),
            slug: "fixture-line",
            workdir: nil,
            branch: nil,
            state: .running,
            restarts: 0,
            rolloutAgeSeconds: 1,
            updatedAt: now,
            sourceModifiedAt: now,
            relay: nil
        )

        XCTAssertEqual(
            SentinelAggregation.severity(lines: [line], aio: snapshot, now: now),
            .amber
        )
    }

    func testStatusBarUsesOnlyFirstTwoProvidersInRouteOrder() {
        let providers = [
            makeProvider(id: 1, remaining: 9.9),
            makeProvider(id: 2, remaining: 360),
            makeProvider(id: 3, remaining: 720),
        ]
        let snapshot = AIOSnapshot(
            sourceState: .available,
            gatewayEnabled: true,
            routeMode: .aggregate,
            providers: providers,
            lastHitProviderID: nil,
            lastHitProviderName: nil,
            readAt: Date(),
            errorMessage: nil
        )

        XCTAssertEqual(snapshot.statusBarBalances.map(\.providerID), [1, 2])
        XCTAssertEqual(snapshot.statusBarBalances.map(\.text), ["$10", "$360"])
        XCTAssertEqual(snapshot.statusBarBalances.map(\.isLowBalance), [true, false])
    }

    func testProviderStatusSeverity() {
        XCTAssertEqual(
            makeCircuitProvider(enabled: false, circuit: .closed).statusSeverity,
            .gray
        )
        XCTAssertEqual(
            makeCircuitProvider(enabled: false, circuit: .halfOpen).statusSeverity,
            .gray
        )
        XCTAssertEqual(
            makeCircuitProvider(enabled: true, circuit: .open).statusSeverity,
            .red
        )
        XCTAssertEqual(
            makeCircuitProvider(enabled: true, circuit: .halfOpen).statusSeverity,
            .amber
        )
        XCTAssertEqual(
            makeCircuitProvider(enabled: true, circuit: .closed).statusSeverity,
            .green
        )
        XCTAssertEqual(
            makeCircuitProvider(enabled: true, circuit: .unknown("UNKNOWN")).statusSeverity,
            .green
        )
        XCTAssertEqual(
            makeCircuitProvider(enabled: true, circuit: .closed, remaining: 4).statusSeverity,
            .amber
        )
    }

    func testDisabledUsageRefreshRunsEveryTenMinutes() {
        let lastRefreshAt = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(
            AIOUsageRefreshPolicy.shouldRefreshDisabledUsage(
                lastRefreshAt: nil,
                now: lastRefreshAt
            )
        )
        XCTAssertFalse(
            AIOUsageRefreshPolicy.shouldRefreshDisabledUsage(
                lastRefreshAt: lastRefreshAt,
                now: lastRefreshAt.addingTimeInterval(599.9)
            )
        )
        XCTAssertTrue(
            AIOUsageRefreshPolicy.shouldRefreshDisabledUsage(
                lastRefreshAt: lastRefreshAt,
                now: lastRefreshAt.addingTimeInterval(600)
            )
        )
    }

    func testDisabledUsageFailurePreservesLastSuccessfulBalance() throws {
        let disabled = makeCircuitProvider(enabled: false, circuit: .closed)
        let cached = [disabled.id: disabled.usage]

        let failedRefresh = AIOUsageRefreshPolicy.merge(
            cached: cached,
            fresh: [disabled.id: .failed],
            providers: [disabled]
        )
        XCTAssertEqual(try XCTUnwrap(failedRefresh[disabled.id]?.usage?.remaining), 100)

        let refreshedUsage = makeCircuitProvider(
            enabled: false,
            circuit: .closed,
            remaining: 80
        ).usage
        let successfulRefresh = AIOUsageRefreshPolicy.merge(
            cached: cached,
            fresh: [disabled.id: refreshedUsage],
            providers: [disabled]
        )
        XCTAssertEqual(try XCTUnwrap(successfulRefresh[disabled.id]?.usage?.remaining), 80)
    }

    private func makeCircuitProvider(
        enabled: Bool,
        circuit: AIOCircuitState,
        remaining: Double = 100
    ) -> AIOProvider {
        AIOProvider(
            id: 99,
            name: "fixture",
            baseURL: "https://relay.example.test/v1",
            enabled: enabled,
            routeOrder: 0,
            providerOrder: 0,
            note: "",
            circuitState: circuit,
            failureCount: 0,
            usage: .success(
                AIOUsage(
                    response: AIOUsageResponse(
                        remaining: remaining,
                        unit: "USD",
                        planName: nil,
                        subscription: AIOUsageSubscription(expiresAt: nil),
                        isValid: true
                    )
                )
            )
        )
    }

    private func makeProvider(id: Int64, remaining: Double) -> AIOProvider {
        AIOProvider(
            id: id,
            name: "密钥 \(id)",
            baseURL: "https://aio.fixture.test/\(id)/v1",
            enabled: true,
            routeOrder: Int(id),
            providerOrder: Int(id),
            note: "",
            circuitState: .closed,
            failureCount: 0,
            usage: .success(
                AIOUsage(
                    response: AIOUsageResponse(
                        remaining: remaining,
                        unit: "USD",
                        planName: nil,
                        subscription: nil,
                        isValid: true
                    )
                )
            )
        )
    }
}
