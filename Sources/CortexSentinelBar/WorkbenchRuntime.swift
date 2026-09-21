import Foundation
import AppKit

/// App-owned lifecycle and versioned API. Only this boundary projects the native Sentinel state.
final class WorkbenchRuntime: @unchecked Sendable {
    static let protocolVersion = 1
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cortex-sentinel/workbench")
    }
    let directory: URL
    let assets: URL
    let ledger: WorkbenchLedger
    let multica: WorkbenchMultica
    private let lock = NSLock()
    private var config: BoardObject
    private var server: WorkbenchHTTPServer?
    private var discovery = LanPeerBrowser(serviceType: "_cortex-board._tcp")
    private var peers: [LanPeer] = []
    private var timer: DispatchSourceTimer?
    private var sourceRefreshInFlight = false
    private var sourceErrors: [String: String] = [:]
    private let nativeSnapshot: @Sendable () async -> BoardObject
    private let managedInstallation: Bool
    var onStatus: @Sendable (String?) -> Void = { _ in }
    var port: UInt16 { UInt16(configuration()["port"] as? Int ?? 8935) }

    init(directory: URL = WorkbenchRuntime.defaultDirectory, assets: URL, managedInstallation: Bool = true,
         nativeSnapshot: @escaping @Sendable () async -> BoardObject) throws {
        self.directory = directory; self.assets = assets; self.nativeSnapshot = nativeSnapshot
        self.managedInstallation = managedInstallation
        let configURL = directory.appendingPathComponent("config.json")
        if FileManager.default.fileExists(atPath: configURL.path) {
            config = try WorkbenchJSON.read(configURL)
        } else {
            config = ["mode": "unconfigured", "port": 8935, "node_id": UUID().uuidString,
                      "view_key": UUID().uuidString + UUID().uuidString,
                      "clients": ["local-admin": ["secret": UUID().uuidString + UUID().uuidString, "scopes": ["*"]]]]
            try WorkbenchJSON.write(config, to: configURL)
        }
        guard let p = config["port"] as? Int, (1024...65535).contains(p) else { throw WorkbenchError("工作台端口无效") }
        ledger = try WorkbenchLedger(url: directory.appendingPathComponent("ledger.json"))
        multica = WorkbenchMultica(url: directory.appendingPathComponent("multica.json"),
            executable: config["multica_bin"] as? String ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/multica").path)
    }
    func configuration() -> BoardObject { lock.lock(); defer { lock.unlock() }; return config }
    private func saveConfiguration(_ next: BoardObject) throws {
        lock.lock(); defer { lock.unlock() }
        try WorkbenchJSON.write(next, to: directory.appendingPathComponent("config.json")); config = next
    }
    func start() throws {
        let server = WorkbenchHTTPServer(port: port, status: onStatus) { [weak self] request in
            guard let self else { return .json(["error": "哨兵正在退出"], status: 503) }
            do { return try await self.respond(request) }
            catch {
                let failure = error as? WorkbenchError
                return .json(["error": failure?.message ?? "工作台读取或保存失败；未覆盖已有资料"], status: failure?.status ?? 500)
            }
        }
        self.server = server; try server.start()
        discovery.start { [weak self] peers in
            guard let self else { return }; self.lock.lock(); self.peers = peers; self.lock.unlock()
        }
        guard managedInstallation else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 10, repeating: 180)
        timer.setEventHandler { [weak self] in self?.refreshSources() }
        self.timer = timer; timer.resume()
        installClientLocation()
        if configuration()["install_ai_skill"] as? Bool == true { try? installSkill() }
    }
    func stop() { timer?.cancel(); timer = nil; discovery.stop(); server?.stop(); server = nil }
    func open() { NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(port)/")!) }

    private func installSkill() throws {
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser
        for host in [".claude", ".codex"] where fm.fileExists(atPath: home.appendingPathComponent(host).path) {
            let target = home.appendingPathComponent(host + "/skills/cortex-governance-board")
            guard !fm.fileExists(atPath: target.path) else { continue } // never replace somebody's customized skill
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: target, withDestinationURL: assets.appendingPathComponent("skill"))
        }
    }

    private func installClientLocation() {
        let config = configuration()
        guard let client = (config["clients"] as? [String: BoardObject])?["local-admin"], let secret = client["secret"] as? String else { return }
        // Compatibility discovery file contains only coordinates; secret stays in its own 0600 profile.
        let profile = directory.appendingPathComponent("local-client.json")
        try? WorkbenchJSON.write(["url": "http://127.0.0.1:\(port)", "client": "local-admin", "secret": secret], to: profile)
        let location = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/cortex-board/location.json")
        var existing = (try? WorkbenchJSON.read(location)) ?? [:]
        let existingProfile = existing["profile"]
        existing.merge(["url": "http://127.0.0.1:\(port)", "profile": profile.path,
                        "client": assets.appendingPathComponent("client/client.py").path,
                        "guide": "http://127.0.0.1:\(port)/api/guide", "owner": "cortex-sentinel"]) { _, new in new }
        // Joined machines retain their scoped hub profile rather than silently becoming administrators.
        if config["mode"] as? String == "joined" {
            existing["profile"] = config["maintenance_profile"] ?? existingProfile ?? NSNull()
            existing["url"] = config["hub_url"] ?? ""
        }
        try? WorkbenchJSON.write(existing, to: location)
    }

    private func refreshSources() {
        let config = configuration()
        if config["mode"] as? String == "host" { Task { await multica.refresh() } }
        lock.lock()
        guard !sourceRefreshInFlight else { lock.unlock(); return }
        sourceRefreshInFlight = true; lock.unlock()
        Task {
            let sources = config["local_sources"] as? [BoardObject] ?? []
            var errors: [String: String] = [:]
            for source in sources {
                guard let file = source["file"] as? String, let track = source["track"] as? String else { continue }
                let profile = source["profile"] as? String ?? directory.appendingPathComponent("local-client.json").path
                let script = assets.appendingPathComponent("client/client.py").path
                let out = await CortexProcessSubprocessRunner().run(executablePath: "/usr/bin/python3",
                    arguments: [script, "--profile", profile, "publish-html", "--track", track, "--file", file],
                    workingDirectory: nil, environment: nil, stdin: nil, timeout: 40)
                if out.exitCode != 0 { errors[track] = "原图发布失败；保留上次来源。请检查文件权限、维护授权与连接。" }
            }
            self.finishSourceRefresh(errors)
        }
    }
    private func finishSourceRefresh(_ errors: [String: String]) {
        lock.lock(); sourceRefreshInFlight = false; sourceErrors = errors; lock.unlock()
    }
    private func peerURLs() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return peers.map { "http://\($0.host):\($0.port)" }.sorted()
    }
    private func currentSourceErrors() -> [String: String] {
        lock.lock(); defer { lock.unlock() }; return sourceErrors
    }
    static func validHub(_ text: String) -> Bool {
        guard let url = URL(string: text), url.scheme == "http", let host = url.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return false }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        let privateIP = parts.count == 4 && parts.allSatisfy { (0...255).contains($0) } &&
            (parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1])))
        return privateIP || host == "localhost" || host.hasSuffix(".local")
    }
    private func proxy(_ path: String, config: BoardObject) async throws -> WorkbenchResponse {
        guard let hub = config["hub_url"] as? String, Self.validHub(hub), let url = URL(string: hub + path),
              let key = config["hub_key"] as? String else { throw WorkbenchError(503, "未连接共享工作台") }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 20_000_000 else {
            throw WorkbenchError(503, "共享工作台离线、授权失效或版本不兼容；没有切换成空白本地账")
        }
        if path == "/api/overview" {
            var body = try WorkbenchJSON.object(data)
            guard body["schema"] as? Int == Self.protocolVersion,
                  body["node_id"] as? String == config["hub_id"] as? String else { throw WorkbenchError(409, "对端身份或协议已变化，请重新确认连接") }
            body["connection"] = ["mode": "joined", "hub_url": hub]
            return .json(body)
        }
        return WorkbenchResponse(data: data)
    }

    func respond(_ request: WorkbenchRequest) async throws -> WorkbenchResponse {
        try request.enforceOrigin()
        let config = configuration()
        let path = request.path.components(separatedBy: "?")[0]
        let host = request.headers["host"]?.lowercased().split(separator: ":").first.map(String.init) ?? ""
        guard Self.validHub("http://" + host) else { throw WorkbenchError(403, "不接受此主机名") }
        let staticFiles = ["/": "index.html", "/index.html": "index.html", "/workbench.js": "workbench.js", "/workbench.css": "workbench.css"]
        if request.method == "GET", let file = staticFiles[path] {
            return WorkbenchResponse(contentType: file.hasSuffix(".js") ? "text/javascript; charset=utf-8" : file.hasSuffix(".css") ? "text/css; charset=utf-8" : "text/html; charset=utf-8",
                                     data: try Data(contentsOf: assets.appendingPathComponent(file)))
        }
        if request.method == "GET", path == "/api/info" {
            return .json(["schema": Self.protocolVersion, "node_id": config["node_id"] ?? "", "mode": config["mode"] ?? "unconfigured",
                          "name": Host.current().localizedName ?? "哨兵", "local": request.local,
                          "peers": request.local ? peerURLs() : []])
        }
        if request.method == "POST", path == "/api/pair" {
            let value = try WorkbenchJSON.object(request.body)
            guard let key = value["key"] as? String, WorkbenchAuth.equal(key, config["view_key"] as? String ?? "") else { throw WorkbenchError(401, "配对码不正确") }
            var response = WorkbenchResponse.json(["ok": true])
            response.headers["Set-Cookie"] = "sentinel_view=\(key); Path=/; HttpOnly; SameSite=Strict; Max-Age=86400"
            return response
        }
        if path == "/api/settings" {
            guard request.local else { throw WorkbenchError(403, "连接设置只在本机操作") }
            if request.method == "GET" {
                return .json(["mode": config["mode"] ?? "unconfigured", "hub_url": config["hub_url"] ?? "",
                              "view_key": config["view_key"] ?? "", "port": port,
                              "address": "http://\(Host.current().name ?? "localhost"):\(port)",
                              "data_directory": directory.path, "peers": peerURLs()])
            }
            try request.localWrite()
            let value = try WorkbenchJSON.object(request.body)
            var next = config
            if value["mode"] as? String == "host" {
                guard config["mode"] as? String != "joined" else { throw WorkbenchError(409, "已连接共享账；不允许一键拆出另一份账。请先导出并明确迁移。") }
                next["mode"] = "host"
            } else if value["mode"] as? String == "joined" {
                guard (ledger.snapshot()["entities"] as? BoardObject ?? [:]).isEmpty else { throw WorkbenchError(409, "本机已有资料，请先迁移，避免丢失或分叉") }
                guard let hub = value["hub_url"] as? String, Self.validHub(hub), let key = value["hub_key"] as? String, !key.isEmpty else { throw WorkbenchError("需要局域网地址与配对码") }
                var probe = URLRequest(url: URL(string: hub.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/overview")!, timeoutInterval: 8)
                probe.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
                let (data, response) = try await URLSession.shared.data(for: probe)
                guard (response as? HTTPURLResponse)?.statusCode == 200, let body = try? WorkbenchJSON.object(data),
                      body["schema"] as? Int == Self.protocolVersion, let id = body["node_id"] as? String,
                      id != config["node_id"] as? String else { throw WorkbenchError(409, "连接未通过：请核对配对码、对端版本与地址") }
                next["mode"] = "joined"; next["hub_url"] = hub.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                next["hub_key"] = key; next["hub_id"] = id
            } else { throw WorkbenchError("选择保存共享账或连接已有工作台") }
            try saveConfiguration(next); installClientLocation(); return .json(["ok": true])
        }
        if path == "/api/clients", request.method == "POST" {
            try request.localWrite()
            guard config["mode"] as? String == "host" else { throw WorkbenchError(409, "请在保存共享账的机器授权") }
            let value = try WorkbenchJSON.object(request.body)
            guard let name = value["name"] as? String, WorkbenchJSON.validID(name), name != "local-admin",
                  let scopes = value["scopes"] as? [String], !scopes.isEmpty,
                  scopes.allSatisfy({ $0 != "*" && WorkbenchJSON.validID($0) }) else { throw WorkbenchError("需要维护者名称与明确的板块范围，不发放远程全局权限") }
            var next = config, clients = config["clients"] as? [String: BoardObject] ?? [:]
            guard clients[name] == nil else { throw WorkbenchError(409, "维护者已存在；未覆盖原密钥") }
            let secret = UUID().uuidString + UUID().uuidString
            clients[name] = ["secret": secret, "scopes": scopes]; next["clients"] = clients
            try saveConfiguration(next)
            return .json(["client": name, "secret": secret, "scopes": scopes])
        }
        if path == "/api/install-skill", request.method == "POST" {
            try request.localWrite()
            try installSkill()
            var next = configuration(); next["install_ai_skill"] = true; try saveConfiguration(next)
            return .json(["ok": true, "message": "已为已有 AI host 接入随包技能；已有自定义同名技能不会覆盖。新会话生效，当前会话可直接读取随包技能。"])
        }
        guard WorkbenchAuth.canRead(request, config: config) else { throw WorkbenchError(401, "需要配对后才能读取工作台") }
        if config["mode"] as? String == "joined" {
            guard request.method == "GET", ["/api/overview", "/api/guide", "/api/history"].contains(path) || path.hasPrefix("/api/entities/") else {
                throw WorkbenchError(403, "维护内容请使用有板块授权的客户端直连共享账；浏览配对码不能写账")
            }
            return try await proxy(request.path, config: config)
        }
        if request.method == "GET" {
            if path == "/api/guide" { return .json(["schema": 1, "guide": try String(contentsOf: assets.appendingPathComponent("GUIDE.md"), encoding: .utf8)]) }
            if path == "/api/history" { return .json(["events": Array((ledger.snapshot()["events"] as? [String: BoardObject] ?? [:]).values).sorted { ($0["at"] as? String ?? "") > ($1["at"] as? String ?? "") }.prefix(100).map { $0 }]) }
            if path.hasPrefix("/api/entities/") {
                guard let entity = projectedEntities()[String(path.dropFirst(14))] else { throw WorkbenchError(404, "记录不存在") }; return .json(entity)
            }
            if path == "/api/overview" { return .json(await overview()) }
            if path.hasPrefix("/api/tickets/") { return .json(try await multica.detail(String(path.dropFirst(13)))) }
        }
        guard config["mode"] as? String == "host" else { throw WorkbenchError(409, "请先选择共享工作台") }
        if request.method == "POST", path == "/api/refresh" {
            try request.localWrite(); Task { await multica.refresh(force: true) }; refreshSources(); return .json(["ok": true, "syncing": true])
        }
        if request.method == "PUT", path == "/api/drafts" {
            try request.localWrite(); return .json(try ledger.saveDrafts(WorkbenchJSON.object(request.body)))
        }
        if request.method == "POST", ["/api/update", "/api/source"].contains(path) {
            let (actor, scopes) = try WorkbenchAuth.writer(request, config: config)
            let body = try WorkbenchJSON.object(request.body)
            return .json(try path == "/api/update" ? ledger.update(body, actor: actor, scopes: scopes) : ledger.publish(body, scopes: scopes))
        }
        throw WorkbenchError(404, "接口不存在")
    }

    func projectedEntities() -> [String: BoardObject] {
        let doc = ledger.snapshot()
        let sources = doc["sources"] as? [String: BoardObject] ?? [:]
        let entities = doc["entities"] as? [String: BoardObject] ?? [:]
        // Imported rendering is a source projection; explicit AI amendments take precedence.
        var merged = entities
        for (id, row) in entities where row["origin"] as? String == "imported" && row["updated_by"] == nil {
            if let track = row["track"] as? String, let source = sources[track],
               !(source["blocks"] as? [BoardObject] ?? []).contains(where: { $0["id"] as? String == id }) {
                merged[id]?["archived"] = true
            }
        }
        for source in sources.values {
            for block in source["blocks"] as? [BoardObject] ?? [] {
                guard let id = block["id"] as? String else { continue }
                var row = block; row["kind"] = "area"; row["revision"] = 0; row["origin"] = "source"
                if let saved = entities[id] {
                    if saved["origin"] as? String == "imported", saved["updated_by"] == nil {
                        row["revision"] = saved["revision"] ?? 0
                    } else { row.merge(saved) { _, new in new } }
                }
                merged[id] = row
            }
        }
        return merged
    }

    func overview() async -> BoardObject {
        let doc = ledger.snapshot(), config = configuration()
        var upstream = (try? WorkbenchJSON.read(directory.appendingPathComponent("multica.json"))) ?? [:]
        let sources = doc["sources"] as? [String: BoardObject] ?? [:]
        let merged = projectedEntities(), errors = currentSourceErrors()
        upstream.merge(["schema": Self.protocolVersion, "node_id": config["node_id"] ?? "", "entities": Array(merged.values),
                        "sources": sources, "drafts": doc["drafts"] ?? [:], "draft_revision": doc["draft_revision"] ?? 0,
                        "connection": ["mode": config["mode"] ?? "unconfigured"], "source_errors": errors,
                        "sentinel": await nativeSnapshot(), "sync": await multica.status()]) { _, new in new }
        return upstream
    }
}
