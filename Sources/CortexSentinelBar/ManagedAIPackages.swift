import Foundation
import CryptoKit
import Darwin

/// Local trust, immutable releases and ownership receipts. No installer or package code is run here.
final class ManagedAIPackages: @unchecked Sendable {
    static let hosts = ["claude": ".claude/skills", "codex": ".codex/skills", "agents": ".agents/skills",
                        "cursor": ".cursor/skills", "opencode": ".config/opencode/skills", "zcode": ".zcode/skills"]
    let directory: URL
    let home: URL
    let executable: URL
    private let lock = NSRecursiveLock()
    private var state: BoardObject
    private var syncing = false
    private let key: Curve25519.Signing.PrivateKey
    private let fm = FileManager.default

    init(directory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
         executable: URL = Bundle.main.executableURL!) throws {
        self.directory = directory; self.home = home; self.executable = executable
        let file = directory.appendingPathComponent("state.json")
        state = fm.fileExists(atPath: file.path) ? try WorkbenchJSON.read(file) :
            ["schema": 1, "sources": BoardObject(), "subscriptions": BoardObject(), "peers": BoardObject()]
        guard state["schema"] as? Int == 1, state["sources"] is [String: BoardObject],
              state["subscriptions"] is [String: BoardObject], state["peers"] is [String: BoardObject] else {
            throw WorkbenchError(409, "规则管理数据损坏或版本不兼容；未覆盖")
        }
        let identity = directory.appendingPathComponent("identity.json")
        if fm.fileExists(atPath: identity.path) {
            guard let value = try WorkbenchJSON.read(identity)["private_key"] as? String,
                  let bytes = Data(base64Encoded: value) else { throw WorkbenchError(503, "规则发布身份损坏；未重新生成身份") }
            key = try Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
        } else {
            key = Curve25519.Signing.PrivateKey()
            try WorkbenchJSON.write(["private_key": key.rawRepresentation.base64EncodedString()], to: identity)
        }
    }
    var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func identifier(_ s: String) -> Bool { s.range(of: "^[a-z0-9][a-z0-9-]{0,62}[a-z0-9]$|^[a-z0-9]$", options: .regularExpression) != nil }
    private func save(_ next: BoardObject) throws { try WorkbenchJSON.write(next, to: directory.appendingPathComponent("state.json")); state = next }
    private func rows(_ key: String) -> [String: BoardObject] { state[key] as? [String: BoardObject] ?? [:] }
    private func exists(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath: url.path)) != nil }
    private func release(_ id: String, _ digest: String) -> URL { directory.appendingPathComponent("releases/\(id)/\(digest)") }
    private func hub(_ id: String) -> URL { home.appendingPathComponent(".cortex-skills/skills/" + id) }
    private func signed(_ body: BoardObject) throws -> BoardObject {
        let bytes = try WorkbenchJSON.data(["issued_at": WorkbenchJSON.timestamp(), "body": body])
        return ["public_key": publicKey, "payload": bytes.base64EncodedString(), "signature": try key.signature(for: bytes).base64EncodedString()]
    }
    static func verify(_ envelope: BoardObject, publicKey: String) throws -> BoardObject {
        guard envelope["public_key"] as? String == publicKey,
              let raw = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              let encoded = envelope["payload"] as? String, encoded.count < 2_000_000, let bytes = Data(base64Encoded: encoded),
              let signature = envelope["signature"] as? String, let sig = Data(base64Encoded: signature), key.isValidSignature(sig, for: bytes) else {
            throw WorkbenchError(409, "来源签名不匹配；未安装")
        }
        let wrapper = try WorkbenchJSON.object(bytes)
        guard let issued = wrapper["issued_at"] as? String, let date = WorkbenchJSON.date(issued),
              abs(date.timeIntervalSinceNow) < 300, let body = wrapper["body"] as? BoardObject else {
            throw WorkbenchError(409, "来源签名已过期；请检查两端时钟并重新读取")
        }
        return body
    }
    static func safePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let forbidden = ["credentials.json", "settings.json", "config.json", "id_rsa", "id_ed25519"]
        return !parts.isEmpty && parts.count <= 8 && path.utf8.count < 240 &&
            parts.allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("\\") && !$0.contains(":") && !$0.contains("\n") && !$0.contains("\r") && !$0.contains("\0") && !forbidden.contains($0.lowercased()) && !$0.lowercased().hasSuffix(".pem") && !$0.lowercased().hasSuffix(".key") }
    }
    static func validate(_ package: BoardObject) throws -> (String, String, [String: String]) {
        guard let id = package["id"] as? String, identifier(id),
              let kind = package["kind"] as? String, ["skill", "hook"].contains(kind),
              let files = package["files"] as? [String: String], !files.isEmpty, files.count <= 128 else { throw WorkbenchError("包清单无效") }
        var total = 0
        for (path, value) in files {
            guard safePath(path), let bytes = Data(base64Encoded: value) else { throw WorkbenchError("包内路径或内容无效") }
            total += bytes.count
        }
        guard total <= 1_000_000 else { throw WorkbenchError(413, "包超过 1 MB；请缩小明确文件清单") }
        if kind == "skill" {
            guard let raw = files["SKILL.md"], let bytes = Data(base64Encoded: raw),
                  let text = String(data: bytes, encoding: .utf8), text.hasPrefix("---\n"),
                  let boundary = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) else { throw WorkbenchError("缺少有效 SKILL.md 入口") }
            let front = String(text[text.index(text.startIndex, offsetBy: 4)..<boundary.lowerBound])
            let lines = front.components(separatedBy: .newlines)
            let name = lines.first(where: { $0.hasPrefix("name:") })?.dropFirst(5).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard name == id, lines.contains(where: { $0.hasPrefix("description:") && !$0.dropFirst(12).trimmingCharacters(in: .whitespaces).isEmpty }) else { throw WorkbenchError("Skill 名称须与包 ID 一致，并提供触发描述") }
        } else {
            guard let hook = package["hook"] as? BoardObject,
                  let event = hook["event"] as? String,
                  ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SubagentStart", "SubagentStop", "PreCompact", "SessionEnd", "Notification"].contains(event),
                  let entry = hook["entry"] as? String, files[entry] != nil,
                  let interpreter = hook["interpreter"] as? String, ["/bin/bash", "/bin/sh", "/usr/bin/python3"].contains(interpreter),
                  (hook["matcher"] as? String ?? "").count < 300 else { throw WorkbenchError("Hook 需要支持的事件、包内入口和解释器；不接受任意安装命令") }
        }
        return (id, kind, files)
    }
    private func makePackage(_ source: BoardObject) throws -> BoardObject {
        guard let root = source["root"] as? String, root.hasPrefix("/"),
              let names = source["files"] as? [String], names.count <= 128 else { throw WorkbenchError("需要绝对目录和明确的文件清单") }
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        var files: [String: String] = [:]
        for name in names {
            guard Self.safePath(name) else { throw WorkbenchError("不允许发布此路径") }
            let file = base.appendingPathComponent(name)
            guard file.resolvingSymlinksInPath().path == file.path,
                  (try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])).isRegularFile == true,
                  (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 1_000_001 <= 1_000_000 else { throw WorkbenchError("发布文件必须是根目录内的普通文件，不能是软链") }
            files[name] = try Data(contentsOf: file).base64EncodedString()
        }
        var package: BoardObject = ["schema": 1, "id": source["id"] ?? "", "title": source["title"] ?? source["id"] ?? "", "kind": source["kind"] ?? "", "files": files]
        if let hook = source["hook"] { package["hook"] = hook }
        _ = try Self.validate(package)
        for (name, value) in files where (try? Data(contentsOf: base.appendingPathComponent(name)).base64EncodedString()) != value {
            throw WorkbenchError(409, "正本正在编辑，请稍后重试；未发布混合版本")
        }
        return package
    }
    func registerSource(_ input: BoardObject) throws -> BoardObject {
        lock.lock(); defer { lock.unlock() }
        let package = try makePackage(input), id = package["id"] as! String
        var next = state, sources = rows("sources")
        if let old = sources[id], old["root"] as? String != input["root"] as? String { throw WorkbenchError(409, "同名来源已登记；不更换正本目录") }
        sources[id] = input; next["sources"] = sources; try save(next)
        return ["ok": true, "id": id, "digest": Self.digest(try WorkbenchJSON.data(package))]
    }
    func exportPackage(_ id: String) throws -> BoardObject {
        lock.lock(); defer { lock.unlock() }
        guard let source = rows("sources")[id] else { throw WorkbenchError(404, "来源包不存在") }
        return try signed(makePackage(source))
    }
    func catalog() throws -> BoardObject {
        lock.lock(); defer { lock.unlock() }
        var catalog: [BoardObject] = []
        for (id, source) in rows("sources").sorted(by: { $0.key < $1.key }) {
            do {
                let package = try makePackage(source)
                catalog.append(["id": id, "title": package["title"] ?? id, "kind": package["kind"] ?? "",
                                "digest": Self.digest(try WorkbenchJSON.data(package)), "files": (source["files"] as? [String] ?? [])])
            } catch { catalog.append(["id": id, "title": source["title"] ?? id, "error": error.localizedDescription]) }
        }
        return try signed(["schema": 1, "at": WorkbenchJSON.timestamp(), "packages": catalog, "machine": Host.current().localizedName ?? "哨兵", "installed": installationRows(), "inventory": inventory()])
    }
    func configurePeer(_ input: BoardObject) throws -> BoardObject {
        lock.lock(); defer { lock.unlock() }
        guard let id = input["id"] as? String, id != "local", Self.identifier(id), let url = input["url"] as? String, WorkbenchRuntime.validHub(url),
              let pub = input["public_key"] as? String, let bytes = Data(base64Encoded: pub), bytes.count == 32,
              let token = input["token"] as? String, !token.isEmpty else { throw WorkbenchError("需要来源名称、局域网地址、配对码和已核对的公钥") }
        var next = state, peers = rows("peers")
        if let old = peers[id], old["public_key"] as? String != pub { throw WorkbenchError(409, "来源公钥改变，不能覆盖信任") }
        var updated = peers[id] ?? [:]
        updated.merge(["id": id, "url": url.trimmingCharacters(in: CharacterSet(charactersIn: "/")), "public_key": pub, "token": token]) { _, new in new }
        peers[id] = updated
        next["peers"] = peers; try save(next); return ["ok": true]
    }
    func peer(_ id: String) throws -> BoardObject {
        lock.lock(); defer { lock.unlock() }
        guard let peer = rows("peers")[id] else { throw WorkbenchError(404, "尚未确认此来源") }; return peer
    }
    func peers() -> [BoardObject] { lock.lock(); defer { lock.unlock() }; return Array(rows("peers").values) }
    func subscriptions() -> [BoardObject] { lock.lock(); defer { lock.unlock() }; return Array(rows("subscriptions").values) }
    func beginSync() -> Bool { lock.lock(); defer { lock.unlock() }; if syncing { return false }; syncing = true; return true }
    func endSync() { lock.lock(); syncing = false; lock.unlock() }
    func cachePeer(_ id: String, catalog: BoardObject?, error: String?) throws {
        lock.lock(); defer { lock.unlock() }
        var next = state, peers = rows("peers"); guard var item = peers[id] else { return }
        if let catalog { item["catalog"] = catalog; item["last_success"] = WorkbenchJSON.timestamp() }
        item["error"] = error; peers[id] = item; next["peers"] = peers; try save(next)
    }
    private func treeMatches(_ directory: URL, files: [String: String]) -> Bool {
        guard let enumerator = fm.enumerator(atPath: directory.path) else { return false }
        var found = Set<String>()
        for case let relative as String in enumerator {
            let file = directory.appendingPathComponent(relative)
            guard let values = try? fm.attributesOfItem(atPath: file.path), values[.type] as? FileAttributeType != .typeSymbolicLink else { return false }
            if values[.type] as? FileAttributeType == .typeRegular {
                guard let expected = files[relative], let bytes = try? Data(contentsOf: file), bytes.base64EncodedString() == expected else { return false }
                found.insert(relative)
            }
        }
        return found == Set(files.keys)
    }
    private func linkMatches(_ link: URL, _ target: URL) -> Bool { (try? fm.destinationOfSymbolicLink(atPath: link.path)) == target.path }
    private func setLink(_ link: URL, _ target: URL) throws {
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = link.deletingLastPathComponent().appendingPathComponent(".sentinel-" + UUID().uuidString)
        try fm.createSymbolicLink(at: temporary, withDestinationURL: target)
        guard Darwin.rename(temporary.path, link.path) == 0 else { try? fm.removeItem(at: temporary); throw WorkbenchError(409, "安装入口改变，未替换") }
    }
    private func savedPackage(_ id: String, _ digest: String) throws -> BoardObject { try WorkbenchJSON.read(directory.appendingPathComponent("packages/\(id)/\(digest).json")) }
    private func currentIntact(_ receipt: BoardObject) -> Bool {
        guard let id = receipt["id"] as? String, let digest = receipt["digest"] as? String,
              let package = try? savedPackage(id, digest), let files = package["files"] as? [String: String], treeMatches(release(id, digest), files: files) else { return false }
        if package["kind"] as? String == "skill" {
            guard linkMatches(hub(id), release(id, digest)) else { return false }
            for host in receipt["targets"] as? [String] ?? [] {
                guard let path = Self.hosts[host], linkMatches(home.appendingPathComponent(path + "/" + id), hub(id)) else { return false }
            }
        } else {
            guard let group = receipt["hook_group"] as? BoardObject, let event = (package["hook"] as? BoardObject)?["event"] as? String,
                  let settings = try? WorkbenchJSON.read(home.appendingPathComponent(".claude/settings.json")),
                  let groups = (settings["hooks"] as? [String: [BoardObject]])?[event], groups.filter({ NSDictionary(dictionary: $0).isEqual(to: group) }).count == 1 else { return false }
        }
        return true
    }
    private func installationRows() -> [BoardObject] {
        rows("subscriptions").values.map { row in
            var safe = row
            safe.removeValue(forKey: "hook_group")
            safe["state"] = currentIntact(row) ? "installed" : "conflict"
            safe["activation"] = "尚无宿主调用证据"
            if let id = row["id"] as? String, let receipt = try? WorkbenchJSON.read(directory.appendingPathComponent("invocations/\(id).json")), receipt["digest"] as? String == row["digest"] as? String {
                safe["invocation"] = receipt
                safe["activation"] = receipt["exit_code"] as? Int != 0 ? "最近一次 Hook 调用失败" : receipt["test"] as? Bool == true ? "仅通过独立冒烟" : "已收到 Hook 调用回执"
            }
            return safe
        }.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
    }
    func status() -> BoardObject {
        lock.lock(); defer { lock.unlock() }
        let catalog = (try? Self.verify(self.catalog(), publicKey: publicKey)) ?? [:]
        let transactionRoot = directory.appendingPathComponent("transactions")
        let incomplete = ((try? fm.contentsOfDirectory(atPath: transactionRoot.path)) ?? []).filter { $0.hasSuffix(".json") }.compactMap { name -> String? in
            guard let transaction = try? WorkbenchJSON.read(transactionRoot.appendingPathComponent(name)),
                  let after = transaction["after"] as? BoardObject, let id = after["id"] as? String,
                  rows("subscriptions")[id]?["digest"] as? String != after["digest"] as? String else { return nil }
            return id
        }
        return ["schema": 1, "public_key": publicKey, "fingerprint": Self.digest(key.publicKey.rawRepresentation), "syncing": syncing,
                "packages": catalog["packages"] ?? [], "installed": installationRows(),
                "incomplete_installs": incomplete,
                "local_sources": rows("sources").values.map { source in source.filter { ["id", "title", "kind", "root", "files"].contains($0.key) } },
                "peers": rows("peers").values.map { item -> BoardObject in var safe = item; safe.removeValue(forKey: "token"); return safe },
                "hosts": Self.hosts.keys.sorted().filter { fm.fileExists(atPath: home.appendingPathComponent(Self.hosts[$0]!).deletingLastPathComponent().path) },
                "inventory": inventory()]
    }
    private func inventory() -> BoardObject {
        var skills: [BoardObject] = []
        for (host, path) in Self.hosts {
            let root = home.appendingPathComponent(path)
            for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where !name.hasPrefix(".") {
                let file = root.appendingPathComponent(name + "/SKILL.md")
                if let bytes = try? Data(contentsOf: file), bytes.count < 1_000_000 {
                    skills.append(["id": name, "host": host, "digest": Self.digest(bytes), "managed": (rows("subscriptions")[name]?["targets"] as? [String] ?? []).contains(host)])
                }
            }
        }
        let settingsFile = home.appendingPathComponent(".claude/settings.json")
        let settings = (try? WorkbenchJSON.read(settingsFile)) ?? [:]
        let hooks = (settings["hooks"] as? [String: [BoardObject]] ?? [:]).map { event, groups -> BoardObject in
            ["event": event, "groups": groups.count, "digest": Self.digest((try? WorkbenchJSON.data(groups)) ?? Data())]
        }
        var projectHooks: [BoardObject] = []
        let repoFile = home.appendingPathComponent("Library/Application Support/Cortex/GateRuntime/repo")
        if let root = try? String(contentsOf: repoFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), root.hasPrefix("/") {
            for name in [".claude/settings.json", ".claude/settings.local.json"] {
                let file = URL(fileURLWithPath: root).appendingPathComponent(name)
                guard exists(file) else { continue }
                if let value = try? WorkbenchJSON.read(file), let groups = value["hooks"] as? [String: [BoardObject]] {
                    projectHooks.append(["scope": name, "events": groups.mapValues { $0.count }, "owner": "GateRuntime / 项目配置", "disabled": value["disableAllHooks"] ?? false])
                } else { projectHooks.append(["scope": name, "error": "配置没有 hooks 或无法读取；不推断为已停用"]) }
            }
        }
        return ["skills": skills, "hooks": hooks, "hooks_disabled": settings["disableAllHooks"] ?? false,
                "hooks_error": exists(settingsFile) && settings.isEmpty ? "用户配置无法读取或为空；无法判断有效配置" : "",
                "project_hooks": projectHooks, "scope": "用户级 + GateRuntime 登记的项目；插件和会话级不自动接管"]
    }

    func install(_ package: BoardObject, source: String, expected: String, targets: [String], automatic: Bool, approveHook: Bool) throws -> BoardObject {
        lock.lock(); defer { lock.unlock() }
        let (id, kind, files) = try Self.validate(package), bytes = try WorkbenchJSON.data(package), digest = Self.digest(bytes)
        guard digest == expected else { throw WorkbenchError(409, "来源版本已变化；请刷新预览后重试") }
        var receipts = rows("subscriptions"), previous = receipts[id]
        if let previous {
            guard previous["source"] as? String == source else { throw WorkbenchError(409, "此包已有其他正本；未换来源") }
            guard currentIntact(previous) else { throw WorkbenchError(409, "本机内容或入口已修改；保留本机版本，请先处理差异") }
        }
        guard kind != "hook" || approveHook else { throw WorkbenchError(409, "Hook 新版本需要在本机确认后启用") }
        guard kind != "skill" || !targets.isEmpty else { throw WorkbenchError("请选择已有的 AI 工具") }
        if kind == "skill" {
            for host in targets {
                guard let path = Self.hosts[host], fm.fileExists(atPath: home.appendingPathComponent(path).deletingLastPathComponent().path) else { throw WorkbenchError(409, "目标 AI 工具尚未安装") }
                let target = home.appendingPathComponent(path + "/" + id)
                guard !exists(target) || (previous != nil && linkMatches(target, hub(id))) else { throw WorkbenchError(409, "同名 Skill 已存在且不归哨兵管理；未覆盖") }
            }
            guard !exists(hub(id)) || previous != nil else { throw WorkbenchError(409, "Skill Hub 已有同名正本；未接管") }
            // Removing targets is a separate explicit operation; updates cannot silently revoke an entry.
            guard Set(previous?["targets"] as? [String] ?? []).isSubset(of: Set(targets)) else { throw WorkbenchError(409, "更新不可隐式移除已安装目标") }
        }
        let destination = release(id, digest)
        if exists(destination) {
            guard treeMatches(destination, files: files) else { throw WorkbenchError(409, "保留版本已被本机修改；未覆盖") }
        } else {
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".stage-" + UUID().uuidString)
            do {
                try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                for (name, value) in files {
                    let file = staging.appendingPathComponent(name)
                    try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(base64Encoded: value)!.write(to: file, options: .atomic)
                }
                try fm.moveItem(at: staging, to: destination)
            } catch {
                // Only the UUID staging directory created by this operation can be removed.
                try? fm.removeItem(at: staging); throw error
            }
        }
        try WorkbenchJSON.write(package, to: directory.appendingPathComponent("packages/\(id)/\(digest).json"))
        var receipt: BoardObject = ["id": id, "title": package["title"] ?? id, "kind": kind, "source": source, "digest": digest,
                                   "targets": targets, "automatic": automatic && kind == "skill", "installed_at": WorkbenchJSON.timestamp()]
        if let old = previous?["digest"] as? String, old != digest { receipt["previous"] = old }
        else if let old = previous?["previous"] { receipt["previous"] = old }
        // Write a durable intent before touching discovery paths. An interrupted transaction is visible, not green.
        try WorkbenchJSON.write(["before": previous ?? [:], "after": receipt], to: directory.appendingPathComponent("transactions/\(id).json"))
        if kind == "skill" {
            try setLink(hub(id), destination)
            for host in targets { try setLink(home.appendingPathComponent(Self.hosts[host]! + "/" + id), hub(id)) }
        } else {
            let group = try mergeHook(package, digest: digest, previous: previous)
            receipt["hook_group"] = group
        }
        receipts[id] = receipt; var next = state; next["subscriptions"] = receipts; try save(next)
        try? fm.removeItem(at: directory.appendingPathComponent("transactions/\(id).json"))
        return ["ok": true, "id": id, "digest": digest, "activation": "已安装；宿主是否使用由调用回执判断"]
    }
    private func mergeHook(_ package: BoardObject, digest: String, previous: BoardObject?) throws -> BoardObject {
        guard fm.fileExists(atPath: home.appendingPathComponent(".claude").path) else { throw WorkbenchError(409, "本机没有 Claude Code 配置目录") }
        let id = package["id"] as! String, definition = package["hook"] as! BoardObject, event = definition["event"] as! String
        let file = home.appendingPathComponent(".claude/settings.json")
        guard !exists(file) || file.resolvingSymlinksInPath().path == file.path else { throw WorkbenchError(409, "settings 是软链；请先明确配置归属") }
        let before = exists(file) ? try Data(contentsOf: file) : nil
        var settings = try before.map(WorkbenchJSON.object) ?? [:]
        guard settings["hooks"] == nil || settings["hooks"] is [String: [BoardObject]] else { throw WorkbenchError(409, "现有 hooks 结构无法安全合并") }
        var hooks = settings["hooks"] as? [String: [BoardObject]] ?? [:]
        if let old = previous?["hook_group"] as? BoardObject {
            for (key, groups) in hooks { hooks[key] = groups.filter { !NSDictionary(dictionary: $0).isEqual(to: old) } }
        }
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = [executable.path, "--managed-hook", directory.path, id, digest].map(quote).joined(separator: " ")
        let group: BoardObject = ["matcher": definition["matcher"] as? String ?? "", "hooks": [["type": "command", "command": command, "timeout": 15]]]
        hooks[event, default: []].append(group); settings["hooks"] = hooks
        if let before { try WorkbenchJSON.write(["bytes": before.base64EncodedString()], to: directory.appendingPathComponent("backups/settings-\(UUID().uuidString).json")) }
        guard (try? Data(contentsOf: file)) == before else { throw WorkbenchError(409, "settings 被其他程序改动；未覆盖") }
        try WorkbenchJSON.write(settings, to: file)
        return group
    }
    func rollback(_ id: String) throws -> BoardObject {
        lock.lock(); defer { lock.unlock() }
        guard let receipt = rows("subscriptions")[id], let previous = receipt["previous"] as? String else { throw WorkbenchError(409, "没有可回退的已安装版本") }
        return try install(savedPackage(id, previous), source: receipt["source"] as! String, expected: previous,
                           targets: receipt["targets"] as? [String] ?? [], automatic: false, approveHook: true)
    }
    func pause(_ id: String) throws -> BoardObject {
        lock.lock(); defer { lock.unlock() }
        var next = state, subscriptions = rows("subscriptions")
        guard subscriptions[id] != nil else { throw WorkbenchError(404, "订阅不存在") }
        subscriptions[id]?["automatic"] = false; next["subscriptions"] = subscriptions; try save(next); return ["ok": true]
    }
    func uninstall(_ id: String) throws -> BoardObject {
        lock.lock(); defer { lock.unlock() }
        guard let receipt = rows("subscriptions")[id], currentIntact(receipt) else { throw WorkbenchError(409, "本机安装已修改或不存在；未删除任何内容") }
        if receipt["kind"] as? String == "hook" {
            let file = home.appendingPathComponent(".claude/settings.json"), before = try Data(contentsOf: file)
            var settings = try WorkbenchJSON.object(before), hooks = settings["hooks"] as? [String: [BoardObject]] ?? [:]
            let owned = receipt["hook_group"] as! BoardObject
            for (event, groups) in hooks { hooks[event] = groups.filter { !NSDictionary(dictionary: $0).isEqual(to: owned) } }
            settings["hooks"] = hooks
            try WorkbenchJSON.write(["bytes": before.base64EncodedString()], to: directory.appendingPathComponent("backups/settings-\(UUID().uuidString).json"))
            guard try Data(contentsOf: file) == before else { throw WorkbenchError(409, "settings 已变化；未覆盖") }
            try WorkbenchJSON.write(settings, to: file)
        } else {
            for host in receipt["targets"] as? [String] ?? [] { try fm.removeItem(at: home.appendingPathComponent(Self.hosts[host]! + "/" + id)) }
            try fm.removeItem(at: hub(id))
        }
        var next = state, subscriptions = rows("subscriptions"); subscriptions.removeValue(forKey: id); next["subscriptions"] = subscriptions; try save(next)
        try? fm.removeItem(at: directory.appendingPathComponent("transactions/\(id).json"))
        return ["ok": true, "message": "仅停用哨兵拥有的入口；正本和历史版本保留，可重新安装。"]
    }
    func recordError(_ id: String, _ error: String?) throws {
        lock.lock(); defer { lock.unlock() }
        var next = state, subscriptions = rows("subscriptions"); subscriptions[id]?["error"] = error
        next["subscriptions"] = subscriptions; try save(next)
    }

    /// Stage-one pointers have one exact owned file. Preserve it before adopting the Hub layout.
    func adoptBoardPointers(expected: String, package: BoardObject, targets: [String]) throws {
        lock.lock(); defer { lock.unlock() }
        let id = "cortex-governance-board"
        if rows("subscriptions")[id] != nil { return }
        var moved: [(URL, URL)] = []
        for host in targets {
            let target = home.appendingPathComponent(Self.hosts[host]! + "/" + id)
            if exists(target) {
                guard target.resolvingSymlinksInPath().path == target.path,
                      (try? fm.contentsOfDirectory(atPath: target.path)) == ["SKILL.md"],
                      [Data(expected.utf8), Data((expected + "\n").utf8)].contains((try? Data(contentsOf: target.appendingPathComponent("SKILL.md"))) ?? Data()) else {
                    throw WorkbenchError(409, "板块维护 Skill 已有本机修改；没有迁移或覆盖")
                }
            }
        }
        do {
            for host in targets {
                let target = home.appendingPathComponent(Self.hosts[host]! + "/" + id)
                if exists(target) {
                    let backup = directory.appendingPathComponent("backups/board-\(host)-\(UUID().uuidString)")
                    try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: target, to: backup); moved.append((target, backup))
                }
            }
            _ = try install(package, source: "local", expected: Self.digest(WorkbenchJSON.data(package)), targets: targets, automatic: true, approveHook: false)
        } catch {
            for (target, backup) in moved where !exists(target) { try? fm.moveItem(at: backup, to: target) }
            throw error
        }
    }

    func hookDefinition(id: String, digest: String) throws -> (BoardObject, URL) {
        lock.lock(); defer { lock.unlock() }
        guard Self.identifier(id), digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              let receipt = rows("subscriptions")[id], receipt["digest"] as? String == digest, currentIntact(receipt) else {
            throw WorkbenchError(409, "Hook 版本或注册已改变，拒绝执行未确认内容")
        }
        let package = try savedPackage(id, digest)
        guard Self.digest(try WorkbenchJSON.data(package)) == digest, let hook = package["hook"] as? BoardObject else { throw WorkbenchError("Hook 清单校验失败") }
        return (hook, release(id, digest))
    }
}
