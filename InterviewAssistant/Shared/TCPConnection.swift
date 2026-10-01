import Foundation
import Network
import Observation
#if canImport(Darwin)
import Darwin
#endif

enum DirectorMode: String, Codable, Sendable {
    case ai
    case director
}

struct DirectorPacket: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case hello, question, answer, mode, snapshot
    }

    var kind: Kind
    var questionID: String? = nil
    var text: String? = nil
    var mode: DirectorMode? = nil
    var hostBoardOpen: Bool? = nil
    var createdAt: Date = .now

    static func answer(_ text: String, questionID: String?) -> DirectorPacket {
        DirectorPacket(kind: .answer, questionID: questionID, text: text)
    }
}

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
    var onPacket: ((DirectorPacket) -> Void)?

    private var connection: NWConnection?
    private var buffer = Data()
    private let port: UInt16 = 9999
    private var reconnectTask: Task<Void, Never>?
    private var reconnectHost = ""
    private var reconnectMode: Mode = .receiver
    private var allowsReconnect = false

    func connect(host: String, mode: Mode) {
        disconnect()
        let cleanHost = host.sanitizedIPAddressInput
        guard !cleanHost.isEmpty else {
            statusText = "本地模式"
            return
        }
        let endpoint = NWEndpoint.Host(cleanHost)
        reconnectHost = cleanHost
        reconnectMode = mode
        allowsReconnect = true
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
                    if mode == .sender {
                        self.send(DirectorPacket(kind: .hello))
                    }
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

    func send(_ packet: DirectorPacket) {
        guard let data = try? JSONEncoder.director.encode(packet),
              let line = String(data: data, encoding: .utf8) else { return }
        sendLine(line)
    }

    func disconnect() {
        allowsReconnect = false
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
                            if let data = line.data(using: .utf8),
                               let packet = try? JSONDecoder.director.decode(DirectorPacket.self, from: data) {
                                self.onPacket?(packet)
                            } else {
                                self.onLine?(line)
                            }
                        }
                    }
                }
                if !isComplete {
                    self.receive()
                } else if self.allowsReconnect, !self.reconnectHost.isEmpty {
                    self.isConnected = false
                    self.statusText = "disconnected"
                    self.scheduleReconnect(host: self.reconnectHost, mode: self.reconnectMode)
                }
            }
        }
    }

    private func scheduleReconnect(host: String, mode: Mode) {
        guard allowsReconnect else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run {
                guard let self, self.allowsReconnect else { return }
                self.connect(host: host, mode: mode)
            }
        }
    }
}

@MainActor
@Observable
final class TCPLineServer {
    var statusText = "disconnected"
    var isRunning = false
    var clientCount = 0
    var onPacket: ((DirectorPacket) -> Void)?
    var stateProvider: (() -> DirectorPacket)?

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let port: UInt16 = 9999
    private var restartTask: Task<Void, Never>?

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
                        self.scheduleRestart()
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

    func send(_ packet: DirectorPacket) {
        guard let data = try? JSONEncoder.director.encode(packet),
              let line = String(data: data, encoding: .utf8) else { return }
        sendLine(line)
    }

    func stop() {
        restartTask?.cancel()
        restartTask = nil
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections = []
        clientCount = 0
        isRunning = false
    }

    private func scheduleRestart() {
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.start() }
        }
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
                    self.receiveRequest(on: connection, buffer: Data())
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

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak connection] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, let connection else { return }
                var accumulated = buffer
                if let data { accumulated.append(data) }

                if accumulated.starts(with: Data("GET ".utf8)) || accumulated.starts(with: Data("POST ".utf8)) {
                    if self.handleHTTPRequest(accumulated, on: connection) { return }
                } else {
                    while let range = accumulated.firstRange(of: Data("\n".utf8)) {
                        let lineData = accumulated[..<range.lowerBound]
                        accumulated.removeSubrange(..<range.upperBound)
                        if let packet = try? JSONDecoder.director.decode(DirectorPacket.self, from: Data(lineData)) {
                            self.onPacket?(packet)
                        }
                    }
                }

                if !isComplete && error == nil {
                    self.receiveRequest(on: connection, buffer: accumulated)
                }
            }
        }
    }

    private func handleHTTPRequest(_ data: Data, on connection: NWConnection) -> Bool {
        guard let text = String(data: data, encoding: .utf8),
              let headerRange = text.range(of: "\r\n\r\n") else { return false }
        let header = String(text[..<headerRange.lowerBound])
        let first = header.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return false }
        let method = String(first[0])
        let path = String(first[1])
        let contentLength = header.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "0") } ?? 0
        let bodyStart = headerRange.upperBound
        let body = String(text[bodyStart...])
        guard body.utf8.count >= contentLength else { return false }

        if method == "GET" && path == "/" {
            sendHTTP(200, contentType: "text/html; charset=utf-8", body: Self.controllerWebPage, on: connection)
        } else if method == "GET" && path == "/state" {
            let packet = stateProvider?() ?? DirectorPacket(kind: .snapshot, mode: .director, hostBoardOpen: false)
            let payload = (try? JSONEncoder.director.encode(packet)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            sendHTTP(200, contentType: "application/json", body: payload, on: connection)
        } else if method == "POST" && path == "/send",
                  let json = body.prefix(contentLength).data(using: .utf8),
                  let packet = try? JSONDecoder.director.decode(DirectorPacket.self, from: json) {
            onPacket?(packet)
            sendHTTP(200, contentType: "application/json", body: "{\"ok\":true}", on: connection)
        } else {
            sendHTTP(404, contentType: "text/plain", body: "Not found", on: connection)
        }
        return true
    }

    private func sendHTTP(_ status: Int, contentType: String, body: String, on connection: NWConnection) {
        let bodyData = Data(body.utf8)
        let reason = status == 200 ? "OK" : "Not Found"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(bodyData.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(bodyData)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static let controllerWebPage = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>Director Mode</title>
    <style>*{box-sizing:border-box}body{margin:0;background:#f7f8fb;color:#111;font:16px -apple-system,BlinkMacSystemFont,sans-serif}.wrap{max-width:760px;margin:auto;padding:24px}h1{font-size:34px}.status{color:#ef3434;font-weight:700}.card{background:#fff;border-radius:16px;padding:20px;margin:16px 0;box-shadow:0 8px 30px #0000000d}.q{min-height:110px;font-size:20px;white-space:pre-wrap}.nav{display:flex;justify-content:space-between;align-items:center}textarea{width:100%;min-height:180px;border:1px solid #ddd;border-radius:12px;padding:14px;font:16px ui-monospace,monospace}button{border:0;border-radius:10px;background:#111;color:#fff;padding:12px 22px;font-weight:700}.muted{color:#777;font-size:13px}</style></head>
    <body><main class="wrap"><h1>Director Mode</h1><div id="status" class="status">Connecting…</div><section class="card"><div class="nav"><button onclick="move(-1)">‹</button><b>Question</b><button onclick="move(1)">›</button></div><p id="question" class="q"></p><div id="count" class="muted"></div></section><section class="card"><textarea id="answer" placeholder="Send Markdown content…"></textarea><div class="nav"><span class="muted">Markdown supported</span><button onclick="sendAnswer()">Send</button></div></section></main>
    <script>let history=[],index=-1,last='',mode='director',boardOpen=false;async function refresh(){try{let s=await(await fetch('/state',{cache:'no-store'})).json();mode=s.mode||'director';boardOpen=s.hostBoardOpen===true;document.getElementById('status').textContent=boardOpen?(mode==='ai'?'Host opened the prompt board · AI mode':'Host opened the prompt board · Director mode'):'Host closed the prompt board';if(s.questionID&&s.questionID!==last){last=s.questionID;history.push({id:s.questionID,text:s.text||''});index=history.length-1;render()}}catch(e){document.getElementById('status').textContent='Disconnected'}}function render(){let q=history[index];document.getElementById('question').textContent=q?.text||'';document.getElementById('count').textContent=history.length?`${index+1} / ${history.length}`:''}function move(n){index=Math.max(0,Math.min(history.length-1,index+n));render()}async function sendAnswer(){if(!boardOpen){alert('Host closed the prompt board');return}if(mode==='ai'){alert('Host is in AI mode');return}let q=history[index],v=document.getElementById('answer').value.trim();if(!v)return;let d=new Date().toISOString().split('.')[0]+'Z';await fetch('/send',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({kind:'answer',questionID:q?.id,text:v,createdAt:d})});document.getElementById('answer').value=''}setInterval(refresh,800);refresh()</script></body></html>
    """
}

private extension JSONEncoder {
    static var director: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var director: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
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
        let addresses = allAddresses()
        if let wifi = addresses.first(where: { $0.interface == "en0" || $0.interface == "en1" }) {
            return wifi.ip
        }
        return addresses.first(where: {
            !$0.interface.hasPrefix("utun") &&
            !$0.interface.hasPrefix("awdl") &&
            !$0.interface.hasPrefix("llw") &&
            !$0.interface.hasPrefix("bridge") &&
            ($0.ip.hasPrefix("192.168.") || $0.ip.hasPrefix("10.") || $0.ip.hasPrefix("172."))
        })?.ip
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
