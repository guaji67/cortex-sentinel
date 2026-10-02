import Foundation

// 独立编译真实同步器，假执行器只返回合成上游，不接真实看板。
protocol CortexSubprocessRunning: Sendable {
    func run(executablePath: String, arguments: [String], workingDirectory: URL?, environment: [String:String]?, stdin: Data?, timeout: TimeInterval) async -> CortexSubprocessResult
}
struct CortexSubprocessResult: Sendable {
    let exitCode: Int32
    let standardOutput: Data
    let standardError: Data
    let timedOut: Bool
}
struct CortexProcessSubprocessRunner: CortexSubprocessRunning {
    func run(executablePath: String, arguments: [String], workingDirectory: URL?, environment: [String:String]?, stdin: Data?, timeout: TimeInterval) async -> CortexSubprocessResult { fatalError("不得调用真实上游") }
}
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value = value.addingTimeInterval(seconds) }
}
actor FakeRunner: CortexSubprocessRunning {
    let mode: String
    var calls = 0
    init(_ mode: String) { self.mode = mode }
    func run(executablePath: String, arguments: [String], workingDirectory: URL?, environment: [String:String]?, stdin: Data?, timeout: TimeInterval) async -> CortexSubprocessResult {
        calls += 1
        precondition(timeout > 0 && timeout <= 45)
        let value: Any
        if arguments.first == "gh" {
            precondition(arguments.prefix(3).elementsEqual(["gh","pr","list"]))
            precondition(environment?["PATH"]?.contains("/.local/bin:") == true)
            if mode == "github-failed" { return .init(exitCode: 1,standardOutput: Data(),standardError: Data(),timedOut: false) }
            value = [["number":1,"title":"fix: COR-1 修复","baseRefName":"main","mergedAt":WorkbenchJSON.timestamp(),"mergeCommit":["oid":"synthetic-main-merge"],"url":"https://github.com/example/repo/pull/1"]]
        } else {
            precondition(arguments.first == "issue" && ["list","get"].contains(arguments[1]))
            if arguments[1] == "get" { value = ["identifier":"COR-OLD","status":"done","labels":[]] }
            else if mode == "unbounded" { value = ["issues":[["identifier":"COR-\(calls)","status":"todo","labels":[]]],"has_more":true] }
            else if mode == "invalid" { value = ["issues":[],"has_more":true] }
            else {
                let state = arguments[arguments.firstIndex(of:"--status")!+1]
                value = ["issues": state == "todo" ? [["identifier":"COR-1","title":"合成工作","status":"todo","labels":[]]] : [],"has_more":false]
            }
        }
        return .init(exitCode:0,standardOutput:try! JSONSerialization.data(withJSONObject:value),standardError:Data(),timedOut:false)
    }
}
@main struct Verify {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("panorama-multica-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        var checked = 0
        for mode in ["good","unbounded","invalid","github-failed"] {
            let url=root.appendingPathComponent(mode+".json")
            let initial: BoardObject = ["domains":[["id":"P1","label":"域:对话"]],"tickets":[["key":"COR-1","status":"todo","domain":"P1","domain_src":"label","labels":["域:对话"]]],"merges":["records":[["title":"旧记录"]]]]
            try WorkbenchJSON.write(initial,to:url)
            let before=try Data(contentsOf:url), runner=FakeRunner(mode)
            let sync=WorkbenchMultica(url:url,executable:"/usr/bin/true",runner:runner)
            await sync.refresh(force:true)
            let calls=await runner.calls
            if mode == "unbounded" || mode == "invalid" {
                let after = try Data(contentsOf:url)
                precondition(after==before)
                precondition(calls<=40)
                let status = await sync.status()
                precondition(status["error"] as? String != "")
            } else {
                let cache=try WorkbenchJSON.read(url)
                let row=(cache["tickets"] as! [BoardObject]).first!
                precondition(row["domain_src"] as? String == "none")
                precondition(row["domain"] as? String == "X")
                let merges=cache["merges"] as! BoardObject
                precondition(mode == "github-failed" ? (merges["error"] as? String != nil) : (merges["records"] as! [BoardObject]).first?["merge_sha"] as? String == "synthetic-main-merge")
            }
            checked += 1
        }
        let clock = TestClock(), runner = FakeRunner("good")
        let sync = WorkbenchMultica(url: root.appendingPathComponent("expired-detail.json"), executable: "/usr/bin/true", runner: runner, clock: { clock.now() })
        await sync.refresh(force: true)
        let beforeDetail = await runner.calls
        clock.advance(200)
        let detail = try await sync.detail("COR-OLD")
        precondition((detail["issue"] as? BoardObject)?["status"] as? String == "done")
        let afterDetail = await runner.calls
        precondition(afterDetail == beforeDetail + 1)
        // 按需读取不能把来源同步的节流窗口重置或提前放开。
        await sync.refresh()
        let afterThrottled = await runner.calls
        precondition(afterThrottled == afterDetail)
        clock.advance(200)
        await sync.refresh()
        let afterRefresh = await runner.calls
        precondition(afterRefresh > afterDetail)
        checked += 1
        print("bounded_sync_cases_passed=\(checked)")
    }
}
