import Foundation

enum OtherCodexProcessReader {
    static func read(excluding managedProcessIDs: Set<Int>) -> [OtherCodexProcess] {
        guard let output = run(executable: "/bin/ps", arguments: ["-axo", "pid=,etime=,command="]) else {
            return []
        }
        return parsePSOutput(
            output,
            excluding: managedProcessIDs,
            workingDirectory: workingDirectory(for:)
        )
    }

    static func parsePSOutput(
        _ output: String,
        excluding managedProcessIDs: Set<Int>,
        workingDirectory: (Int) -> String?
    ) -> [OtherCodexProcess] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine -> OtherCodexProcess? in
                let fields = rawLine.split(
                    maxSplits: 2,
                    omittingEmptySubsequences: true,
                    whereSeparator: \.isWhitespace
                )
                guard fields.count == 3,
                      let processID = Int(fields[0]),
                      !managedProcessIDs.contains(processID),
                      isCodexExecCommand(String(fields[2]))
                else {
                    return nil
                }

                let directory = workingDirectory(processID)
                let worktreeName = directory.map {
                    URL(fileURLWithPath: $0).lastPathComponent
                } ?? "目录未知"
                return OtherCodexProcess(
                    processID: processID,
                    worktreeName: worktreeName,
                    elapsed: String(fields[1])
                )
            }
            .sorted { lhs, rhs in
                lhs.processID < rhs.processID
            }
    }

    private static func isCodexExecCommand(_ command: String) -> Bool {
        let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= 2 else {
            return false
        }
        let shellWrappers: Set<String> = ["bash", "dash", "fish", "sh", "zsh"]
        if shellWrappers.contains(URL(fileURLWithPath: tokens[0]).lastPathComponent) {
            return false
        }
        for index in 0..<(tokens.count - 1) {
            let executable = URL(fileURLWithPath: tokens[index]).lastPathComponent
            if executable == "codex", tokens[index + 1] == "exec" {
                return true
            }
        }
        return false
    }

    private static func workingDirectory(for processID: Int) -> String? {
        guard let output = run(
            executable: "/usr/sbin/lsof",
            arguments: ["-a", "-p", String(processID), "-d", "cwd", "-Fn"]
        ) else {
            return nil
        }
        return output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.hasPrefix("n/") })
            .map { String($0.dropFirst()) }
    }

    private static func run(executable: String, arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return nil
            }
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }
}
