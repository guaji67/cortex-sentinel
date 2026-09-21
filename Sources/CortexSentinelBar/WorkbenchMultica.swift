import Foundation

/// Read-only upstream. Uses Sentinel's existing bounded subprocess runner; no second web service.
/// A failed/incomplete page keeps the last entire snapshot, never an optimistic reduced total.
actor WorkbenchMultica {
    let url: URL
    let executable: String
    private var busy = false
    private var errorText = ""
    private var lastAttempt = Date.distantPast
    private let runner: any CortexSubprocessRunning
    init(url: URL, executable: String, runner: any CortexSubprocessRunning = CortexProcessSubprocessRunner()) {
        self.url = url; self.executable = executable; self.runner = runner
    }
    func status() -> BoardObject { ["syncing": busy, "error": errorText] }
    private func call(_ args: [String]) async throws -> Any {
        var environment = ProcessInfo.processInfo.environment
        environment["MULTICA_HTTP_TIMEOUT"] = "45"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        let out = await runner.run(executablePath: executable, arguments: args + ["--output", "json"],
                                   workingDirectory: nil, environment: environment, stdin: nil, timeout: 60)
        guard out.exitCode == 0 else { throw WorkbenchError(503, "Multica 没有返回有效快照；请检查本机登录与连接") }
        return try JSONSerialization.jsonObject(with: out.standardOutput)
    }
    func refresh(force: Bool = false) async {
        guard !busy, force || Date().timeIntervalSince(lastAttempt) > 1800 else { return }
        busy = true; lastAttempt = Date(); defer { busy = false }
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
            for state in active {
                var offset = 0
                for pageNumber in 0..<1000 {
                    guard let page = try await call(["issue", "list", "--status", state, "--limit", "25", "--offset", String(offset),
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
                    guard !rows.isEmpty, pageNumber < 999 else { throw WorkbenchError("分页未完成；未替换完整快照") }
                    offset += rows.count
                }
            }
            // Existing closed records are retained as history, never counted as active tickets.
            for row in old {
                guard let key = row["key"] as? String, seen[key] == nil else { continue }
                if active.contains(row["status"] as? String ?? "") {
                    let response = try await call(["issue", "get", key])
                    let object = response as? BoardObject ?? [:]
                    let resolved = (object["issues"] as? [BoardObject])?.first ?? object
                    guard resolved["status"] is String else { throw WorkbenchError("消失的票未查清；保留上次完整快照") }
                    seen[key] = normalize(resolved.merging(["identifier": key], uniquingKeysWith: { first, _ in first }),
                                          previous: row, labelCodes: labelCodes)
                } else { seen[key] = row }
            }
            cache["tickets"] = seen.values.sorted { ($0["key"] as? String ?? "") < ($1["key"] as? String ?? "") }
            cache["synced_at"] = WorkbenchJSON.timestamp()
            var trend = cache["trend"] as? [BoardObject] ?? []
            trend.append(["at": WorkbenchJSON.timestamp(), "active": seen.values.filter { active.contains($0["status"] as? String ?? "") }.count])
            cache["trend"] = Array(trend.suffix(96))
            try WorkbenchJSON.write(cache, to: url); errorText = ""
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
        } else if next["domain"] == nil { next["domain"] = "X"; next["domain_src"] = "none" }
        return next
    }
    func detail(_ key: String) async throws -> BoardObject {
        guard WorkbenchJSON.validID(key) else { throw WorkbenchError("票号不合法") }
        // Issue detail is on demand, without modifying comments, assignments, or issue state.
        let value = try await call(["issue", "get", key])
        return ["key": key, "issue": value]
    }
}
