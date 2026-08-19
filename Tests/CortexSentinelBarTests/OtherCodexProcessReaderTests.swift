import XCTest
@testable import CortexSentinelBar

final class OtherCodexProcessReaderTests: XCTestCase {
    func testPSParserKeepsOnlyUnmanagedCodexExecProcesses() {
        let output = """
          101  00:05 /usr/local/bin/codex exec --json
          102  01:02 /usr/bin/python3 scripts/codex_babysitter.py
          103  02:03 /opt/homebrew/bin/codex exec resume abc
          104  00:01 zsh -c codex exec
        """
        let directories = [
            101: "/Users/example/worktrees/managed",
            103: "/Users/example/worktrees/free-line",
            104: "/Users/example/worktrees/shell-wrapper",
        ]

        let processes = OtherCodexProcessReader.parsePSOutput(
            output,
            excluding: [101],
            workingDirectory: { directories[$0] }
        )

        XCTAssertEqual(
            processes,
            [
                OtherCodexProcess(
                    processID: 103,
                    worktreeName: "free-line",
                    elapsed: "02:03"
                ),
            ]
        )
    }

    func testPSParserUsesHonestUnknownDirectoryFallback() {
        let output = "201 1-02:03:04 /usr/local/bin/codex exec --full-auto"

        XCTAssertEqual(
            OtherCodexProcessReader.parsePSOutput(
                output,
                excluding: [],
                workingDirectory: { _ in nil }
            ),
            [
                OtherCodexProcess(
                    processID: 201,
                    worktreeName: "目录未知",
                    elapsed: "1-02:03:04"
                ),
            ]
        )
    }
}
