import Foundation
import Network
import Observation
#if canImport(Darwin)
import Darwin
#endif

@MainActor
@Observable
final class TCPLineConnection {
    enum Mode {
        case sender
        case receiver
    }

    var statusText = "disconnected"
    var isConnected = false
    var onLine: ((String) -> Void)?

    private var connection: NWConnection?
    private var buffer = Data()
    private let port: UInt16 = 9999
    private var reconnectTask: Task<Void, Never>?

    func connect(host: String, mode: Mode) {
        disconnect()
        let cleanHost = host.sanitizedIPAddressInput
        guard !cleanHost.isEmpty else {
            statusText = "本地模式"
            return
        }
        let endpoint = NWEndpoint.Host(cleanHost)
        let connection = NWConnection(host: endpoint, port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        self.connection = connection
        statusText = "连接 \(cleanHost)..."
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isConnected = true
                    self.statusText = mode == .sender ? "connected" : "IP 接收中"
                    self.receive()
                case .failed, .waiting:
                    self.isConnected = false
                    self.statusText = "disconnected"
                    self.scheduleReconnect(host: cleanHost, mode: mode)
                case .cancelled:
                    self.isConnected = false
                default:
                    break
                }
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    func sendLine(_ text: String) {
        let data = Data((text + "\n").utf8)
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        connection?.cancel()
        connection = nil
        isConnected = false
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, _ in
            Task { @MainActor in
                guard let self else { return }
                if let data {
                    self.buffer.append(data)
                    while let range = self.buffer.firstRange(of: Data("\n".utf8)) {
                        let lineData = self.buffer[..<range.lowerBound]
                        self.buffer.removeSubrange(..<range.upperBound)
                        if let line = String(data: lineData, encoding: .utf8), !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.onLine?(line)
                        }
                    }
                }
                if !isComplete { self.receive() }
            }
        }
    }

    private func scheduleReconnect(host: String, mode: Mode) {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run { self?.connect(host: host, mode: mode) }
        }
    }
}

@MainActor
@Observable
final class TCPLineServer {
    var statusText = "disconnected"
    var isRunning = false
    var clientCount = 0

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let port: UInt16 = 9999

    func start() {
        stop()
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.statusText = "listening"
                    case .failed:
                        self.isRunning = false
                        self.statusText = "disconnected"
                    case .cancelled:
                        self.isRunning = false
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.accept(connection)
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        } catch {
            statusText = error.localizedDescription
        }
    }

    func sendLine(_ text: String) {
        let data = Data((text + "\n").utf8)
        let liveConnections = connections
        for connection in liveConnections {
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections = []
        clientCount = 0
        isRunning = false
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor in
                guard let self, let connection else { return }
                if case .ready = state {
                    if !self.connections.contains(where: { $0 === connection }) {
                        self.connections.append(connection)
                    }
                    self.clientCount = self.connections.count
                    self.statusText = "listening"
                }
                if case .waiting(let error) = state {
                    self.statusText = error.localizedDescription
                }
                if case .cancelled = state {
                    self.connections.removeAll { $0 === connection }
                    self.clientCount = self.connections.count
                }
                if case .failed = state {
                    self.connections.removeAll { $0 === connection }
                    self.clientCount = self.connections.count
                }
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }
}

enum LocalNetworkInfo {
    struct Address: Identifiable {
        let interface: String
        let ip: String
        var id: String { "\(interface)-\(ip)" }
    }

    static func preferredIPAddress() -> String {
        wifiIPAddress() ?? "未检测到 Wi-Fi IP"
    }

    static func wifiIPAddress() -> String? {
        allAddresses().first { $0.interface == "en0" }?.ip
    }

    static func allIPAddresses() -> [String] {
        allAddresses().map(\.ip)
    }

    static func allAddresses() -> [Address] {
        var addresses: [Address] = []
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            let name = String(cString: interface.ifa_name)
            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            if result == 0 {
                if let end = hostname.firstIndex(of: 0) {
                    let ip = String(decoding: hostname[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    addresses.append(Address(interface: name, ip: ip))
                }
            }
        }
        return addresses
    }
}

private extension String {
    var sanitizedIPAddressInput: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "，,.;； "))
    }
}
