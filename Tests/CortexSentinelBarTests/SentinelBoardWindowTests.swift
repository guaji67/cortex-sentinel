import Foundation
import XCTest
@testable import CortexSentinelBar

final class SentinelBoardWindowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    func testNewestGrokCompletionsFillRecentWindowAndKeepCodex() throws {
        let grokSlugs = ["boardcheck", "distdir", "flakyfamily", "diskclean", "pkgparity", "askslow", "feishusync"]
        let recentCodex = (0..<12).map { "codex-recent-\($0)" }
        let historyCodex = (0..<30).map { "codex-old-\($0)" }

        var entries: [(slug: String, engine: String, label: String, registeredAt: TimeInterval)] = []
        entries.append(contentsOf: recentCodex.enumerated().map { index, slug in
            (slug, "codex", "旧完成 \(index)", now.timeIntervalSince1970 - 80_000 + TimeInterval(index))
        })
        entries.append(contentsOf: grokSlugs.enumerated().map { index, slug in
            (slug, "cursor-grok", "Grok \(slug)", now.timeIntervalSince1970 - 8_000 + TimeInterval(index))
        })
        entries.append(contentsOf: historyCodex.enumerated().map { index, slug in
            (slug, "codex", "更早 \(index)", now.timeIntervalSince1970 - 200_000 + TimeInterval(index))
        })
        let registry = try makeRegistry(entries)

        var lines: [LineStatus] = []
        lines.append(contentsOf: recentCodex.enumerated().map { index, slug in
            makeLine(slug: slug, engine: .codex, state: .done, age: 20_000 + TimeInterval(index) * 100)
        })
        lines.append(contentsOf: grokSlugs.enumerated().map { index, slug in
            makeLine(slug: slug, engine: .cursorGrok, state: .done, age: 1_000 + TimeInterval(index) * 10)
        })
        lines.append(contentsOf: historyCodex.enumerated().map { index, slug in
            makeLine(slug: slug, engine: .codex, state: .done, age: 90_000 + TimeInterval(index) * 10)
        })

        let groups = SentinelAggregation.lineGroups(lines: lines, registry: registry, now: now)
        let board = SentinelBoardWindow.snapshot(groups: groups)

        XCTAssertEqual(board.recentCounts.grok, 7)
        XCTAssertEqual(board.recentCounts.codex, 1)
        XCTAssertEqual(board.recentShown.count, 8)
        XCTAssertEqual(
            Set(board.recentShown.filter { $0.engine == .cursorGrok }.map(\.line.slug)),
            Set(grokSlugs)
        )
        XCTAssertTrue(board.recentShown.allSatisfy { $0.engine == .cursorGrok || $0.engine == .codex })
        XCTAssertGreaterThan(board.historyCounts.codex, 0)
        XCTAssertEqual(board.historyCounts.grok, 0)
        XCTAssertEqual(
            groups.recentlyCompleted.filter { $0.engine == .codex }.count,
            12
        )
        XCTAssertEqual(groups.history.filter { $0.engine == .codex }.count, 30)
    }

    func testOlderGrokStillShowsInHistoryWithGrokBadge() throws {
        let grokSlugs = ["distdir", "askslow", "feishusync"]
        let newerCodex = (0..<10).map { "codex-newer-\($0)" }

        var entries: [(slug: String, engine: String, label: String, registeredAt: TimeInterval)] = []
        entries.append(contentsOf: newerCodex.enumerated().map { index, slug in
            (slug, "codex", "更新 \(index)", now.timeIntervalSince1970 - 4_000 + TimeInterval(index))
        })
        entries.append(contentsOf: grokSlugs.enumerated().map { index, slug in
            (slug, "cursor-grok", "Grok \(slug)", now.timeIntervalSince1970 - 20_000 + TimeInterval(index))
        })
        let registry = try makeRegistry(entries)

        var lines: [LineStatus] = []
        lines.append(contentsOf: newerCodex.enumerated().map { index, slug in
            makeLine(slug: slug, engine: .codex, state: .done, age: 200 + TimeInterval(index) * 10)
        })
        lines.append(contentsOf: grokSlugs.enumerated().map { index, slug in
            makeLine(slug: slug, engine: .cursorGrok, state: .done, age: 5_000 + TimeInterval(index) * 10)
        })

        let board = SentinelBoardWindow.snapshot(
            groups: SentinelAggregation.lineGroups(lines: lines, registry: registry, now: now)
        )

        XCTAssertEqual(board.recentCounts.grok, 0)
        XCTAssertEqual(board.recentCounts.codex, 8)
        XCTAssertEqual(board.historyCounts.grok, 3)
        XCTAssertEqual(board.historyCounts.codex, 2)
        XCTAssertEqual(
            Set(board.historyShown.filter { $0.engine == .cursorGrok }.map(\.line.slug)),
            Set(grokSlugs)
        )
        XCTAssertTrue(
            board.historyShown.filter { $0.engine == .cursorGrok }
                .allSatisfy { $0.engine.displayName == "Grok" }
        )
    }

    func testHistoryDisplayKeepsNewest500AndArchivesTheRest() throws {
        let recent = (0..<8).map { "recent-\($0)" }
        let history = (0..<520).map { "hist-\($0)" }
        let entries = (recent + history).enumerated().map { index, slug in
            (slug, "codex", "线 \(slug)", now.timeIntervalSince1970 - 400_000 + TimeInterval(index))
        }
        let registry = try makeRegistry(entries)

        var lines: [LineStatus] = []
        lines.append(contentsOf: recent.enumerated().map { index, slug in
            makeLine(slug: slug, engine: .codex, state: .done, age: 600 + TimeInterval(index))
        })
        lines.append(contentsOf: history.enumerated().map { index, slug in
            makeLine(slug: slug, engine: .codex, state: .done, age: 90_000 + TimeInterval(520 - index))
        })

        let board = SentinelBoardWindow.snapshot(
            groups: SentinelAggregation.lineGroups(lines: lines, registry: registry, now: now)
        )

        XCTAssertEqual(board.recentShown.count, 8)
        XCTAssertEqual(board.historyShown.count, 500)
        XCTAssertEqual(board.hiddenCount, 20)
        XCTAssertEqual(board.historyCounts.codex, 500)
        XCTAssertEqual(board.hiddenCounts.codex, 20)
        XCTAssertEqual(board.historyShown.first?.line.slug, "hist-519")
        XCTAssertEqual(board.hidden.last?.line.slug, "hist-0")
        XCTAssertEqual(
            board.footerText,
            "另有 20 条更早记录未显示。按状态文件时间倒序只留最近 500 条；源文件仍在 logs/，登记表未改。"
        )

        let archive = board.archive()
        XCTAssertEqual(archive.kept, 500)
        XCTAssertEqual(archive.hiddenCount, 20)
        XCTAssertTrue(archive.criterion.contains("500"))
        XCTAssertEqual(archive.hidden.count, 20)
        XCTAssertEqual(archive.hidden.first?.slug, "hist-19")
        XCTAssertEqual(archive.hidden.last?.slug, "hist-0")
    }

    func testArchiveWriteDoesNotTouchRegistryFile() throws {
        let registryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-line-registry-\(UUID().uuidString).json")
        let original = Data(#"[{"slug":"keep-me","label_zh":"保留","dispatcher_zh":"来源","registered_at":1787000000}]"#.utf8)
        try original.write(to: registryURL)
        defer { try? FileManager.default.removeItem(at: registryURL) }

        let entries = (0..<4).map { index in
            ("line-\(index)", "codex", "线 \(index)", now.timeIntervalSince1970)
        }
        let registry = try makeRegistry(entries)
        let lines = (0..<4).map { index in
            makeLine(slug: "line-\(index)", engine: .codex, state: .done, age: 90_000 + TimeInterval(index))
        }
        let board = SentinelBoardWindow.snapshot(
            groups: SentinelAggregation.lineGroups(lines: lines, registry: registry, now: now),
            recentCap: 2,
            historyCap: 2
        )
        XCTAssertEqual(board.hiddenCount, 2)

        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sentinel-history-hidden-\(UUID().uuidString).json")
        try board.writeArchive(to: archiveURL)
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        XCTAssertEqual(try Data(contentsOf: registryURL), original)
        let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: archiveURL)) as? [String: Any]
        XCTAssertEqual(payload?["hiddenCount"] as? Int, 2)
        XCTAssertEqual(payload?["kept"] as? Int, 2)
    }

    func testActiveEngineCountsMatchFourRegisteredRunningGrokLines() throws {
        let slugs = ["diskclean", "casediga", "casedigb", "casedigc"]
        let localHost = LocalHostIdentity(identifiers: ["Test Mac"])
        let registry = try makeRegistry(
            slugs.map { slug in
                (slug, "cursor-grok", slug, now.timeIntervalSince1970)
            },
            host: "Test Mac"
        )
        let lines = slugs.map { slug in
            makeLine(slug: slug, engine: .cursorGrok, state: .running, age: 5)
        }
        let groups = SentinelAggregation.lineGroups(lines: lines, registry: registry, now: now)

        XCTAssertEqual(groups.activeRegistered.count, 4)
        XCTAssertEqual(groups.activeUnregistered.count, 0)
        XCTAssertEqual(groups.localActiveEngineCounts(localHost: localHost).grok, 4)
        XCTAssertEqual(groups.localActiveEngineCounts(localHost: localHost).codex, 0)
        XCTAssertEqual(
            ChannelSectionPresentation(
                grok: ChannelVerdict(status: .alive, evidence: "1 条在跑", running: 1),
                codex: ChannelVerdict(status: .alive, evidence: "闲", running: 0),
                liveCounts: groups.localActiveEngineCounts(localHost: localHost)
            ).render.primaryRow,
            ["Codex 通 闲", "Grok 通 4 条"]
        )
    }

    func testHeaderRecentCountFollowsVisibleWindowNotUncappedGroup() throws {
        let entries = (0..<12).map { index in
            ("done-\(index)", "codex", "完成 \(index)", now.timeIntervalSince1970)
        }
        let registry = try makeRegistry(entries)
        let lines = (0..<12).map { index in
            makeLine(slug: "done-\(index)", engine: .codex, state: .done, age: 60 + TimeInterval(index))
        }
        let groups = SentinelAggregation.lineGroups(lines: lines, registry: registry, now: now)
        let board = SentinelBoardWindow.snapshot(groups: groups)

        XCTAssertEqual(groups.recentlyCompleted.count, 12)
        XCTAssertEqual(board.recentShown.count, 8)
        let localHost = LocalHostIdentity(identifiers: ["Test Mac"])
        XCTAssertEqual(
            SentinelBoardCopy.headerSubtitle(
                localActiveCount: groups.localActivePresentations(localHost: localHost).count,
                recentCount: board.recentShown.count
            ),
            "这台机上在跑 0 条 · 8 条最近完成"
        )
    }

    func testLocalUnregisteredAndRemoteRegisteredCountDifferentThings() throws {
        let localHost = LocalHostIdentity(identifiers: ["Test Mac"])
        let registry = try makeRegistry(
            [
                ("remote-registered", "codex", "外机已登记", now.timeIntervalSince1970),
            ],
            host: "Other Mac"
        )
        let localUnregistered = makeLine(
            slug: "local-unregistered",
            engine: .cursorGrok,
            state: .running,
            age: 10
        )
        let remoteRegistered = makeLine(
            slug: "remote-registered",
            engine: .codex,
            state: .running,
            age: 10
        )
        let groups = SentinelAggregation.lineGroups(
            lines: [localUnregistered, remoteRegistered],
            registry: registry,
            now: now
        )
        let board = SentinelBoardWindow.snapshot(groups: groups)
        let localActive = groups.localActivePresentations(localHost: localHost).count
        let registeredActive = groups.activeRegistered.count
        let unregisteredActive = groups.activeUnregistered.count

        XCTAssertEqual(localActive, 0)
        XCTAssertEqual(registeredActive, 1)
        XCTAssertEqual(unregisteredActive, 1)
        XCTAssertNotEqual(localActive, registeredActive)
        XCTAssertEqual(groups.activeRegistered.map(\.line.slug), ["remote-registered"])
        XCTAssertEqual(groups.activeUnregistered.map(\.line.slug), ["local-unregistered"])
        XCTAssertEqual(
            groups.localActivePresentations(localHost: localHost).map(\.line.slug),
            []
        )
        XCTAssertEqual(
            SentinelBoardCopy.headerSubtitle(
                localActiveCount: localActive,
                recentCount: board.recentShown.count,
                offHostActiveCount: groups.activeHostOriginCounts(localHost: localHost).remote
                    + groups.activeHostOriginCounts(localHost: localHost).unknown
            ),
            "这台机上在跑 0 条 · 另外 2 条不在这台机上 · 0 条最近完成"
        )
        XCTAssertEqual(SentinelBoardCopy.registeredSectionTitle, "有登记的")
        XCTAssertEqual(SentinelBoardCopy.unregisteredSectionTitle, "没登记的")
    }

    func testHeaderMentionsOffHostActiveLinesAndKeepsPureLocalUnchanged() throws {
        let localHost = LocalHostIdentity(identifiers: ["Test Mac"])
        let mixedData = try JSONSerialization.data(
            withJSONObject: [
                [
                    "slug": "remote-line",
                    "engine": "codex",
                    "label_zh": "外机",
                    "dispatcher_zh": "来源对话",
                    "registered_at": now.timeIntervalSince1970,
                    "host": "Other Mac",
                ],
                [
                    "slug": "unknown-line",
                    "engine": "cursor-grok",
                    "label_zh": "未知",
                    "dispatcher_zh": "来源对话",
                    "registered_at": now.timeIntervalSince1970,
                ],
            ]
        )
        let mixedRegistry = try XCTUnwrap(CodexLineRegistryReader.decode(mixedData))
        let mixedGroups = SentinelAggregation.lineGroups(
            lines: [
                makeLine(slug: "remote-line", engine: .codex, state: .running, age: 10),
                makeLine(slug: "unknown-line", engine: .cursorGrok, state: .running, age: 10),
            ],
            registry: mixedRegistry,
            now: now
        )
        let mixedOrigins = mixedGroups.activeHostOriginCounts(localHost: localHost)
        XCTAssertEqual(mixedOrigins.local, 0)
        XCTAssertEqual(mixedOrigins.remote, 1)
        XCTAssertEqual(mixedOrigins.unknown, 1)
        XCTAssertEqual(
            SentinelBoardCopy.headerSubtitle(
                localActiveCount: mixedGroups.localActivePresentations(localHost: localHost).count,
                recentCount: SentinelBoardWindow.snapshot(groups: mixedGroups).recentShown.count,
                offHostActiveCount: mixedOrigins.remote + mixedOrigins.unknown
            ),
            "这台机上在跑 0 条 · 另外 2 条不在这台机上 · 0 条最近完成"
        )

        let localRegistry = try makeRegistry(
            [("local-line", "codex", "本机", now.timeIntervalSince1970)],
            host: "Test Mac"
        )
        let localGroups = SentinelAggregation.lineGroups(
            lines: [makeLine(slug: "local-line", engine: .codex, state: .running, age: 10)],
            registry: localRegistry,
            now: now
        )
        let localOrigins = localGroups.activeHostOriginCounts(localHost: localHost)
        XCTAssertEqual(localOrigins.local, 1)
        XCTAssertEqual(localOrigins.remote, 0)
        XCTAssertEqual(localOrigins.unknown, 0)
        let localHeader = SentinelBoardCopy.headerSubtitle(
            localActiveCount: localGroups.localActivePresentations(localHost: localHost).count,
            recentCount: 0,
            offHostActiveCount: localOrigins.remote + localOrigins.unknown
        )
        XCTAssertEqual(localHeader, "这台机上在跑 1 条 · 0 条最近完成")
        XCTAssertFalse(localHeader.contains("不在这台机上"))
    }

    func testRecencyDateFallsBackFromMtimeToUpdatedAtToRegisteredAt() throws {
        let updatedAt = now.addingTimeInterval(-100)
        let registeredAt = now.timeIntervalSince1970 - 200
        let registry = try makeRegistry([
            ("fallback-line", "codex", "回退", registeredAt),
        ])
        let registration = registry.registration(for: "fallback-line")

        let withMtime = makeLine(
            slug: "fallback-line",
            engine: .codex,
            state: .done,
            age: 10
        )
        XCTAssertEqual(
            SentinelBoardWindow.recencyDate(for: withMtime, registration: registration),
            withMtime.sourceModifiedAt
        )

        let noMtime = LineStatus(
            sourceFile: URL(fileURLWithPath: "/tmp/codex-babysitter-fallback-line.status.json"),
            slug: "fallback-line",
            engine: .codex,
            workdir: nil,
            branch: nil,
            state: .done,
            restarts: 0,
            reportsRestarts: true,
            rolloutAgeSeconds: nil,
            updatedAt: updatedAt,
            sourceModifiedAt: nil,
            relay: nil
        )
        XCTAssertEqual(
            SentinelBoardWindow.recencyDate(for: noMtime, registration: registration),
            updatedAt
        )

        let onlyRegistered = LineStatus(
            sourceFile: URL(fileURLWithPath: "/tmp/codex-babysitter-fallback-line.status.json"),
            slug: "fallback-line",
            engine: .codex,
            workdir: nil,
            branch: nil,
            state: .done,
            restarts: 0,
            reportsRestarts: true,
            rolloutAgeSeconds: nil,
            updatedAt: nil,
            sourceModifiedAt: nil,
            relay: nil
        )
        XCTAssertEqual(
            SentinelBoardWindow.recencyDate(for: onlyRegistered, registration: registration),
            Date(timeIntervalSince1970: registeredAt)
        )
        XCTAssertEqual(SentinelBoardWindow.historyDisplayCap, 500)
        XCTAssertEqual(StatusFileRetention.defaultCap, 500)
    }

    private func makeRegistry(
        _ entries: [(slug: String, engine: String, label: String, registeredAt: TimeInterval)],
        host: String? = nil
    ) throws -> CodexLineRegistry {
        let objects = entries.map { entry -> [String: Any] in
            var object: [String: Any] = [
                "slug": entry.slug,
                "engine": entry.engine,
                "label_zh": entry.label,
                "dispatcher_zh": "来源对话",
                "registered_at": entry.registeredAt,
            ]
            if let host {
                object["host"] = host
            }
            return object
        }
        let data = try JSONSerialization.data(withJSONObject: objects)
        return try XCTUnwrap(CodexLineRegistryReader.decode(data))
    }

    private func makeLine(
        slug: String,
        engine: LineEngine,
        state: LineState,
        age: TimeInterval
    ) -> LineStatus {
        LineStatus(
            sourceFile: URL(fileURLWithPath: "/tmp/\(engine.isCursorGrok ? "grok" : "codex-babysitter")-\(slug).status.json"),
            slug: slug,
            engine: engine,
            workdir: nil,
            branch: nil,
            state: state,
            restarts: 0,
            reportsRestarts: engine != .cursorGrok,
            rolloutAgeSeconds: nil,
            updatedAt: now,
            sourceModifiedAt: now.addingTimeInterval(-age),
            relay: nil
        )
    }
}
