import Foundation
import XCTest
@testable import CortexSentinelBar

final class InputStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_784_824_800)

    func testDisplayProbesMapModelsInFixedMenuBarOrder() throws {
        let snapshot = try XCTUnwrap(
            InputStatusClient.decodeSnapshot(
                Data(
                    """
                    {
                      "all_ok": false,
                      "services": [
                        {
                          "model": "gpt-5.5",
                          "uptime_pct": "99.8",
                          "last": {"ok": true, "latency_ms": "88"}
                        },
                        {
                          "model": "gpt-5.6-sol",
                          "uptime_pct": 99.9,
                          "last": {"ok": false, "latency_ms": 120}
                        }
                      ]
                    }
                    """.utf8
                ),
                readAt: now
            )
        )

        let probes = snapshot.displayProbes(now: now)

        XCTAssertEqual(probes.map(\.probe.model), InputStatusConstants.monitoredModels)
        XCTAssertEqual(probes.map(\.state), [.disconnected, .unknown, .connected])
        XCTAssertEqual(probes[0].probe.latencyMilliseconds, 120)
        XCTAssertEqual(probes[2].probe.uptimePercentage, 99.8)
        XCTAssertTrue(snapshot.hasWarning(now: now))
    }

    func testAllProbeDotsBecomeStaleAfterTenMinutes() throws {
        let snapshot = try XCTUnwrap(
            InputStatusClient.decodeSnapshot(
                Data(
                    """
                    {
                      "all_ok": true,
                      "services": [
                        {"model": "gpt-5.6-sol", "last": {"ok": true}},
                        {"model": "gpt-5.6-terra", "last": {"ok": true}},
                        {"model": "gpt-5.5", "last": {"ok": true}}
                      ]
                    }
                    """.utf8
                ),
                readAt: now
            )
        )

        XCTAssertEqual(
            snapshot.displayProbes(now: now.addingTimeInterval(600)).map(\.state),
            [.connected, .connected, .connected]
        )
        XCTAssertEqual(
            snapshot.displayProbes(now: now.addingTimeInterval(601)).map(\.state),
            [.stale, .stale, .stale]
        )
    }

    func testStatusRequestUsesConfiguredEndpointAndFifteenSecondTimeout() async throws {
        let endpoint = URL(string: "https://status.fixture.test/api/status")!
        let loader = RecordingInputStatusLoader()

        _ = try await InputStatusClient(
            endpoint: endpoint,
            requestLoader: loader
        ).fetch(now: now)

        XCTAssertEqual(loader.lastRequest?.url, endpoint)
        XCTAssertEqual(
            loader.lastRequest?.timeoutInterval,
            InputStatusConstants.requestTimeout
        )
    }

    func testClosedPanelUsesFiveMinuteInputStatusRefresh() {
        XCTAssertEqual(
            InputStatusRefreshPolicy.automaticInterval(panelPresented: true),
            60
        )
        XCTAssertEqual(
            InputStatusRefreshPolicy.automaticInterval(panelPresented: false),
            300
        )
    }

    func testStatusBarDotSharesSlowToneWithPanel() {
        // v3.2 第 1 点：高延迟(>=3000ms)时，状态栏点与面板点必须同为橙(slow)，
        // 不再出现「面板橙、状态栏绿」——两处都走 indicatorTone。
        let slowProbe = InputStatusProbe(
            model: "gpt-5.6-sol",
            uptimePercentage: 96,
            isOK: true,
            latencyMilliseconds: 8000,
            history: [
                InputStatusHistoryPoint(timestamp: 1, isOK: true, latencyMilliseconds: 8000),
            ]
        )
        let slowDisplay = InputStatusDisplayProbe(probe: slowProbe, state: .connected)
        XCTAssertEqual(InputStatusPresentation.indicatorTone(for: slowDisplay), .slow)
        XCTAssertEqual(
            InputStatusPresentation.indicatorTone(for: slowDisplay).appKitColor,
            SentinelTheme.AppKitColors.warning
        )

        // 正常低延迟仍为绿
        let okProbe = InputStatusProbe(
            model: "gpt-5.5",
            uptimePercentage: 99,
            isOK: true,
            latencyMilliseconds: 400,
            history: [InputStatusHistoryPoint(timestamp: 1, isOK: true, latencyMilliseconds: 400)]
        )
        let okDisplay = InputStatusDisplayProbe(probe: okProbe, state: .connected)
        XCTAssertEqual(InputStatusPresentation.indicatorTone(for: okDisplay).appKitColor,
                       SentinelTheme.AppKitColors.success)

        // 过期数据为灰
        let staleDisplay = InputStatusDisplayProbe(probe: okProbe, state: .stale)
        XCTAssertEqual(InputStatusPresentation.indicatorTone(for: staleDisplay), .missing)
    }

    func testStatusBarRendererProducesOriginalBitmap() {
        let snapshot = InputStatusSnapshot(
            allOK: false,
            probes: [
                InputStatusProbe(
                    model: "gpt-5.6-sol",
                    uptimePercentage: 99.9,
                    isOK: true,
                    latencyMilliseconds: 80
                ),
                InputStatusProbe(
                    model: "gpt-5.5",
                    uptimePercentage: 99.8,
                    isOK: false,
                    latencyMilliseconds: 120
                ),
            ],
            readAt: now,
            errorMessage: nil
        )
        let balances = [
            StatusBarBalanceItem(
                providerID: 1,
                providerName: "第一把",
                text: "9",
                isLowBalance: true
            ),
            StatusBarBalanceItem(
                providerID: 2,
                providerName: "第二把",
                text: "360",
                isLowBalance: false
            ),
        ]

        let image = SentinelStatusBarRenderer.image(
            probes: snapshot.displayProbes(now: now),
            balances: balances
        )

        XCTAssertFalse(image.isTemplate)
        XCTAssertEqual(image.size.height, SentinelTheme.StatusBar.height)
        XCTAssertGreaterThan(image.size.width, image.size.height)
        XCTAssertNotNil(image.tiffRepresentation)
    }
}

private final class RecordingInputStatusLoader: InputStatusRequestLoading, @unchecked Sendable {
    private(set) var lastRequest: URLRequest?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        let data = Data(
            """
            {
              "all_ok": true,
              "services": []
            }
            """.utf8
        )
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}
