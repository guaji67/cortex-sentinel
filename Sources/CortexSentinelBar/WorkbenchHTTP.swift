import Foundation
import Network
import CryptoKit

struct WorkbenchRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
    var loopback: Bool

    static func parse(_ bytes: Data, loopback: Bool) throws -> WorkbenchRequest? {
        guard bytes.count <= 2_100_000 else { throw WorkbenchError(413, "请求过大") }
        guard let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) else {
            if bytes.count > 16_384 { throw WorkbenchError(413, "请求头过大") }; return nil
        }
        guard boundary.lowerBound <= 16_384,
              let head = String(data: bytes[..<boundary.lowerBound], encoding: .utf8) else { throw WorkbenchError("请求头无效") }
        let lines = head.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ")
        guard start.count == 3, ["GET", "POST", "PUT"].contains(String(start[0])), start[1].hasPrefix("/") else {
            throw WorkbenchError("请求无效")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw WorkbenchError("请求头无效") }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { throw WorkbenchError("不接受重复请求头") }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil,
              let length = Int(headers["content-length"] ?? "0"), length >= 0, length <= 2_000_000 else { throw WorkbenchError(413, "不支持此请求长度") }
        guard bytes.count >= boundary.upperBound + length else { return nil }
        guard bytes.count == boundary.upperBound + length else { throw WorkbenchError("不接受流水线请求") }
        return WorkbenchRequest(method: String(start[0]), path: String(start[1]), headers: headers,
                                body: bytes[boundary.upperBound...], loopback: loopback)
    }

    var local: Bool {
        let host = headers["host"]?.lowercased().split(separator: ":").first.map(String.init) ?? ""
        return loopback && ["localhost", "127.0.0.1"].contains(host)
    }
    func enforceOrigin() throws {
        if let origin = headers["origin"], origin != "http://" + (headers["host"] ?? "") {
            throw WorkbenchError(403, "拒绝跨站请求")
        }
        if headers["sec-fetch-site"] == "cross-site" { throw WorkbenchError(403, "拒绝跨站请求") }
    }
    func localWrite() throws {
        try enforceOrigin()
        guard local, headers["x-sentinel-local"] == "1" else { throw WorkbenchError(403, "请在本机哨兵中操作") }
    }
}

struct WorkbenchResponse {
    var status = 200
    var contentType = "application/json; charset=utf-8"
    var data: Data
    var headers: [String: String] = [:]
    static func json(_ value: Any, status: Int = 200) -> WorkbenchResponse {
        WorkbenchResponse(status: status, data: (try? WorkbenchJSON.data(value)) ?? Data("{}".utf8))
    }
    var wire: Data {
        let fixed = ["Content-Type": contentType, "Content-Length": String(data.count), "Connection": "close",
                     "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer",
                     "Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"]
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
        for (key, value) in fixed.merging(headers, uniquingKeysWith: { _, new in new }) { head += "\(key): \(value)\r\n" }
        return Data((head + "\r\n").utf8) + data
    }
}

enum WorkbenchAuth {
    static func signature(secret: String, timestamp: String, path: String, body: Data) -> String {
        let bytes = Data((timestamp + "\n" + path + "\n").utf8) + body
        return HMAC<SHA256>.authenticationCode(for: bytes, using: SymmetricKey(data: Data(secret.utf8)))
            .map { String(format: "%02x", $0) }.joined()
    }
    static func equal(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8), right = Array(b.utf8)
        guard left.count == right.count, !left.isEmpty else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    static func writer(_ request: WorkbenchRequest, config: BoardObject) throws -> (String, [String]) {
        guard let actor = request.headers["x-board-client"],
              let client = (config["clients"] as? [String: BoardObject])?[actor],
              let secret = client["secret"] as? String, let scopes = client["scopes"] as? [String],
              let stamp = request.headers["x-board-time"], let seconds = Double(stamp), seconds.isFinite,
              abs(Date().timeIntervalSince1970 - seconds) < 300,
              equal(request.headers["x-board-signature"] ?? "", signature(secret: secret, timestamp: stamp, path: request.path, body: request.body)) else {
            throw WorkbenchError(401, "需要有效的维护签名")
        }
        return (actor, scopes)
    }
    static func canRead(_ request: WorkbenchRequest, config: BoardObject) -> Bool {
        if request.local { return true }
        if (try? writer(request, config: config)) != nil { return true }
        let token = request.headers["authorization"]?.replacingOccurrences(of: "Bearer ", with: "") ??
            request.headers["cookie"]?.components(separatedBy: "; ").first(where: { $0.hasPrefix("sentinel_view=") })?.dropFirst(14).description ?? ""
        return equal(token, config["view_key"] as? String ?? "")
    }
}

/// A bounded HTTP transport owned by the existing App process, not a second launchd service.
final class WorkbenchHTTPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cortex.sentinel.workbench.http")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var processing: Set<ObjectIdentifier> = []
    private let handler: @Sendable (WorkbenchRequest) async -> WorkbenchResponse
    private let status: @Sendable (String?) -> Void
    let port: UInt16
    init(port: UInt16, status: @escaping @Sendable (String?) -> Void,
         handler: @escaping @Sendable (WorkbenchRequest) async -> WorkbenchResponse) {
        self.port = port; self.status = status; self.handler = handler
    }
    func start() throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.service = NWListener.Service(name: Host.current().localizedName ?? "Cortex", type: "_cortex-board._tcp")
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.status(nil) }
            if case .failed = state { self?.status("工作台端口被占用或网络服务不可用；没有停止其他程序") }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        self.listener = listener; listener.start(queue: queue)
    }
    func stop() {
        queue.async {
            self.listener?.cancel(); self.listener = nil
            self.connections.values.forEach { $0.cancel() }; self.connections.removeAll()
        }
    }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 32 else { connection.cancel(); return }
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) { [weak self, weak connection] in
            if let connection, self?.processing.contains(ObjectIdentifier(connection)) != true { self?.finish(connection) }
        }
        read(connection, accumulated: Data())
    }
    private func finish(_ connection: NWConnection) { connections.removeValue(forKey: ObjectIdentifier(connection)); processing.remove(ObjectIdentifier(connection)); connection.cancel() }
    private func read(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var next = accumulated; if let data { next.append(data) }
            let endpoint = String(describing: connection.endpoint)
            let local = endpoint.hasPrefix("127.0.0.1:") || endpoint.hasPrefix("[::1]:") || endpoint.hasPrefix("::1.")
            do {
                guard let request = try WorkbenchRequest.parse(next, loopback: local) else {
                    if complete || error != nil { self.finish(connection) } else { self.read(connection, accumulated: next) }; return
                }
                self.processing.insert(ObjectIdentifier(connection))
                self.queue.asyncAfter(deadline: .now() + 75) { [weak self, weak connection] in if let connection { self?.finish(connection) } }
                Task {
                    let response = await self.handler(request)
                    self.queue.async { self.send(response, connection: connection) }
                }
            } catch {
                let failure = error as? WorkbenchError ?? WorkbenchError("请求无效")
                self.send(.json(["error": failure.message], status: failure.status), connection: connection)
            }
        }
    }
    private func send(_ response: WorkbenchResponse, connection: NWConnection) {
        connection.send(content: response.wire, completion: .contentProcessed { [weak self] _ in
            self?.queue.async { self?.finish(connection) }
        })
    }
}
