import XCTest
@testable import CortexSentinelBar

final class SentinelFileReaderTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-07-23T11:00:05Z")!

    func testDiscoversAndParsesGrokStatusContract() throws {
        let fileManager = FileManager.default
        let logsDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "CortexSentinelGrok-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: logsDirectory) }

        let fixture = try fixtureURL("grok-status", extension: "json")
        try fileManager.copyItem(
            at: fixture,
            to: logsDirectory.appendingPathComponent("grok-grokboard.status.json")
        )
        try Data("{}".utf8).write(
            to: logsDirectory.appendingPathComponent("grok-ignore.json")
        )

        let lines = SentinelFileReader.readLines(in: logsDirectory)
        let line = try XCTUnwrap(lines.first)

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(line.slug, "grokboard")
        XCTAssertEqual(line.engine, .cursorGrok)
        XCTAssertEqual(line.state, .running)
        XCTAssertEqual(line.model, "cursor-grok-4.6-xhigh-fast")
        XCTAssertEqual(line.processID, 12_345)
        XCTAssertEqual(line.logBytes, 10_234)
        XCTAssertNil(line.exitCode)
        XCTAssertFalse(line.reportsRestarts)
        XCTAssertEqual(line.restarts, 0)
        XCTAssertNil(line.relay)
        XCTAssertNil(line.relayProbe)
        XCTAssertNil(line.balance)
        XCTAssertNil(line.rolloutAgeSeconds)
        XCTAssertFalse(line.reportsCodexChannelTelemetry)
    }

    func testParsesChannelStatusContract() throws {
        let json = """
        {
          "generated_at": "2026-08-18T23:40:00+08:00",
          "channels": {
            "grok": {"status": "alive", "evidence": "2 条在跑", "running": 2},
            "codex": {"status": "degraded", "evidence": "1 条 pid 已死但 state 非终态: orphan"}
          }
        }
        """
        let snapshot = SentinelFileReader.parseChannelStatus(data: Data(json.utf8))

        XCTAssertEqual(snapshot.grok.status, .alive)
        XCTAssertEqual(snapshot.grok.evidence, "2 条在跑")
        XCTAssertEqual(snapshot.grok.running, 2)
        XCTAssertEqual(snapshot.grok.status.displayName, "通")
        XCTAssertEqual(snapshot.codex.status, .degraded)
        XCTAssertEqual(snapshot.codex.evidence, "1 条 pid 已死但 state 非终态: orphan")
        XCTAssertNil(snapshot.codex.running)
        XCTAssertEqual(snapshot.codex.runningCount, 0)
        XCTAssertEqual(snapshot.codex.status.displayName, "不通")
        XCTAssertEqual(
            SentinelFileReader.parseChannelStatus(data: Data("{}".utf8)).grok.status.displayName,
            "无数据"
        )
        XCTAssertNotNil(snapshot.generatedAt)
        XCTAssertEqual(
            SentinelFileReader.parseChannelStatus(data: Data("{}".utf8)).grok.status,
            .unknown
        )
        XCTAssertEqual(
            SentinelFileReader.parseChannelStatus(data: Data("{}".utf8)).grok.runningCount,
            0
        )
    }

    func testGrokFallbackSlugRemovesGrokPrefix() throws {
        let fileManager = FileManager.default
        let logsDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "CortexSentinelGrokFallback-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: logsDirectory) }
        try Data(#"{"state":"running","agent_pid":42}"#.utf8).write(
            to: logsDirectory.appendingPathComponent("grok-fallback-line.status.json")
        )

        let line = try XCTUnwrap(SentinelFileReader.readLines(in: logsDirectory).first)

        XCTAssertEqual(line.slug, "fallback-line")
        XCTAssertEqual(line.engine, .cursorGrok)
        XCTAssertEqual(line.processID, 42)
    }

    func testKilledIsParsedAsTerminalState() {
        let line = SentinelFileReader.parseLine(
            data: Data(#"{"engine":"cursor-grok","slug":"stopped","state":"killed"}"#.utf8),
            fallbackSlug: "fallback",
            sourceFile: URL(fileURLWithPath: "/tmp/grok-stopped.status.json"),
            sourceModifiedAt: now
        )

        XCTAssertEqual(line.state, .killed)
        XCTAssertTrue(line.state.isTerminal)
        XCTAssertEqual(line.state.displayName, "已停止")
        XCTAssertEqual(
            SentinelAggregation.lineGroups(lines: [line], registry: .empty, now: now)
                .recentlyCompleted.map(\.line.slug),
            ["stopped"]
        )
    }

    func testGrokOnlyDirectoryDoesNotAffectTopBalanceOrRelayPresentation() throws {
        let fileManager = FileManager.default
        let logsDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "CortexSentinelGrokOnly-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: logsDirectory) }
        try fileManager.copyItem(
            at: fixtureURL("grok-status", extension: "json"),
            to: logsDirectory.appendingPathComponent("grok-grokboard.status.json")
        )

        let lines = SentinelFileReader.readLines(in: logsDirectory)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.engine, .cursorGrok)

        let relay = AIOProvider(
            id: 41,
            name: "fixture-relay",
            baseURL: "https://relay.example.test/v1",
            enabled: true,
            routeOrder: 0,
            providerOrder: 0,
            note: "",
            circuitState: .closed,
            failureCount: 0,
            usage: .success(
                AIOUsage(
                    response: AIOUsageResponse(
                        remaining: 88,
                        unit: "USD",
                        planName: "fixture",
                        subscription: AIOUsageSubscription(expiresAt: nil),
                        isValid: true
                    )
                )
            )
        )
        let aio = AIOSnapshot(
            sourceState: .available,
            gatewayEnabled: true,
            routeMode: .aggregate,
            providers: [relay],
            lastHitProviderID: relay.id,
            lastHitProviderName: relay.name,
            readAt: now,
            errorMessage: nil
        )
        let top = SentinelTopChannelPresentation(aio: aio)

        XCTAssertEqual(top.balanceCountText, "官方 + 1 把")
        XCTAssertEqual(aio.statusBarBalances.map(\.text), ["$88"])
        XCTAssertEqual(top.routeSummary, "最后命中：fixture-relay")
        XCTAssertFalse(top.balanceCountText.contains("异常"))
        XCTAssertFalse(top.routeSummary.contains("异常"))
        XCTAssertFalse(top.routeSummary.contains("未知"))
    }

    func testFixtureAggregationCoversAllFourStates() throws {
        XCTAssertEqual(severity(for: "green"), .green)
        XCTAssertEqual(severity(for: "amber"), .amber)
        XCTAssertEqual(severity(for: "red"), .red)
        XCTAssertEqual(severity(for: "gray"), .gray)
    }

    func testDeadLineNoteDistinguishesHandledAndUnhandledRendering() throws {
        let note = "已核对样例进程与产物，保留主产物并将其余工作转入后续融合线；结论是不再重派。"
        let handled = SentinelFileReader.parseLine(
            data: Data(
                """
                {
                  "slug": "handled-dead",
                  "state": "dead",
                  "note": "\(note)"
                }
                """.utf8
            ),
            fallbackSlug: "handled-dead",
            sourceFile: URL(fileURLWithPath: "/tmp/handled-dead.status.json"),
            sourceModifiedAt: now
        )
        let unhandled = SentinelFileReader.parseLine(
            data: Data(
                """
                {
                  "slug": "unhandled-dead",
                  "state": "dead"
                }
                """.utf8
            ),
            fallbackSlug: "unhandled-dead",
            sourceFile: URL(fileURLWithPath: "/tmp/unhandled-dead.status.json"),
            sourceModifiedAt: now
        )

        let handledPresentation = LineDispositionPresentation(line: handled)
        let unhandledPresentation = LineDispositionPresentation(line: unhandled)

        XCTAssertEqual(handled.note, note)
        XCTAssertEqual(handledPresentation.stateText, "已处置")
        XCTAssertEqual(handledPresentation.symbolName, "checkmark.seal.fill")
        XCTAssertEqual(handledPresentation.markerText, "已有处置记录")
        XCTAssertEqual(handledPresentation.note, note)
        XCTAssertFalse(handledPresentation.requiresAttention)

        XCTAssertNil(unhandled.note)
        XCTAssertEqual(unhandledPresentation.stateText, "已失联")
        XCTAssertEqual(unhandledPresentation.symbolName, "xmark.circle.fill")
        XCTAssertNil(unhandledPresentation.markerText)
        XCTAssertNil(unhandledPresentation.note)
        XCTAssertTrue(unhandledPresentation.requiresAttention)

        XCTAssertEqual(
            SentinelAggregation.severity(lines: [handled], aio: .unconfigured, now: now),
            .amber
        )
        XCTAssertEqual(
            SentinelAggregation.severity(lines: [unhandled], aio: .unconfigured, now: now),
            .red
        )
    }

    func testBlankDeadLineNoteRemainsUnhandled() {
        let line = SentinelFileReader.parseLine(
            data: Data(
                """
                {
                  "slug": "blank-note-dead",
                  "state": "dead",
                  "note": "     "
                }
                """.utf8
            ),
            fallbackSlug: "blank-note-dead",
            sourceFile: URL(fileURLWithPath: "/tmp/blank-note-dead.status.json"),
            sourceModifiedAt: now
        )

        XCTAssertNil(line.note)
        XCTAssertTrue(line.requiresAttention)
        XCTAssertEqual(LineDispositionPresentation(line: line).stateText, "已失联")
    }

    func testParsesPoolHealthActiveAndSwitchContract() throws {
        let relay = try relayFixture(named: "green")

        XCTAssertEqual(relay.sourceState, .available)
        XCTAssertEqual(relay.entries.count, 1)
        XCTAssertEqual(relay.entries.first?.id, "relay-self")
        XCTAssertEqual(relay.entries.first?.owner, .selfOwned)
        XCTAssertEqual(relay.entries.first?.maskedAPIKey, "sk-...1234")
        XCTAssertEqual(relay.active?.activeID, "relay-self")
        XCTAssertEqual(relay.active?.generation, 2)
        XCTAssertEqual(relay.activeHealth?.ok, true)
        XCTAssertEqual(BalancePresentation(health: relay.activeHealth), .amount(42.5, "USD"))
        XCTAssertEqual(relay.latestSwitch?.caller, "green-line-12")
        XCTAssertEqual(relay.latestSwitch?.probeOK, true)

        let line = try statusFixture(named: "green")
        XCTAssertEqual(line.processID, 42001)
        XCTAssertEqual(line.relay?.baseURLAtSpawn, "https://relay.example.test/v1")
        XCTAssertEqual(
            RelayAttribution.resolve(line: line, relay: relay),
            RelayAttribution(text: "主用出口", isReported: true)
        )
    }

    func testBalanceStatesFollowContract() throws {
        XCTAssertEqual(
            BalancePresentation(health: try relayFixture(named: "amber").activeHealth),
            .depleted
        )
        XCTAssertEqual(
            BalancePresentation(health: try relayFixture(named: "red").activeHealth),
            .unsupported
        )
        XCTAssertEqual(BalancePresentation(health: nil), .unavailable)
    }

    func testMissingFilesGracefullyDegradeToUnconfigured() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CortexSentinelBar-missing-\(UUID().uuidString)")
        let relay = SentinelFileReader.readRelays(
            at: RelayFileLocations(
                pool: root.appendingPathComponent("pool.json"),
                health: root.appendingPathComponent("health.json"),
                active: root.appendingPathComponent("active.json"),
                switchLog: root.appendingPathComponent("switch-log.jsonl")
            )
        )

        XCTAssertEqual(relay.sourceState, .unconfigured)
        XCTAssertEqual(SentinelFileReader.readLines(in: root), [])
        XCTAssertEqual(SentinelAggregation.severity(lines: [], relay: relay, now: now), .gray)
    }

    func testStatusDirectoryFollowsWorktreeSymlink() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("CortexSentinelBar-symlink-\(UUID().uuidString)", isDirectory: true)
        let target = root.appendingPathComponent("shared-logs", isDirectory: true)
        let link = root.appendingPathComponent("logs", isDirectory: true)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
        let fixture = try fixtureURL("green-status", extension: "json")
        try fileManager.copyItem(
            at: fixture,
            to: target.appendingPathComponent("codex-babysitter-symlink.status.json")
        )

        let lines = SentinelFileReader.readLines(in: link)

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.slug, "green-line")
    }

    func testMissingBranchStaysNilAndDoesNotCrash() throws {
        let line = try statusFixture(named: "amber")

        XCTAssertNil(line.branch)
        XCTAssertEqual(line.worktreeName, "amber-line")
        XCTAssertEqual(line.state, .backoff)
    }

    func testWaitingRelayFixtureDecodesProbeContractAndPresentation() throws {
        let line = try statusFixture(named: "waiting-relay")

        XCTAssertEqual(line.state, .waitingRelay)
        XCTAssertEqual(line.state.displayName, "等中转恢复")
        XCTAssertEqual(line.state.symbolName, "hourglass")
        XCTAssertFalse(line.state.isCritical)
        XCTAssertFalse(line.state.isRetrying)
        XCTAssertEqual(line.maxRestartsOverride, 7)
        XCTAssertEqual(line.escalateAfterFailures, 4)
        XCTAssertEqual(line.balance?.scope, "official_weekly")
        XCTAssertEqual(line.balance?.planType, "plus")
        XCTAssertEqual(line.balance?.weeklyUsedPercentage, 75)
        XCTAssertEqual(line.balance?.fiveHourUsedPercentage, 20.5)
        XCTAssertEqual(
            SentinelAggregation.severity(
                lines: [line],
                relay: try relayFixture(named: "green"),
                now: now
            ),
            .amber
        )
        XCTAssertEqual(
            line.relayProbe,
            LineRelayProbe(
                state: "unhealthy",
                checkedAt: "2026-07-31T02:10:00+00:00",
                lastOK: false,
                recentOK: [false, false],
                detail: "last.ok=false",
                primaryProvider: "aio",
                activeProvider: "aio",
                fallbackProvider: "codex_local_access",
                fallbackAttempted: true,
                switchCount: 1,
                lastSwitchAt: "2026-07-31T01:05:00+00:00",
                firstFailureAt: "2026-07-31T01:00:00+00:00"
            )
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let presentation = LineRelayProbePresentation.details(
            for: try XCTUnwrap(line.relayProbe),
            now: ISO8601DateFormatter().date(from: "2026-07-31T02:10:00Z")!,
            calendar: calendar
        )
        XCTAssertEqual(
            presentation,
            [
                RelayProbeDetail(label: "出口", value: "aio"),
                RelayProbeDetail(label: "探针", value: "不可用 · 最近失败 · 近 2 次有失败 · 02:10"),
                RelayProbeDetail(label: "等待", value: "已等 1 小时 10 分钟"),
                RelayProbeDetail(label: "备用", value: "已尝试 codex_local_access · 切换 1 次"),
            ]
        )
    }

    func testOfficialWeeklyBalanceUsesHumanReadableResetDate() {
        let line = parseStatus(
            """
            {
              "state": "waiting_relay",
              "balance": {
                "scope": "official_weekly",
                "plan_type": "plus",
                "weekly_used_pct": 75,
                "weekly_reset_at": "2026-08-08T20:39:19Z"
              }
            }
            """
        )

        XCTAssertEqual(
            OfficialQuotaPresentation.rows(for: line.balance),
            [OfficialQuotaRow(text: "官方周额度剩 25% · 8/9 重置", isWarning: false)]
        )
    }

    func testOfficialWeeklyBalanceUsesProviderNameAndMarksStaleData() {
        let line = parseStatus(
            """
            {
              "state": "running",
              "balance": {
                "scope": "official_weekly",
                "provider_name": "GPT PRO",
                "email": "fixture@example.test",
                "weekly_used_pct": 4,
                "weekly_reset_at": "2026-08-08T04:39:19Z",
                "stale": true,
                "note": "官方额度接口暂不可达"
              }
            }
            """
        )

        XCTAssertEqual(
            OfficialQuotaPresentation.rows(for: line.balance),
            [
                OfficialQuotaRow(
                    text: "GPT PRO·周额度剩 96% · 8/8 重置 · 数据已过期",
                    isWarning: true
                ),
                OfficialQuotaRow(text: "官方额度接口暂不可达", isWarning: true),
            ]
        )
    }

    func testOfficialWeeklyBalanceFallsBackToEmailUserName() {
        let line = parseStatus(
            """
            {
              "state": "running",
              "balance": {
                "scope": "official_weekly",
                "email": "user1234@example.test",
                "weekly_used_pct": 4,
                "weekly_reset_at": "2026-08-08T04:39:19Z"
              }
            }
            """
        )

        XCTAssertEqual(
            OfficialQuotaPresentation.rows(for: line.balance),
            [OfficialQuotaRow(text: "user1234·周额度剩 96% · 8/8 重置", isWarning: false)]
        )
    }

    func testOfficialWeeklyBalanceShowsUpstreamNote() {
        let line = parseStatus(
            """
            {
              "state": "running",
              "balance": {
                "scope": "official_weekly",
                "note": "官方额度接口暂不可达"
              }
            }
            """
        )

        XCTAssertEqual(
            OfficialQuotaPresentation.rows(for: line.balance),
            [OfficialQuotaRow(text: "官方额度接口暂不可达", isWarning: true)]
        )
    }

    func testOfficialWeeklyBalanceAddsFiveHourRowOnlyWhenPresent() {
        let line = parseStatus(
            """
            {
              "state": "running",
              "balance": {
                "scope": "official_weekly",
                "weekly_used_pct": 68,
                "weekly_reset_at": "2026-08-08T04:39:19Z",
                "five_hour_used_pct": 12.5,
                "five_hour_reset_at": "2026-08-02T12:30:00Z"
              }
            }
            """
        )

        XCTAssertEqual(
            OfficialQuotaPresentation.rows(for: line.balance),
            [
                OfficialQuotaRow(text: "官方周额度剩 32% · 8/8 重置", isWarning: false),
                OfficialQuotaRow(text: "5 小时额度剩 87.5% · 8/2 20:30 重置", isWarning: false),
            ]
        )
    }

    func testOfficialQuotaRemainingPercentageIsClamped() {
        XCTAssertEqual(OfficialQuotaPresentation.remainingPercentage(fromUsed: -5), 100)
        XCTAssertEqual(OfficialQuotaPresentation.remainingPercentage(fromUsed: 125), 0)
    }

    func testLegacyStatusWithoutRelayProbeKeepsRelayContract() throws {
        let line = try statusFixture(named: "green")

        XCTAssertNil(line.relayProbe)
        XCTAssertEqual(line.relay?.activeID, "relay-self")
        XCTAssertEqual(line.relay?.baseURLAtSpawn, "https://relay.example.test/v1")
    }

    func testRelayProbeMissingAndUnknownFieldsDoNotBreakStatus() {
        let source = URL(fileURLWithPath: "/tmp/codex-babysitter-partial-probe.status.json")
        let data = Data(
            """
            {
              "slug": "partial-probe",
              "state": "waiting_relay",
              "relay_probe": {
                "state": "unknown",
                "future_field": {"nested": true}
              }
            }
            """.utf8
        )

        let line = SentinelFileReader.parseLine(
            data: data,
            fallbackSlug: "partial-probe",
            sourceFile: source
        )

        XCTAssertEqual(line.state, .waitingRelay)
        XCTAssertEqual(line.relayProbe?.state, "unknown")
        XCTAssertNil(line.relayProbe?.checkedAt)
        XCTAssertNil(line.relayProbe?.fallbackAttempted)
    }

    func testBlankBranchIsTreatedAsUnreported() {
        let source = URL(fileURLWithPath: "/tmp/codex-babysitter-blank-branch.status.json")
        let data = Data(
            """
            {
              "slug": "blank-branch",
              "state": "running",
              "branch": "   "
            }
            """.utf8
        )

        let line = SentinelFileReader.parseLine(
            data: data,
            fallbackSlug: "blank-branch",
            sourceFile: source
        )

        XCTAssertNil(line.branch)
    }

    func testRelayAttributionFallsBackToReportedDomain() throws {
        let source = URL(fileURLWithPath: "/tmp/codex-babysitter-domain.status.json")
        let data = Data(
            """
            {
              "slug": "domain-line",
              "state": "running",
              "relay": {"base_url_at_spawn": "https://fallback.example.test/v1"}
            }
            """.utf8
        )
        let line = SentinelFileReader.parseLine(
            data: data,
            fallbackSlug: "domain-line",
            sourceFile: source
        )

        XCTAssertEqual(
            RelayAttribution.resolve(line: line, relay: .unconfigured),
            RelayAttribution(text: "fallback.example.test", isReported: true)
        )
    }

    func testMalformedStatusBecomesVisibleUnknownState() {
        let line = SentinelFileReader.parseLine(
            data: Data("{broken".utf8),
            fallbackSlug: "broken-line",
            sourceFile: URL(fileURLWithPath: "/tmp/codex-babysitter-broken-line.status.json"),
            sourceModifiedAt: now
        )

        XCTAssertEqual(line.slug, "broken-line")
        XCTAssertEqual(line.state, .unknown("invalid"))
        XCTAssertEqual(
            SentinelAggregation.severity(lines: [line], relay: .unconfigured, now: now),
            .amber
        )
    }

    func testStaleRunningLineDoesNotRaiseActiveSeverity() throws {
        var line = try statusFixture(named: "green")
        line = LineStatus(
            sourceFile: line.sourceFile,
            slug: line.slug,
            workdir: line.workdir,
            branch: line.branch,
            state: line.state,
            restarts: line.restarts,
            rolloutAgeSeconds: line.rolloutAgeSeconds,
            updatedAt: now,
            sourceModifiedAt: now.addingTimeInterval(-601),
            relay: line.relay
        )

        XCTAssertEqual(
            SentinelAggregation.severity(lines: [line], relay: try relayFixture(named: "green"), now: now),
            .gray
        )
    }

    func testStaleRolloutIsAmber() throws {
        var line = try statusFixture(named: "green")
        line = LineStatus(
            sourceFile: line.sourceFile,
            slug: line.slug,
            workdir: line.workdir,
            branch: line.branch,
            state: line.state,
            restarts: line.restarts,
            rolloutAgeSeconds: 601,
            updatedAt: line.updatedAt,
            sourceModifiedAt: now,
            relay: line.relay
        )

        XCTAssertEqual(
            SentinelAggregation.severity(lines: [line], relay: try relayFixture(named: "green"), now: now),
            .amber
        )
    }

    func testPathEnvironmentOverridesRepositoryAndPoolRoots() {
        let paths = SentinelPaths.discover(
            environment: [
                "CORTEX_REPO_ROOT": "/tmp/cortex-fixture-repo",
                "CORTEX_RELAY_POOL_DIR": "/tmp/cortex-fixture-pool",
                "CORTEX_CODEX_AUTH_PATH": "/tmp/cortex-fixture-auth.json",
            ],
            currentDirectory: URL(fileURLWithPath: "/tmp"),
            executableURL: nil
        )

        XCTAssertEqual(paths.repositoryRoot.path, "/tmp/cortex-fixture-repo")
        XCTAssertEqual(paths.poolDirectory.path, "/tmp/cortex-fixture-pool")
        XCTAssertEqual(paths.logsDirectory.path, "/tmp/cortex-fixture-repo/logs")
        XCTAssertEqual(paths.codexAuthURL.path, "/tmp/cortex-fixture-auth.json")
    }

    func testWatchDirEnvironmentSelectsLogsDirectoryDirectly() {
        let paths = SentinelPaths.discover(
            environment: [
                "CORTEX_SENTINEL_WATCH_DIR": "/tmp/sentinel-watch-dir",
                "CORTEX_REPO_ROOT": "/tmp/cortex-fixture-repo",
            ],
            currentDirectory: URL(fileURLWithPath: "/tmp"),
            executableURL: nil
        )

        XCTAssertEqual(paths.logsDirectory.path, "/tmp/sentinel-watch-dir")
        XCTAssertEqual(paths.repositoryRoot.path, "/tmp/cortex-fixture-repo")
    }

    func testDefaultWatchDirectoryIsHomeCortexSentinelLogs() {
        let defaults = UserDefaults(suiteName: "sentinel-paths-default-\(UUID().uuidString)")!
        let paths = SentinelPaths.discover(
            environment: [:],
            currentDirectory: URL(fileURLWithPath: "/tmp"),
            executableURL: nil,
            defaults: defaults
        )
        let expected = SentinelPaths.defaultWatchDirectory
        XCTAssertEqual(paths.logsDirectory.path, expected.path)
        XCTAssertEqual(
            paths.repositoryRoot.path,
            expected.deletingLastPathComponent().path
        )
        XCTAssertTrue(paths.missingWatchDirectoryMessage.contains(expected.path))
        XCTAssertEqual(SentinelPaths.missingWatchDirectoryTitle, "还没有可盯的线")
        XCTAssertEqual(
            SentinelPaths.missingWatchDirectoryBody,
            "哨兵盯一个目录，里面是派工工具写的状态文件。这个目录现在还不存在。"
        )
        XCTAssertEqual(
            SentinelPaths.missingWatchDirectoryHint,
            "默认位置 ~/.cortex-sentinel/logs，把状态文件放进去就能看到。要换地方，设 CORTEX_SENTINEL_WATCH_DIR。"
        )
        XCTAssertFalse(SentinelPaths.missingWatchDirectoryTitle.contains("CORTEX_REPO_ROOT"))
        XCTAssertFalse(SentinelPaths.missingWatchDirectoryBody.contains("CORTEX_REPO_ROOT"))
        XCTAssertFalse(SentinelPaths.missingWatchDirectoryHint.contains("CORTEX_REPO_ROOT"))
    }

    func testStatusRewriteDoesNotChangeEstablishedOrder() {
        let source = URL(fileURLWithPath: "/tmp/status.json")
        let firstStarted = now.addingTimeInterval(-120)
        let secondStarted = now.addingTimeInterval(-60)
        let initial = [
            LineStatus(
                sourceFile: source.appendingPathComponent("second"),
                slug: "second",
                workdir: nil,
                branch: nil,
                state: .running,
                restarts: 0,
                rolloutAgeSeconds: 1,
                updatedAt: now,
                sourceModifiedAt: now,
                startedAt: secondStarted,
                relay: nil
            ),
            LineStatus(
                sourceFile: source.appendingPathComponent("first"),
                slug: "first",
                workdir: nil,
                branch: nil,
                state: .running,
                restarts: 0,
                rolloutAgeSeconds: 1,
                updatedAt: now.addingTimeInterval(-30),
                sourceModifiedAt: now.addingTimeInterval(-30),
                startedAt: firstStarted,
                relay: nil
            ),
        ]
        let rewritten = [
            LineStatus(
                sourceFile: source.appendingPathComponent("first"),
                slug: "first",
                workdir: nil,
                branch: nil,
                state: .running,
                restarts: 0,
                rolloutAgeSeconds: 1,
                updatedAt: now.addingTimeInterval(30),
                sourceModifiedAt: now.addingTimeInterval(30),
                startedAt: firstStarted,
                relay: nil
            ),
            initial[0],
        ]

        XCTAssertEqual(SentinelAggregation.sortedLines(initial, now: now).map(\.slug), ["first", "second"])
        XCTAssertEqual(SentinelAggregation.sortedLines(rewritten, now: now).map(\.slug), ["first", "second"])
    }

    func testStatusFileRenderingKeepsEstablishedOrderAcrossRewritesAndAppend() throws {
        let fileManager = FileManager.default
        let logsDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "CortexSentinelOrder-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: logsDirectory)
        }

        try writeStatus(
            slug: "newer-alpha",
            startedAt: "2026-08-05T02:02:00Z",
            updatedAt: "2026-08-05T02:03:00Z",
            to: logsDirectory
        )
        try writeStatus(
            slug: "older-zulu",
            startedAt: "2026-08-05T02:01:00Z",
            updatedAt: "2026-08-05T02:04:00Z",
            to: logsDirectory
        )

        let initial = renderedActiveOrder(in: logsDirectory)
        for minute in 5...7 {
            try writeStatus(
                slug: "newer-alpha",
                startedAt: "2026-08-05T02:02:00Z",
                updatedAt: "2026-08-05T02:\(String(format: "%02d", minute)):00Z",
                to: logsDirectory
            )
        }
        let afterRewrites = renderedActiveOrder(in: logsDirectory)

        try writeStatus(
            slug: "latest-aardvark",
            startedAt: "2026-08-05T02:08:00Z",
            updatedAt: "2026-08-05T02:08:00Z",
            to: logsDirectory
        )
        let afterAppend = renderedActiveOrder(in: logsDirectory)

        print("ORDER_FIXTURE initial=\(initial.joined(separator: ","))")
        print("ORDER_FIXTURE after_rewrites=\(afterRewrites.joined(separator: ","))")
        print("ORDER_FIXTURE after_append=\(afterAppend.joined(separator: ","))")
        XCTAssertEqual(initial, ["older-zulu", "newer-alpha"])
        XCTAssertEqual(afterRewrites, initial)
        XCTAssertEqual(afterAppend, ["older-zulu", "newer-alpha", "latest-aardvark"])
    }

    func testNewLineAppendsByStartTime() {
        let existing = [
            makeSortableLine(slug: "first", startedAt: now.addingTimeInterval(-120)),
            makeSortableLine(slug: "second", startedAt: now.addingTimeInterval(-60)),
        ]
        let newLine = makeSortableLine(slug: "new-line", startedAt: now)

        XCTAssertEqual(
            SentinelAggregation.sortedLines([newLine] + existing, now: now).map(\.slug),
            ["first", "second", "new-line"]
        )
    }

    func testMissingStartTimesSortLastBySlugDeterministically() {
        let lines = [
            makeSortableLine(slug: "missing-zulu", startedAt: nil),
            makeSortableLine(slug: "dated", startedAt: now),
            makeSortableLine(slug: "missing-alpha", startedAt: nil),
        ]

        XCTAssertEqual(
            SentinelAggregation.sortedLines(lines, now: now).map(\.slug),
            ["dated", "missing-alpha", "missing-zulu"]
        )
    }

    private func makeSortableLine(slug: String, startedAt: Date?) -> LineStatus {
        LineStatus(
            sourceFile: URL(fileURLWithPath: "/tmp/\(slug).status.json"),
            slug: slug,
            workdir: nil,
            branch: nil,
            state: .running,
            restarts: 0,
            rolloutAgeSeconds: 1,
            updatedAt: now,
            sourceModifiedAt: now,
            startedAt: startedAt,
            relay: nil
        )
    }

    private func writeStatus(
        slug: String,
        startedAt: String,
        updatedAt: String,
        to logsDirectory: URL
    ) throws {
        let json = """
        {
          "slug": "\(slug)",
          "state": "running",
          "started_at": "\(startedAt)",
          "updated_at": "\(updatedAt)"
        }
        """
        let url = logsDirectory.appendingPathComponent("codex-babysitter-\(slug).status.json")
        try Data(json.utf8).write(to: url, options: .atomic)
    }

    private func renderedActiveOrder(in logsDirectory: URL) -> [String] {
        let lines = SentinelFileReader.readLines(in: logsDirectory)
        let groups = SentinelAggregation.lineGroups(
            lines: lines,
            registry: .empty,
            now: Date()
        )
        return groups.activeUnregistered.map(\.line.slug)
    }

    private func severity(for prefix: String) -> SentinelSeverity {
        let relay = try! relayFixture(named: prefix)
        let line = try! statusFixture(named: prefix)
        return SentinelAggregation.severity(lines: [line], relay: relay, now: now)
    }

    private func parseStatus(_ json: String) -> LineStatus {
        SentinelFileReader.parseLine(
            data: Data(json.utf8),
            fallbackSlug: "quota-line",
            sourceFile: URL(fileURLWithPath: "/tmp/codex-babysitter-quota-line.status.json")
        )
    }

    private func relayFixture(named prefix: String) throws -> RelaySnapshot {
        SentinelFileReader.readRelays(
            at: RelayFileLocations(
                pool: try fixtureURL("\(prefix)-pool", extension: "json"),
                health: try fixtureURL("\(prefix)-health", extension: "json"),
                active: try fixtureURL("\(prefix)-active", extension: "json"),
                switchLog: try fixtureURL("\(prefix)-switch-log", extension: "jsonl")
            )
        )
    }

    private func statusFixture(named prefix: String) throws -> LineStatus {
        let url = try fixtureURL("\(prefix)-status", extension: "json")
        return SentinelFileReader.parseLine(
            data: try Data(contentsOf: url),
            fallbackSlug: "\(prefix)-fallback",
            sourceFile: url,
            sourceModifiedAt: now
        )
    }

    private func fixtureURL(_ name: String, extension: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: `extension`) else {
            throw XCTSkip("fixture \(name).\(`extension`) is unavailable")
        }
        return url
    }
}
