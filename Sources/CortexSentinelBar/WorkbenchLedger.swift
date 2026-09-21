import Foundation
import CryptoKit
import CoreFoundation

typealias BoardObject = [String: Any]

struct WorkbenchError: Error, LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
    init(_ status: Int, _ message: String) { self.status = status; self.message = message }
    init(_ message: String) { self.status = 400; self.message = message }
}

enum WorkbenchJSON {
    static func data(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }
    static func object(_ data: Data) throws -> BoardObject {
        guard let object = try JSONSerialization.jsonObject(with: data) as? BoardObject else {
            throw WorkbenchError("需要 JSON 对象")
        }
        return object
    }
    static func read(_ url: URL) throws -> BoardObject { try object(Data(contentsOf: url)) }
    static func write(_ value: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try data(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
    static func date(_ value: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions.insert(.withFractionalSeconds)
        return f.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func validID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9_.:-]{0,119}$", options: .regularExpression) != nil
    }
}

/// All writers pass this one transaction boundary. Unknown research fields survive unchanged.
/// The on-disk document is replaced atomically; a failed write never advances memory or revisions.
final class WorkbenchLedger: @unchecked Sendable {
    let url: URL
    private let lock = NSRecursiveLock()
    private var document: BoardObject

    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            document = try WorkbenchJSON.read(url)
            guard document["schema"] as? Int == 1,
                  document["entities"] is [String: BoardObject], document["events"] is [String: BoardObject] else {
                throw WorkbenchError(503, "工作台数据版本不兼容或损坏；未覆盖原文件")
            }
        } else {
            document = ["schema": 1, "entities": [String: BoardObject](), "events": [String: BoardObject](),
                        "sources": [String: BoardObject](), "drafts": ["domains": BoardObject(), "tickets": BoardObject()],
                        "draft_revision": 0]
        }
    }

    func snapshot() -> BoardObject {
        lock.lock(); defer { lock.unlock() }
        return document
    }

    func entity(_ id: String) -> BoardObject? {
        lock.lock(); defer { lock.unlock() }
        return (document["entities"] as? [String: BoardObject])?[id]
    }

    private func commit(_ next: BoardObject) throws {
        try WorkbenchJSON.write(next, to: url)
        document = next
    }

    func update(_ event: BoardObject, actor: String, scopes: [String]) throws -> BoardObject {
        lock.lock(); defer { lock.unlock() }
        guard let id = event["id"] as? String, WorkbenchJSON.validID(id),
              let eventID = event["event_id"] as? String, WorkbenchJSON.validID(eventID),
              let kind = event["kind"] as? String, ["track", "area", "note", "problem", "relation"].contains(kind),
              let patch = event["patch"] as? BoardObject, let base = event["base_revision"] as? Int,
              CFGetTypeID(event["base_revision"] as CFTypeRef) != CFBooleanGetTypeID(),
              try WorkbenchJSON.data(patch).count <= 200_000 else {
            throw WorkbenchError("需要有效的 id、event_id、kind、base_revision、patch")
        }
        let protected: Set<String> = ["id", "kind", "revision", "updated_at", "updated_by"]
        guard protected.isDisjoint(with: patch.keys) else { throw WorkbenchError("不能覆盖身份或修订字段") }
        var entities = document["entities"] as? [String: BoardObject] ?? [:]
        var events = document["events"] as? [String: BoardObject] ?? [:]
        let digest = SHA256.hash(data: try WorkbenchJSON.data(event)).map { String(format: "%02x", $0) }.joined()
        if let replay = events[eventID] {
            guard replay["actor"] as? String == actor, replay["digest"] as? String == digest else {
                throw WorkbenchError(409, "event_id 已用于不同请求")
            }
            return ["ok": true, "replayed": true, "id": id, "revision": replay["revision"] ?? 0]
        }
        let previous = entities[id]
        var next = previous ?? [:]
        let track = previous?["track"] as? String ?? patch["track"] as? String ?? ""
        guard WorkbenchJSON.validID(track), scopes.contains("*") || scopes.contains(track),
              patch["track"] == nil || patch["track"] as? String == track else {
            throw WorkbenchError(403, "没有这个板块的维护权限")
        }
        guard previous == nil || previous?["kind"] as? String == kind else { throw WorkbenchError("不能改变记录类型") }
        guard base == (previous?["revision"] as? Int ?? 0) else { throw WorkbenchError(409, "内容已更新，请重读后合并") }
        if kind == "track" {
            guard id == track else { throw WorkbenchError("板块 id 应与 track 一致") }
        } else {
            guard entities[track]?["kind"] as? String == "track" else { throw WorkbenchError("先登记板块入口，正文可以以后补") }
        }
        next.merge(patch) { _, new in new }
        for field in ["owner", "machine", "parent", "group", "status_label", "color", "blocker", "next_action", "state", "classification", "from", "to", "certainty"] {
            if let value = next[field], !(value is String) { throw WorkbenchError("\(field) 应为文本；自由扩展字段不受此约束") }
        }
        for field in ["references", "ticket_ids", "domains"] {
            if let value = next[field], !(value is [String]) { throw WorkbenchError("\(field) 应为文本列表") }
        }
        if let notes = next["notes"], !(notes is [Any]) { throw WorkbenchError("notes 应为列表，长正文可用 body") }
        guard let title = next["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 500 else { throw WorkbenchError("需要简短标题，正文不限提纲") }
        if let parent = next["parent"] as? String, !parent.isEmpty {
            guard entities[parent]?["track"] as? String == track, parent != id else { throw WorkbenchError("父块应属于本板块") }
            var cursor = parent; var seen: Set<String> = [id]
            while !cursor.isEmpty {
                guard seen.insert(cursor).inserted else { throw WorkbenchError("父子结构不能成环") }
                cursor = entities[cursor]?["parent"] as? String ?? ""
            }
        }
        if kind == "relation" {
            guard let from = next["from"] as? String, entities[from]?["track"] as? String == track,
                  let to = next["to"] as? String, !to.isEmpty else { throw WorkbenchError("关系需要本板块起点和目标") }
            if next["certainty"] as? String == "confirmed", (next["references"] as? [String] ?? []).isEmpty {
                throw WorkbenchError("确认关系需要依据")
            }
        }
        if kind == "problem" {
            if let block = next["block_id"] as? String, !block.isEmpty {
                guard entities[block]?["track"] as? String == track else { throw WorkbenchError("问题所属块不在本板块") }
            }
            let state = next["state"] as? String ?? "recorded"
            guard ["recorded", "repairing", "merged", "delivered", "verified", "dismissed", "source_closed"].contains(state) else {
                throw WorkbenchError("不认识的交付阶段")
            }
            let evidence = next["evidence"] as? [String: String] ?? [:]
            if state == "verified" {
                guard ["confirmed_bug", "improvement"].contains(next["classification"] as? String ?? ""),
                      ["machine", "version", "action", "expected", "actual", "checked_at", "reference"].allSatisfy({ !(evidence[$0] ?? "").isEmpty }),
                      WorkbenchJSON.date(evidence["checked_at"] ?? "") != nil else {
                    throw WorkbenchError("用户验证需要机器、版本、操作、预期、实际、时间和出处；来源提及不算确认缺陷")
                }
                if previous?["state"] as? String != "verified" {
                    guard patch["evidence"] != nil, (previous?["evidence"] as? [String: String]) != evidence else {
                        throw WorkbenchError("重新验收需要这一次的证据")
                    }
                }
            }
            if state == "dismissed", (evidence["reference"] ?? "").isEmpty { throw WorkbenchError("排除或归并需要依据") }
            next["state"] = state
        }
        next.merge(["id": id, "kind": kind, "track": track, "revision": base + 1,
                    "updated_by": actor, "updated_at": WorkbenchJSON.timestamp()]) { _, new in new }
        entities[id] = next
        events[eventID] = ["entity_id": id, "actor": actor, "digest": digest, "revision": base + 1,
                           "at": WorkbenchJSON.timestamp(), "body": next]
        var doc = document; doc["entities"] = entities; doc["events"] = events
        try commit(doc)
        return ["ok": true, "id": id, "revision": base + 1]
    }

    func publish(_ source: BoardObject, scopes: [String]) throws -> BoardObject {
        lock.lock(); defer { lock.unlock() }
        guard let track = source["track"] as? String, scopes.contains("*") || scopes.contains(track),
              entity(track)?["kind"] as? String == "track", let blocks = source["blocks"] as? [BoardObject],
              blocks.count <= 1000, let observed = source["observed_at"] as? String,
              let observedDate = WorkbenchJSON.date(observed) else { throw WorkbenchError(403, "来源缺少有效板块、时间或维护权限") }
        var ids = Set<String>()
        for block in blocks {
            guard let id = block["id"] as? String, WorkbenchJSON.validID(id), ids.insert(id).inserted,
                  block["track"] as? String == track, block["title"] is String else { throw WorkbenchError("来源块身份重复或越界") }
            if let existing = entity(id) {
                guard existing["track"] as? String == track, existing["kind"] as? String == "area" else {
                    throw WorkbenchError(403, "来源块身份已被其他板块或记录占用")
                }
            }
        }
        var sources = document["sources"] as? [String: BoardObject] ?? [:]
        if let old = sources[track], let date = WorkbenchJSON.date(old["observed_at"] as? String ?? ""), date > observedDate {
            throw WorkbenchError(409, "来源比已保存版本旧；未覆盖")
        }
        var fresh = source; fresh["received_at"] = WorkbenchJSON.timestamp(); sources[track] = fresh
        var entities = document["entities"] as? [String: BoardObject] ?? [:]
        for block in blocks {
            let id = block["id"] as! String
            if entities[id] == nil {
                entities[id] = ["id": id, "kind": "area", "track": track, "title": block["title"] ?? id,
                                "revision": 1, "origin": "imported"]
            }
        }
        var doc = document; doc["sources"] = sources; doc["entities"] = entities; try commit(doc)
        return ["ok": true, "track": track, "blocks": blocks.count]
    }

    func saveDrafts(_ payload: BoardObject) throws -> BoardObject {
        lock.lock(); defer { lock.unlock() }
        guard let base = payload["base_revision"] as? Int, base == (document["draft_revision"] as? Int ?? 0),
              let drafts = payload["drafts"] as? BoardObject else { throw WorkbenchError(409, "管理草稿已变化，请刷新") }
        var next = document; next["drafts"] = drafts; next["draft_revision"] = base + 1; try commit(next)
        return ["ok": true, "revision": base + 1]
    }
}
