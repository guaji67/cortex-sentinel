import Foundation

/// Read-only upstream. Uses Sentinel's existing bounded subprocess runner; no second web service.
/// A failed/incomplete page keeps the last entire snapshot, never an optimistic reduced total.
actor WorkbenchMultica {
    let url: URL
    let executable: String
    private var busy = false
    private var errorText = ""
    private var lastAttempt = Date.distantPast
    private var deadline = Date.distantFuture
    private var callsRemaining = 64
    private let runner: any CortexSubprocessRunning
    init(url: URL, executable: String, runner: any CortexSubprocessRunning = CortexProcessSubprocessRunner()) {
        self.url = url; self.executable = executable; self.runner = runner
    }
    func status() -> BoardObject { ["syncing": busy, "error": errorText] }
    private func call(_ args: [String]) async throws -> Any {
        guard callsRemaining > 0, deadline.timeIntervalSinceNow > 0 else { throw WorkbenchError(503, "本轮查询达到上限，保留上一份完整快照") }
        callsRemaining -= 1
        var environment = executionEnvironment()
        environment["MULTICA_HTTP_TIMEOUT"] = "45"
        let out = await runner.run(executablePath: executable, arguments: args + ["--output", "json"],
                                   workingDirectory: nil, environment: environment, stdin: nil, timeout: min(45, deadline.timeIntervalSinceNow))
        guard out.exitCode == 0 else { throw WorkbenchError(503, "Multica 没有返回有效快照；请检查本机登录与连接") }
        return try JSONSerialization.jsonObject(with: out.standardOutput)
    }
    func refresh(force: Bool = false) async {
        guard !busy, force || Date().timeIntervalSince(lastAttempt) > 300 else { return }
        busy = true; lastAttempt = Date(); deadline = Date().addingTimeInterval(180); callsRemaining = 64; defer { busy = false }
        do {
            guard FileManager.default.isExecutableFile(atPath: executable) else { throw WorkbenchError(503, "本机未配置 Multica CLI；已保存的资料仍可查看") }
            var cache = (try? WorkbenchJSON.read(url)) ?? [:]
            let old = cache["tickets"] as? [BoardObject] ?? []
            let domains = cache["domains"] as? [BoardObject] ?? []
            let oldByKey = Dictionary(old.compactMap { row -> (String, BoardObject)? in
                guard let key = row["key"] as? String else { return nil }; return (key, row)
            }, uniquingKeysWith: { _, last in last })
            let labelCodes = Dictionary(domains.compactMap { d -> (String, String)? in
                guard let label = d["label"] as? String, let id = d["id"] as? String else { return nil }; return (label, id)
            }, uniquingKeysWith: { _, last in last })
            let active = ["backlog", "todo", "in_progress", "in_review", "blocked"]
            var seen: [String: BoardObject] = [:]
            var pagesRemaining = 40
            for state in active {
                var offset = 0
                for _ in 0..<40 {
                    guard pagesRemaining > 0 else { throw WorkbenchError(503, "活票分页超过本轮上限，保留上一份完整快照") }
                    pagesRemaining -= 1
                    guard let page = try await call(["issue", "list", "--status", state, "--limit", "100", "--offset", String(offset),
                        "--sort", "created_at", "--direction", "asc", "--fields",
                        "id,identifier,title,status,priority,assignee_id,updated_at,labels"]) as? BoardObject,
                          let rows = page["issues"] as? [BoardObject], let more = page["has_more"] as? Bool else {
                        throw WorkbenchError(503, "Multica 分页形状变化；未替换完整快照")
                    }
                    for row in rows {
                        guard let key = row["identifier"] as? String else { throw WorkbenchError("上游票缺少身份") }
                        seen[key] = normalize(row, previous: oldByKey[key], labelCodes: labelCodes)
                    }
                    if !more { break }
                    guard !rows.isEmpty else { throw WorkbenchError("分页未完成；未替换完整快照") }
                    offset += rows.count
                }
            }
            // 活票已完整取得；消失的旧票不继续算活票，也不臆断已合入。
            // 每轮只复核有限旧票，余项保留最后已知状态与待复核标记。
            var unresolved = 0
            for row in old {
                guard let key = row["key"] as? String, seen[key] == nil else { continue }
                if active.contains(row["status"] as? String ?? "") || row["status"] as? String == "unresolved" {
                    if unresolved < 12, deadline.timeIntervalSinceNow > 30, callsRemaining > 4,
                       let response = try? await call(["issue", "get", key]) as? BoardObject,
                       response["status"] is String {
                        seen[key] = normalize(response.merging(["identifier": key], uniquingKeysWith: { first, _ in first }), previous: row, labelCodes: labelCodes)
                    } else {
                        var pending = row
                        pending["last_known_status"] = row["last_known_status"] ?? row["status"]
                        pending["status"] = "unresolved"; seen[key] = pending
                    }
                    unresolved += 1
                } else { seen[key] = row }
            }
            cache["tickets"] = seen.values.sorted { ($0["key"] as? String ?? "") < ($1["key"] as? String ?? "") }
            cache["synced_at"] = WorkbenchJSON.timestamp()
            var trend = cache["trend"] as? [BoardObject] ?? []
            trend.append(["at": WorkbenchJSON.timestamp(), "active": seen.values.filter { active.contains($0["status"] as? String ?? "") }.count])
            cache["trend"] = Array(trend.suffix(96))
            try WorkbenchJSON.write(cache, to: url); errorText = ""
            // 主线合入是独立事实，GitHub 不通不抹掉已经取得的票单。
            do {
                cache["merges"] = try await recentMerges()
            } catch {
                var merges = cache["merges"] as? BoardObject ?? [:]
                merges["error"] = "近期主线合入记录读取失败，保留上次记录。"
                cache["merges"] = merges
            }
            try WorkbenchJSON.write(cache, to: url)
        } catch { errorText = error.localizedDescription }
    }
    private func normalize(_ row: BoardObject, previous: BoardObject?, labelCodes: [String: String]) -> BoardObject {
        let labels = (row["labels"] as? [Any] ?? []).compactMap { ($0 as? BoardObject)?["name"] as? String ?? $0 as? String }
        var next = previous ?? [:]
        next.merge(["key": row["identifier"] ?? "", "title": row["title"] ?? "", "status": row["status"] ?? "unknown",
                    "priority": row["priority"] ?? "none", "assignee_id": row["assignee_id"] ?? "",
                    "updated": row["updated_at"] ?? "", "labels": labels]) { _, new in new }
        if let domain = labels.compactMap({ labelCodes[$0] }).first {
            next["domain"] = domain; next["domain_src"] = "label"
        } else { next["domain"] = "X"; next["domain_src"] = "none" }
        return next
    }
    private func executionEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // launchd 不继承交互 shell；复用本机用户 CLI 目录，不绑定开发机路径。
        let localBin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        environment["PATH"] = localBin + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        return environment
    }
    private func recentMerges() async throws -> BoardObject {
        guard deadline.timeIntervalSinceNow > 0 else { throw WorkbenchError(503, "查询预算已用完") }
        let environment = executionEnvironment()
        let cutoff = WorkbenchJSON.timestamp().prefix(10)
        // 只读最近一批主线 PR，不扫描仓库提交史，不获取 PR 正文。
        let out = await runner.run(executablePath: "/usr/bin/env", arguments: ["gh", "pr", "list", "--repo", "guaji67/cortex", "--state", "merged", "--base", "main", "--limit", "100", "--json", "number,title,mergedAt,mergeCommit,url,baseRefName"], workingDirectory: nil, environment: environment, stdin: nil, timeout: min(30,deadline.timeIntervalSinceNow))
        guard out.exitCode == 0, let rows = try JSONSerialization.jsonObject(with: out.standardOutput) as? [BoardObject] else { throw WorkbenchError(503,"合入记录读取失败") }
        let pattern = try NSRegularExpression(pattern: "COR-[0-9]+", options: .caseInsensitive)
        let lower = Date().addingTimeInterval(-7 * 86400)
        let records: [BoardObject] = rows.compactMap { row in
            guard row["baseRefName"] as? String == "main", let at = row["mergedAt"] as? String,
                  let date = WorkbenchJSON.date(at), date >= lower,
                  let commit = (row["mergeCommit"] as? BoardObject)?["oid"] as? String, !commit.isEmpty,
                  let title = row["title"] as? String else { return nil }
            let text = title as NSString
            let keys = pattern.matches(in: title, range: NSRange(location: 0, length: text.length)).map { text.substring(with: $0.range).uppercased() }
            return ["title":title,"number":row["number"] ?? 0,"url":row["url"] ?? "", "merged_at":at,"merge_sha":commit,"ticket_keys":keys]
        }.sorted { ($0["merged_at"] as? String ?? "") > ($1["merged_at"] as? String ?? "") }
        return ["records":records,"observed_at":WorkbenchJSON.timestamp(),"window_days":7,"limit":100,"error":"", "queried_at_day":String(cutoff)]
    }
    func detail(_ key: String) async throws -> BoardObject {
        guard WorkbenchJSON.validID(key) else { throw WorkbenchError("票号不合法") }
        // Issue detail is on demand, without modifying comments, assignments, or issue state.
        let value = try await call(["issue", "get", key])
        return ["key": key, "issue": value]
    }
}
