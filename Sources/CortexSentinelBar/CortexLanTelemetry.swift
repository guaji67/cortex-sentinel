import Foundation
import Network

struct LanPeer: Equatable, Sendable {
    let host: String
    let port: UInt16
}

private let lanTelemetryCommand = Data("TELEMETRY\n".utf8)
private let lanTelemetryServiceType = "_cortex-sentinel._tcp"

/// 本机遥测 TCP 服务：监听端口，收到一行 "TELEMETRY\n" 就回 payloadProvider()
/// 给的 JSON 字节然后关连接。端口被占或任何启动失败都静默降级（isRunning == false），
/// 绝不影响哨兵主体。
final class LanTelemetryServer: @unchecked Sendable {
    let port: UInt16
    private(set) var isRunning: Bool
    private let payloadProvider: @Sendable () async -> Data?
    private let queue = DispatchQueue(label: "cortex.lan.telemetry.server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var epoch: UInt64 = 0
    private var startGate: DispatchSemaphore?

    init(port: UInt16 = 47077, payloadProvider: @escaping @Sendable () async -> Data?) {
        self.port = port
        self.isRunning = false
        self.payloadProvider = payloadProvider
    }

    func start() {
        let gate = DispatchSemaphore(value: 0)
        let startedEpoch: UInt64 = queue.sync {
            epoch += 1
            let current = epoch
            beginListen(epoch: current, gate: gate, attemptsLeft: 12)
            return current
        }
        _ = gate.wait(timeout: .now() + 2)
        queue.sync {
            if epoch == startedEpoch, !isRunning {
                tearDown()
            }
        }
    }

    func stop() {
        let released = DispatchSemaphore(value: 0)
        queue.sync {
            epoch += 1
            let existing = listener
            tearDown()
            if existing == nil {
                released.signal()
            } else {
                // 等内核放开 bind，下一次 start 才站得住同一端口。
                queue.asyncAfter(deadline: .now() + 0.08) {
                    released.signal()
                }
            }
        }
        _ = released.wait(timeout: .now() + 1)
    }

    private func beginListen(epoch startedEpoch: UInt64, gate: DispatchSemaphore, attemptsLeft: Int) {
        if isRunning {
            gate.signal()
            return
        }
        tearDown()
        startGate = gate
        openListener(epoch: startedEpoch, attemptsLeft: attemptsLeft)
    }

    private func openListener(epoch startedEpoch: UInt64, attemptsLeft: Int) {
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            listener.service = NWListener.Service(
                name: Host.current().localizedName ?? "cortex",
                type: lanTelemetryServiceType
            )
            listener.stateUpdateHandler = { [weak self] state in
                self?.queue.async {
                    self?.handleListener(state, epoch: startedEpoch, attemptsLeft: attemptsLeft)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.queue.async {
                    self?.accept(connection)
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            retryOrFail(epoch: startedEpoch, attemptsLeft: attemptsLeft)
        }
    }

    private func handleListener(_ state: NWListener.State, epoch startedEpoch: UInt64, attemptsLeft: Int) {
        guard startedEpoch == epoch else { return }
        switch state {
        case .ready:
            isRunning = true
            signalStartGate()
        case .failed:
            retryOrFail(epoch: startedEpoch, attemptsLeft: attemptsLeft)
        case .cancelled:
            isRunning = false
            signalStartGate()
        default:
            break
        }
    }

    private func retryOrFail(epoch startedEpoch: UInt64, attemptsLeft: Int) {
        guard startedEpoch == epoch else { return }
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        isRunning = false
        guard attemptsLeft > 0, startGate != nil else {
            signalStartGate()
            return
        }
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.epoch == startedEpoch else { return }
            self.openListener(epoch: startedEpoch, attemptsLeft: attemptsLeft - 1)
        }
    }

    private func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.queue.async {
                guard let self else { return }
                if case .failed = state {
                    self.finish(connection)
                } else if case .cancelled = state {
                    self.forget(connection)
                }
            }
        }
        connection.start(queue: queue)
        receiveCommand(connection, buffer: Data())
    }

    private func receiveCommand(_ connection: NWConnection, buffer: Data) {
        // "TELEMETRY\n" 实为 10 字节；工单写 12 是长度笔误。满命令或 EOF 即可判定，
        // 若死等 12 字节会与只发 10 字节的拉取器互锁。
        connection.receive(minimumIncompleteLength: 1, maximumLength: 12) { [weak self] data, _, isComplete, error in
            self?.queue.async {
                guard let self else { return }
                if error != nil {
                    self.finish(connection)
                    return
                }
                var next = buffer
                if let data {
                    next.append(data)
                }
                if next.count >= lanTelemetryCommand.count || isComplete {
                    self.serveIfRequested(connection, request: next)
                    return
                }
                self.receiveCommand(connection, buffer: next)
            }
        }
    }

    private func serveIfRequested(_ connection: NWConnection, request: Data) {
        guard request.starts(with: lanTelemetryCommand) else {
            finish(connection)
            return
        }
        Task { [payloadProvider] in
            let payload = await payloadProvider()
            self.queue.async {
                guard let payload else {
                    self.finish(connection)
                    return
                }
                connection.send(content: payload, isComplete: true, completion: .contentProcessed { [weak self] _ in
                    self?.queue.async {
                        self?.finish(connection)
                    }
                })
            }
        }
    }

    private func finish(_ connection: NWConnection) {
        connection.cancel()
        forget(connection)
    }

    private func forget(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = nil
    }

    private func tearDown() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        isRunning = false
        signalStartGate()
    }

    private func signalStartGate() {
        startGate?.signal()
        startGate = nil
    }
}

/// Bonjour 发现：浏览 _cortex-sentinel._tcp 服务，回调当前在线端点集合
/// （每次变化全量回调，不做增量）。
final class LanPeerBrowser: @unchecked Sendable {
    private let serviceType: String
    private let queue = DispatchQueue(label: "cortex.lan.telemetry.browser")
    private var browser: NWBrowser?
    private var onChange: (@Sendable ([LanPeer]) -> Void)?
    private var resolved: [String: LanPeer] = [:]
    private var resolvers: [String: NWConnection] = [:]

    init(serviceType: String = "_cortex-sentinel._tcp") {
        self.serviceType = serviceType
    }

    func start(onChange: @escaping @Sendable ([LanPeer]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopOnQueue()
            self.onChange = onChange
            let parameters = NWParameters()
            parameters.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjour(type: self.serviceType, domain: nil), using: parameters)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.queue.async {
                    self?.apply(results)
                }
            }
            browser.start(queue: self.queue)
            self.browser = browser
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    private func stopOnQueue() {
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
        resolvers.values.forEach { $0.cancel() }
        resolvers.removeAll()
        resolved.removeAll()
        onChange = nil
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        let live = Set(results.map { Self.endpointID($0.endpoint) })
        resolved = resolved.filter { live.contains($0.key) }
        for (id, connection) in resolvers where !live.contains(id) {
            connection.cancel()
            resolvers[id] = nil
        }
        for result in results {
            let id = Self.endpointID(result.endpoint)
            if resolved[id] != nil { continue }
            if let peer = Self.peer(from: result.endpoint) {
                resolved[id] = peer
                continue
            }
            if resolvers[id] == nil {
                resolve(id, endpoint: result.endpoint)
            }
        }
        emit()
    }

    private func resolve(_ id: String, endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        resolvers[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.queue.async {
                guard let self else { return }
                switch state {
                case .ready:
                    if let remote = connection.currentPath?.remoteEndpoint,
                       let peer = Self.peer(from: remote) {
                        self.resolved[id] = peer
                        self.emit()
                    }
                    connection.cancel()
                    self.resolvers[id] = nil
                case .failed, .cancelled:
                    self.resolvers[id] = nil
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }

    private func emit() {
        var unique: [String: LanPeer] = [:]
        for peer in resolved.values {
            unique["\(peer.host):\(peer.port)"] = peer
        }
        let snapshot = unique.values.sorted { lhs, rhs in
            if lhs.host == rhs.host { return lhs.port < rhs.port }
            return lhs.host < rhs.host
        }
        onChange?(snapshot)
    }

    private static func endpointID(_ endpoint: NWEndpoint) -> String {
        String(describing: endpoint)
    }

    private static func peer(from endpoint: NWEndpoint) -> LanPeer? {
        guard case .hostPort(let host, let port) = endpoint else { return nil }
        guard case .ipv4(let address) = host else { return nil }
        return LanPeer(host: ipv4String(address), port: port.rawValue)
    }

    private static func ipv4String(_ address: IPv4Address) -> String {
        let bytes = [UInt8](address.rawValue)
        guard bytes.count == 4 else { return address.debugDescription }
        return bytes.map(String.init).joined(separator: ".")
    }
}

/// 对单个端点拉遥测：连接后发 "TELEMETRY\n"，读到 EOF 为止，返回 UTF8 JSON 字节。
/// 超时或任何失败返回 nil。
enum LanTelemetryFetcher {
    static func fetch(host: String, port: UInt16, timeout: TimeInterval = 2) async -> Data? {
        let session = FetchSession(host: host, port: port, timeout: timeout)
        return await session.run()
    }
}

/// 单次拉取的连接生命周期：超时/失败/完成后都显式 cancel，避免泄漏。
private final class FetchSession: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "cortex.lan.telemetry.fetcher")
    private var continuation: CheckedContinuation<Data?, Never>?
    private var connection: NWConnection?
    private var buffer = Data()
    private var finished = false
    private var didRequest = false

    init(host: String, port: UInt16, timeout: TimeInterval) {
        self.host = host
        self.port = port
        self.timeout = timeout
    }

    func run() async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                self.continuation = continuation
                self.open()
            }
        }
    }

    private func open() {
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.queue.async {
                self?.handle(state)
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(nil)
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            sendRequest()
        case .waiting(let error):
            if Self.isUnreachable(error) {
                finish(nil)
            }
        case .failed:
            finish(nil)
        case .cancelled:
            finish(nil)
        default:
            break
        }
    }

    private func sendRequest() {
        guard !didRequest, let connection else { return }
        didRequest = true
        connection.send(content: lanTelemetryCommand, isComplete: true, completion: .contentProcessed { [weak self] error in
            self?.queue.async {
                if error != nil {
                    self?.finish(nil)
                    return
                }
                self?.receiveMore()
            }
        })
    }

    private func receiveMore() {
        guard let connection else {
            finish(nil)
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            self?.queue.async {
                guard let self else { return }
                if error != nil {
                    self.finish(nil)
                    return
                }
                if let data {
                    self.buffer.append(data)
                }
                if isComplete {
                    self.completeReceive()
                    return
                }
                self.receiveMore()
            }
        }
    }

    private func completeReceive() {
        guard !buffer.isEmpty, String(data: buffer, encoding: .utf8) != nil else {
            finish(nil)
            return
        }
        finish(buffer)
    }

    private func finish(_ data: Data?) {
        guard !finished else { return }
        finished = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        continuation?.resume(returning: data)
        continuation = nil
    }

    private static func isUnreachable(_ error: NWError) -> Bool {
        if case .posix(let code) = error {
            return code == .ECONNREFUSED || code == .EHOSTUNREACH || code == .ENETUNREACH || code == .ECONNRESET
        }
        return false
    }
}
