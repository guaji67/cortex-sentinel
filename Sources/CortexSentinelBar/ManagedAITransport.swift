import Foundation

private final class ManagedAINoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

extension ManagedAIPackages {
    func fetch(peer: BoardObject, path: String) async throws -> BoardObject {
        guard let base = peer["url"] as? String, WorkbenchRuntime.validHub(base),
              let token = peer["token"] as? String, let pub = peer["public_key"] as? String,
              let url = URL(string: base + path) else { throw WorkbenchError(409, "来源配置无效") }
        let session = URLSession(configuration: .ephemeral, delegate: ManagedAINoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (stream, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw WorkbenchError(503, "来源不可读；检查连接、配对与版本") }
        var data = Data()
        for try await byte in stream {
            guard data.count < 2_000_000 else { throw WorkbenchError(413, "来源响应过大") }
            data.append(byte)
        }
        let body = try Self.verify(WorkbenchJSON.object(data), publicKey: pub)
        guard body["schema"] as? Int == 1 else { throw WorkbenchError(409, "来源协议版本不兼容") }
        if path == "/api/ai/catalog" {
            guard let packages = body["packages"] as? [BoardObject], packages.count <= 256,
                  body["installed"] is [BoardObject] else { throw WorkbenchError(409, "来源目录结构无效；保留上次快照") }
        }
        return body
    }
    func package(source: String, id: String) async throws -> BoardObject {
        guard Self.identifier(id) else { throw WorkbenchError("包名称无效") }
        let package = source == "local" ? try Self.verify(exportPackage(id), publicKey: publicKey) : try await fetch(peer: peer(source), path: "/api/ai/package/" + id)
        guard package["id"] as? String == id else { throw WorkbenchError(409, "来源返回了不同的包；未安装") }
        _ = try Self.validate(package)
        return package
    }
    func synchronize() async {
        guard beginSync() else { return }
        defer { endSync() }
        for peer in peers() {
            guard let id = peer["id"] as? String else { continue }
            do { try cachePeer(id, catalog: await fetch(peer: peer, path: "/api/ai/catalog"), error: nil) }
            catch { try? cachePeer(id, catalog: nil, error: "连接或签名校验失败；保留上次读数") }
        }
        for subscription in subscriptions() where subscription["automatic"] as? Bool == true {
            guard let id = subscription["id"] as? String, let source = subscription["source"] as? String else { continue }
            do {
                let package = try await package(source: source, id: id)
                let digest = Self.digest(try WorkbenchJSON.data(package))
                if digest != subscription["digest"] as? String {
                    _ = try install(package, source: source, expected: digest, targets: subscription["targets"] as? [String] ?? [], automatic: true, approveHook: false)
                }
                try recordError(id, nil)
            } catch { try? recordError(id, error.localizedDescription) }
        }
    }
    func respond(_ request: WorkbenchRequest) async throws -> WorkbenchResponse {
        let path = request.path
        if request.method == "GET", path == "/api/ai/identity" { return .json(["public_key": publicKey]) }
        if request.method == "GET", path == "/api/ai/catalog" { return .json(try catalog()) }
        if request.method == "GET", path.hasPrefix("/api/ai/package/") { return .json(try exportPackage(String(path.dropFirst("/api/ai/package/".count)))) }
        guard request.local else { throw WorkbenchError(403, "安装和信任设置只允许在目标机器本机操作") }
        if request.method == "GET", path == "/api/ai/status" { return .json(status()) }
        try request.localWrite()
        guard request.method == "POST" else { throw WorkbenchError(405, "此操作需要 POST") }
        let value = try WorkbenchJSON.object(request.body)
        if path == "/api/ai/source" { return .json(try registerSource(value)) }
        if path == "/api/ai/peer" { return .json(try configurePeer(value)) }
        if path == "/api/ai/sync" { await synchronize(); return .json(status()) }
        guard let id = value["id"] as? String, Self.identifier(id) else { throw WorkbenchError("需要包名称") }
        if path == "/api/ai/rollback" { return .json(try rollback(id)) }
        if path == "/api/ai/pause" { return .json(try pause(id)) }
        if path == "/api/ai/uninstall" { return .json(try uninstall(id)) }
        let source = value["source"] as? String ?? "local"
        let package = try await package(source: source, id: id)
        if path == "/api/ai/preview" {
            return .json(["package": package, "digest": Self.digest(try WorkbenchJSON.data(package)),
                          "warning": "Skill 可包含可执行资源。Hook 会执行命令；只启用自己核对过的来源及版本。"])
        }
        if path == "/api/ai/install" {
            guard let expected = value["digest"] as? String else { throw WorkbenchError("先预览内容并确认版本") }
            return .json(try install(package, source: source, expected: expected, targets: value["targets"] as? [String] ?? [],
                                     automatic: value["automatic"] as? Bool == true, approveHook: value["approve_hook"] as? Bool == true))
        }
        throw WorkbenchError(404, "规则管理接口不存在")
    }
}
