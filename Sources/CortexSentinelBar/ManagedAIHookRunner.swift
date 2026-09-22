import Foundation

enum ManagedAIHookRunner {
    static func run(directory: URL, id: String, digest: String, test: Bool) async -> Int32 {
        do {
            // A test receipt is never promoted to evidence of a Claude Code session invoking this hook.
            let testHome = directory.deletingLastPathComponent().appendingPathComponent("ai-test-home")
            let home = FileManager.default.fileExists(atPath: testHome.path) ? testHome : FileManager.default.homeDirectoryForCurrentUser
            let manager = try ManagedAIPackages(directory: directory, home: home)
            let (hook, root) = try manager.hookDefinition(id: id, digest: digest)
            let input = FileHandle.standardInput.readDataToEndOfFile()
            guard input.count <= 2_000_000 else { throw WorkbenchError("Hook 输入过大") }
            let event = (try? WorkbenchJSON.object(input))?["hook_event_name"] as? String
            guard event == hook["event"] as? String else { throw WorkbenchError("Hook 事件与已确认清单不符") }
            let run = await CortexProcessSubprocessRunner().run(executablePath: hook["interpreter"] as! String,
                arguments: [root.appendingPathComponent(hook["entry"] as! String).path], workingDirectory: root,
                environment: nil, stdin: input, timeout: 12)
            // Never persist stdin, transcript, cwd, model output or session identifiers.
            try WorkbenchJSON.write(["id": id, "digest": digest, "event": event ?? "", "at": WorkbenchJSON.timestamp(),
                                     "exit_code": run.exitCode, "test": test], to: directory.appendingPathComponent("invocations/\(id).json"))
            FileHandle.standardOutput.write(run.standardOutput)
            FileHandle.standardError.write(run.standardError)
            return run.exitCode
        } catch {
            FileHandle.standardError.write(Data(("哨兵 Hook：" + error.localizedDescription + "\n").utf8)); return 1
        }
    }
}
