import Foundation
import XCTest
@testable import CortexSentinelBar

final class LineRegistryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_784_824_800)

    func testRegistryReadsGrokEngineAndDefaultsLegacyEntriesToCodex() throws {
        let data = Data(
            """
            [
              {
                "engine": "cursor-grok",
                "slug": "grok-line",
                "label_zh": "Grok 派工",
                "dispatcher_zh": "来源对话一",
                "registered_at": 1784823993
              },
              {
                "slug": "legacy-codex-line",
                "label_zh": "Codex 派工",
                "dispatcher_zh": "来源对话二",
                "registered_at": 1784823993
              }
            ]
            """.utf8
        )

        let registry = try XCTUnwrap(CodexLineRegistryReader.decode(data))

        XCTAssertEqual(registry.registration(for: "grok-line")?.engine, .cursorGrok)
        XCTAssertEqual(registry.registration(for: "legacy-codex-line")?.engine, .codex)

        let line = LineStatus(
            sourceFile: URL(fileURLWithPath: "/tmp/grok-line.status.json"),
            slug: "grok-line",
            workdir: nil,
            branch: nil,
            state: .running,
            restarts: 0,
            rolloutAgeSeconds: nil,
            updatedAt: now,
            sourceModifiedAt: now,
            relay: nil
        )
        XCTAssertEqual(
            LinePresentation(
                line: line,
                registration: registry.registration(for: "grok-line")
            ).engine,
            .cursorGrok
        )

        let grokFileCodexRegistration = LineStatus(
            sourceFile: URL(fileURLWithPath: "/tmp/grok-legacy-registry.status.json"),
            slug: "legacy-codex-line",
            engine: .cursorGrok,
            workdir: nil,
            branch: nil,
            state: .done,
            restarts: 0,
            reportsRestarts: false,
            rolloutAgeSeconds: nil,
            updatedAt: now,
            sourceModifiedAt: now,
            relay: nil
        )
        XCTAssertEqual(
            LinePresentation(
                line: grokFileCodexRegistration,
                registration: registry.registration(for: "legacy-codex-line")
            ).engine,
            .cursorGrok
        )
    }

    /// COR-1504：本机线 / 外机线 / 无 host 的历史线。缺字段不许猜成本机，
    /// 通道行「N 条」只数本机；三条都还在列表里。
    func testHostFieldSplitsLocalRemoteAndUnknownWithoutGuessing() throws {
        let localHost = LocalHostIdentity(
            identifiers: ["Falcon 的 Mac mini", "Falcons-Mac-mini.local"]
        )
        let data = Data(
            """
            [
              {
                "engine": "cursor-grok",
                "slug": "local-line",
                "label_zh": "本机线",
                "dispatcher_zh": "来源对话",
                "registered_at": 1784823993,
                "host": "Falcon 的 Mac mini"
              },
              {
                "engine": "cursor-grok",
                "slug": "remote-line",
                "label_zh": "外机线",
                "dispatcher_zh": "来源对话",
                "registered_at": 1784823993,
                "host": "Falcon 的 MacBook Pro"
              },
              {
                "engine": "cursor-grok",
                "slug": "legacy-line",
                "label_zh": "历史线",
                "dispatcher_zh": "来源对话",
                "registered_at": 1784823993
              }
            ]
            """.utf8
        )

        let registry = try XCTUnwrap(CodexLineRegistryReader.decode(data))
        XCTAssertEqual(registry.registration(for: "local-line")?.host, "Falcon 的 Mac mini")
        XCTAssertEqual(registry.registration(for: "remote-line")?.host, "Falcon 的 MacBook Pro")
        XCTAssertNil(registry.registration(for: "legacy-line")?.host)

        let localLine = makeLine(slug: "local-line", state: .running, age: 30)
        let remoteLine = makeLine(slug: "remote-line", state: .running, age: 30)
        let legacyLine = makeLine(slug: "legacy-line", state: .running, age: 30)
        let localPresentation = LinePresentation(
            line: localLine,
            registration: registry.registration(for: "local-line")
        )
        let remotePresentation = LinePresentation(
            line: remoteLine,
            registration: registry.registration(for: "remote-line")
        )
        let legacyPresentation = LinePresentation(
            line: legacyLine,
            registration: registry.registration(for: "legacy-line")
        )

        XCTAssertEqual(localPresentation.hostOrigin(localHost: localHost), .local)
        XCTAssertEqual(localPresentation.hostOrigin(localHost: localHost).badgeText, "本机")
        XCTAssertEqual(
            remotePresentation.hostOrigin(localHost: localHost),
            .remote("Falcon 的 MacBook Pro")
        )
        XCTAssertEqual(
            remotePresentation.hostOrigin(localHost: localHost).badgeText,
            "Falcon 的 MacBook Pro"
        )
        XCTAssertEqual(legacyPresentation.hostOrigin(localHost: localHost), .unknown)
        XCTAssertEqual(legacyPresentation.hostOrigin(localHost: localHost).badgeText, "机器未知")

        let groups = SentinelAggregation.lineGroups(
            lines: [localLine, remoteLine, legacyLine],
            registry: registry,
            now: now
        )
        XCTAssertEqual(groups.activeRegistered.map(\.line.slug), ["legacy-line", "local-line", "remote-line"])
        XCTAssertEqual(groups.activeEngineCounts.grok, 3)
        XCTAssertEqual(groups.localActiveEngineCounts(localHost: localHost).grok, 1)
        XCTAssertEqual(groups.localActivePresentations(localHost: localHost).map(\.line.slug), ["local-line"])
        let origins = groups.activeHostOriginCounts(localHost: localHost)
        XCTAssertEqual(origins.local, 1)
        XCTAssertEqual(origins.remote, 1)
        XCTAssertEqual(origins.unknown, 1)
        XCTAssertEqual(
            ChannelSectionPresentation(
                grok: ChannelVerdict(status: .alive, evidence: "3 条在跑", running: 3),
                codex: ChannelVerdict(status: .alive, evidence: "闲", running: 0),
                liveCounts: groups.localActiveEngineCounts(localHost: localHost)
            ).render.primaryRow,
            ["Codex 通 闲", "Grok 通 1 条"]
        )
    }

    func testHostnameAlsoCountsAsLocalAndBlankHostStaysUnknown() throws {
        let localHost = LocalHostIdentity(
            identifiers: ["Falcon 的 Mac mini", "Falcons-Mac-mini.local"]
        )
        let data = Data(
            """
            [
              {
                "engine": "cursor-grok",
                "slug": "hostname-line",
                "label_zh": "hostname 本机",
                "dispatcher_zh": "来源对话",
                "registered_at": 1784823993,
                "host": "Falcons-Mac-mini.local"
              },
              {
                "engine": "cursor-grok",
                "slug": "blank-host-line",
                "label_zh": "空 host",
                "dispatcher_zh": "来源对话",
                "registered_at": 1784823993,
                "host": "   "
              }
            ]
            """.utf8
        )
        let registry = try XCTUnwrap(CodexLineRegistryReader.decode(data))
        XCTAssertEqual(registry.registration(for: "hostname-line")?.host, "Falcons-Mac-mini.local")
        XCTAssertNil(registry.registration(for: "blank-host-line")?.host)

        let hostnameLine = makeLine(slug: "hostname-line", state: .running, age: 10)
        let blankLine = makeLine(slug: "blank-host-line", state: .running, age: 10)
        XCTAssertEqual(
            LinePresentation(
                line: hostnameLine,
                registration: registry.registration(for: "hostname-line")
            ).hostOrigin(localHost: localHost),
            .local
        )
        XCTAssertEqual(
            LinePresentation(
                line: blankLine,
                registration: registry.registration(for: "blank-host-line")
            ).hostOrigin(localHost: localHost),
            .unknown
        )
    }

    func testRegistryDecodesEastEightOffsetUsedByGrokDispatch() throws {
        let data = Data(
            """
            [
              {
                "engine": "cursor-grok",
                "slug": "distdir",
                "label_zh": "构建产物落错位置的路径拼接修复(TICKET-1157)",
                "dispatcher_zh": "主控对话",
                "registered_at": "2026-08-17T20:06:56+08:00"
              }
            ]
            """.utf8
        )

        let registry = try XCTUnwrap(CodexLineRegistryReader.decode(data))
        let registration = try XCTUnwrap(registry.registration(for: "distdir"))

        XCTAssertEqual(registration.engine, .cursorGrok)
        XCTAssertEqual(registration.labelZH, "构建产物落错位置的路径拼接修复(TICKET-1157)")
        let expected = DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(identifier: "Asia/Shanghai"),
            year: 2026, month: 8, day: 17, hour: 20, minute: 6, second: 56
        ).date?.timeIntervalSince1970
        XCTAssertEqual(registration.registeredAt, try XCTUnwrap(expected))
    }

    func testRegistryDecodesUnixAndISO8601Timestamps() throws {
        let data = Data(
            """
            {
              "version": 1,
              "lines": [
                {
                  "slug": "unix-line",
                  "label_zh": "数字时间",
                  "dispatcher_zh": "来源对话一",
                  "registered_at": 1784823993
                },
                {
                  "slug": "iso-line",
                  "label_zh": "文本时间",
                  "dispatcher_zh": "来源对话二",
                  "registered_at": "2026-07-23T16:26:33Z"
                }
              ]
            }
            """.utf8
        )

        let registry = try XCTUnwrap(CodexLineRegistryReader.decode(data))

        XCTAssertEqual(registry.lines.count, 2)
        XCTAssertEqual(registry.lines[0].registeredAt, 1_784_823_993)
        XCTAssertEqual(registry.lines[1].registeredAt, 1_784_823_993)
    }

    /// 磁盘上的 `logs/codex-line-registry.json` 就是这个形态：顶层裸数组，没有 version/lines 信封。
    /// 之前只认信封，整张表解不出来 → 所有在跑的线都显示「未登记，信息可能不准」、
    /// 「Claude 派工」计数恒为 0。这条测试盯死真实文件形态，别再只测自己想象的 fixture。
    func testRegistryDecodesBareArrayAsWrittenOnDisk() throws {
        let data = Data(
            """
            [
              {
                "slug": "clean-clone-deployability",
                "label_zh": "干净克隆可部署性",
                "dispatcher_zh": "Claude 对话：新机器可用性（Air）",
                "registered_at": 1784823993
              },
              {
                "slug": "onboarding-conversational",
                "label_zh": "新手引导改对话式",
                "dispatcher_zh": "Claude 对话：新机器可用性（Air）",
                "registered_at": 1784823993
              }
            ]
            """.utf8
        )

        let registry = try XCTUnwrap(CodexLineRegistryReader.decode(data))

        XCTAssertEqual(registry.lines.count, 2)
        XCTAssertEqual(registry.registration(for: "clean-clone-deployability")?.labelZH, "干净克隆可部署性")
        XCTAssertEqual(registry.registration(for: "onboarding-conversational")?.labelZH, "新手引导改对话式")
    }

    func testRegistryDecodesEmptyBareArray() throws {
        let registry = try XCTUnwrap(CodexLineRegistryReader.decode(Data("[]".utf8)))
        XCTAssertTrue(registry.lines.isEmpty)
    }

    /// Python 的 `datetime.now().isoformat()` 默认不带时区，登记表里真实存在这种写法。
    /// 之前只认带时区的 ISO8601，这一条解不出就抛错，把整张表一起带崩。
    func testRegistryDecodesTimestampWithoutTimezone() throws {
        let data = Data(
            """
            [
              {
                "slug": "naive-time",
                "label_zh": "无时区时间",
                "dispatcher_zh": "来源对话",
                "registered_at": "2026-07-25T12:45:11"
              },
              {
                "slug": "naive-time-micros",
                "label_zh": "无时区带微秒",
                "dispatcher_zh": "来源对话",
                "registered_at": "2026-07-25T12:45:11.123456"
              }
            ]
            """.utf8
        )

        let registry = try XCTUnwrap(CodexLineRegistryReader.decode(data))

        XCTAssertEqual(registry.lines.count, 2)
        let expected = DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone.current,
            year: 2026, month: 7, day: 25, hour: 12, minute: 45, second: 11
        ).date?.timeIntervalSince1970
        XCTAssertEqual(registry.lines[0].registeredAt, try XCTUnwrap(expected))
    }

    /// 一条写坏了只能丢那一条，不能连坐。表里 30 条好的必须照常显示，
    /// 否则面板会毫无征兆地整体退回「未登记」。
    func testOneBrokenEntryDoesNotKillTheWholeRegistry() throws {
        let data = Data(
            """
            [
              {
                "slug": "good-one",
                "label_zh": "正常一号",
                "dispatcher_zh": "来源对话",
                "registered_at": 1784823993
              },
              {
                "slug": "broken-timestamp",
                "label_zh": "时间戳没见过",
                "dispatcher_zh": "来源对话",
                "registered_at": "昨天下午"
              },
              {
                "slug": "missing-field",
                "label_zh": "缺来源字段"
              },
              {
                "slug": "good-two",
                "label_zh": "正常二号",
                "dispatcher_zh": "来源对话",
                "registered_at": 1784823993
              }
            ]
            """.utf8
        )

        let registry = try XCTUnwrap(CodexLineRegistryReader.decode(data))

        XCTAssertEqual(registry.lines.count, 2)
        XCTAssertNotNil(registry.registration(for: "good-one"))
        XCTAssertNotNil(registry.registration(for: "good-two"))
        XCTAssertNil(registry.registration(for: "broken-timestamp"))
        XCTAssertNil(registry.registration(for: "missing-field"))
    }

    func testLineGroupsUseMtimeAndHideStaleNonterminalLines() throws {
        let registry = try XCTUnwrap(
            CodexLineRegistryReader.decode(
                Data(
                    """
                    {
                      "version": 1,
                      "lines": [
                        {
                          "slug": "registered-active",
                          "label_zh": "活跃派工",
                          "dispatcher_zh": "来源对话",
                          "registered_at": 1784823993
                        },
                        {
                          "slug": "registered-done",
                          "label_zh": "刚完成派工",
                          "dispatcher_zh": "来源对话",
                          "registered_at": 1784823993
                        }
                      ]
                    }
                    """.utf8
                )
            )
        )
        let lines = [
            makeLine(slug: "registered-active", state: .running, age: 599),
            makeLine(slug: "automatic-active", state: .help, age: 60),
            makeLine(slug: "registered-done", state: .done, age: 60),
            makeLine(slug: "stale-running", state: .running, age: 600),
            makeLine(slug: "stale-help", state: .help, age: 3_600),
            makeLine(slug: "old-done", state: .done, age: 86_400),
        ]

        let groups = SentinelAggregation.lineGroups(
            lines: lines,
            registry: registry,
            now: now
        )

        XCTAssertEqual(groups.activeRegistered.map(\.line.slug), ["registered-active"])
        XCTAssertEqual(groups.activeUnregistered.map(\.line.slug), ["automatic-active"])
        XCTAssertEqual(groups.recentlyCompleted.map(\.line.slug), ["registered-done"])
        XCTAssertEqual(
            Set(groups.history.map(\.line.slug)),
            Set(["stale-running", "stale-help", "old-done"])
        )
    }

    func testRegisteredGroupsUseRegistrationTimeInsteadOfStatusMtime() throws {
        let registry = try XCTUnwrap(
            CodexLineRegistryReader.decode(
                Data(
                    """
                    {
                      "version": 1,
                      "lines": [
                        {
                          "slug": "first",
                          "label_zh": "先建立",
                          "dispatcher_zh": "来源一",
                          "registered_at": 1784824600
                        },
                        {
                          "slug": "second",
                          "label_zh": "后建立",
                          "dispatcher_zh": "来源二",
                          "registered_at": 1784824700
                        }
                      ]
                    }
                    """.utf8
                )
            )
        )
        let first = makeLine(slug: "first", state: .running, age: 5)
        let second = makeLine(slug: "second", state: .running, age: 60)

        let groups = SentinelAggregation.lineGroups(
            lines: [second, first],
            registry: registry,
            now: now
        )

        XCTAssertEqual(groups.activeRegistered.map(\.line.slug), ["first", "second"])
    }

    private func makeLine(slug: String, state: LineState, age: TimeInterval) -> LineStatus {
        LineStatus(
            sourceFile: URL(fileURLWithPath: "/tmp/\(slug).status.json"),
            slug: slug,
            workdir: nil,
            branch: nil,
            state: state,
            restarts: 0,
            rolloutAgeSeconds: nil,
            updatedAt: now,
            sourceModifiedAt: now.addingTimeInterval(-age),
            relay: nil
        )
    }
}
