import Foundation
import Network
import Security

// The bytes of the one video a server exposes. The server never sees a path, so it cannot
// be made to read anything else from the app's container.
public protocol TelegramCastByteSource: AnyObject {
    var contentType: String { get }
    var size: Int64 { get }
    // Calls completion once, on any queue, with the requested bytes or nil on failure.
    // The returned closure cancels the read.
    func read(range: Range<Int64>, completion: @escaping (Data?) -> Void) -> () -> Void
}

// Files that exist only while a stream runs: a live playlist and its segments. The source decides
// which relative paths exist, and answers nil for any other.
public protocol TelegramCastDynamicSource: AnyObject {
    // Calls completion once, on any queue. The returned closure cancels the request.
    func resource(path: String, completion: @escaping ((data: Data, contentType: String)?) -> Void) -> () -> Void
}

public enum TelegramCastHTTPRange: Equatable {
    case full
    case partial(Range<Int64>)
    case unsatisfiable

    // RFC 9110 14.1.2. A multi-range or malformed header is ignored, as the RFC allows, and
    // answered with the whole file.
    public static func parse(header: String?, size: Int64) -> TelegramCastHTTPRange {
        guard let header = header?.trimmingCharacters(in: .whitespaces) else {
            return .full
        }
        guard header.lowercased().hasPrefix("bytes=") else {
            return .full
        }
        let spec = header.dropFirst("bytes=".count)
        if spec.contains(",") {
            return .full
        }
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else {
            return .full
        }
        if parts[0].isEmpty {
            guard let suffix = Int64(parts[1]), suffix >= 0 else {
                return .full
            }
            if suffix == 0 || size == 0 {
                return .unsatisfiable
            }
            return .partial(max(0, size - suffix) ..< size)
        }
        guard let lower = Int64(parts[0]), lower >= 0 else {
            return .full
        }
        if lower >= size {
            return .unsatisfiable
        }
        if parts[1].isEmpty {
            return .partial(lower ..< size)
        }
        guard let last = Int64(parts[1]), last >= lower else {
            return .full
        }
        return .partial(lower ..< min(last, size - 1) + 1)
    }
}

// A short-lived HTTP/1.1 server for one video, reachable only through an unguessable URL.
// A Cast device cannot read the app's files, so it fetches them from here over the LAN.
// All state is confined to `queue`.
public final class TelegramCastLocalServer {
    public enum StartError: Error {
        case noLocalAddress
        case listenerFailed
    }

    private static let maxHeaderSize = 16 * 1024
    private static let maxConnections = 8
    private static let chunkSize: Int64 = 512 * 1024
    private static let requestTimeout: Double = 15.0

    private let queue = DispatchQueue(label: "org.telegram.TelegramCastLocalServer")
    private let source: TelegramCastByteSource?
    private let dynamicSource: TelegramCastDynamicSource?
    private let token: String
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var allowedClient: String?
    private var isStopped = false

    public init?(source: TelegramCastByteSource) {
        guard let token = TelegramCastLocalServer.generateToken() else {
            return nil
        }
        self.source = source
        self.dynamicSource = nil
        self.token = token
    }

    public init?(dynamicSource: TelegramCastDynamicSource) {
        guard let token = TelegramCastLocalServer.generateToken() else {
            return nil
        }
        self.source = nil
        self.dynamicSource = dynamicSource
        self.token = token
    }

    deinit {
        self.listener?.cancel()
    }

    // Nil rather than a weaker fallback: a guessable token would expose the video to the LAN.
    private static func generateToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public var path: String {
        return "/cast/\(self.token)/video"
    }

    private var dynamicRoot: String {
        return "/cast/\(self.token)/"
    }

    // host is nil to use the address of the Wi-Fi or Ethernet interface a Cast device can reach.
    // relativePath names the first file of a dynamic source.
    public func start(host: String? = nil, relativePath: String? = nil, completion: @escaping (Result<URL, StartError>) -> Void) {
        self.queue.async {
            guard let address = host ?? TelegramCastLocalServer.localNetworkAddress() else {
                completion(.failure(.noLocalAddress))
                return
            }
            let listener: NWListener
            do {
                listener = try NWListener(using: .tcp)
            } catch {
                completion(.failure(.listenerFailed))
                return
            }
            var didComplete = false
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else {
                    return
                }
                switch state {
                case .ready:
                    let path = relativePath.flatMap { self.dynamicRoot + $0 } ?? self.path
                    if !didComplete, let port = listener?.port?.rawValue, let url = URL(string: "http://\(address):\(port)\(path)") {
                        didComplete = true
                        completion(.success(url))
                    }
                case .failed:
                    if !didComplete {
                        didComplete = true
                        completion(.failure(.listenerFailed))
                    }
                    self.stopOnQueue()
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            listener.start(queue: self.queue)
        }
    }

    public func stop() {
        self.queue.async {
            self.stopOnQueue()
        }
    }

    private func stopOnQueue() {
        if self.isStopped {
            return
        }
        self.isStopped = true
        self.listener?.cancel()
        self.listener = nil
        let connections = self.connections
        self.connections.removeAll()
        for (_, connection) in connections {
            connection.close()
        }
    }

    private func accept(_ nwConnection: NWConnection) {
        if self.isStopped || self.connections.count >= TelegramCastLocalServer.maxConnections {
            nwConnection.cancel()
            return
        }
        let connection = Connection(connection: nwConnection, queue: self.queue, server: self)
        self.connections[ObjectIdentifier(connection)] = connection
        connection.start()
    }

    fileprivate func connectionClosed(_ connection: Connection) {
        self.connections.removeValue(forKey: ObjectIdentifier(connection))
    }

    private static func clientAddress(_ connection: NWConnection) -> String? {
        if case let .hostPort(host, _) = connection.endpoint {
            switch host {
            case let .ipv4(address):
                return "\(address)"
            case let .ipv6(address):
                return "\(address)"
            default:
                return "\(host)"
            }
        }
        return nil
    }

    private static func tokensMatch(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = Array(lhs.utf8)
        let rhs = Array(rhs.utf8)
        if lhs.count != rhs.count {
            return false
        }
        var difference: UInt8 = 0
        for i in 0 ..< lhs.count {
            difference |= lhs[i] ^ rhs[i]
        }
        return difference == 0
    }

    fileprivate enum Response {
        case error(status: String)
        case body(status: String, range: Range<Int64>?, headOnly: Bool)
        case dynamic(path: String, source: TelegramCastDynamicSource, headOnly: Bool)
        case preflight
    }

    fileprivate func response(method: String, target: String, rangeHeader: String?, connection: NWConnection) -> Response {
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let authorized: Bool
        if self.dynamicSource != nil {
            authorized = TelegramCastLocalServer.tokensMatch(String(path.prefix(self.dynamicRoot.count)), self.dynamicRoot)
        } else {
            authorized = TelegramCastLocalServer.tokensMatch(path, self.path)
        }
        guard authorized else {
            return .error(status: "404 Not Found")
        }
        // A receiver's script may ask permission first when it sends custom headers.
        if method == "OPTIONS" && self.dynamicSource != nil {
            return .preflight
        }
        // The URL is a bearer secret sent in clear on the LAN, so the first device to use it
        // keeps it: a client that sniffed the URL cannot then read the video.
        let client = TelegramCastLocalServer.clientAddress(connection)
        if let allowedClient = self.allowedClient {
            if client != allowedClient {
                return .error(status: "403 Forbidden")
            }
        } else {
            self.allowedClient = client
        }
        guard method == "GET" || method == "HEAD" else {
            return .error(status: "405 Method Not Allowed")
        }
        if let dynamicSource = self.dynamicSource {
            return .dynamic(path: String(path.dropFirst(self.dynamicRoot.count)), source: dynamicSource, headOnly: method == "HEAD")
        }
        guard let source = self.source else {
            return .error(status: "404 Not Found")
        }
        switch TelegramCastHTTPRange.parse(header: rangeHeader, size: source.size) {
        case .full:
            return .body(status: "200 OK", range: nil, headOnly: method == "HEAD")
        case let .partial(range):
            return .body(status: "206 Partial Content", range: range, headOnly: method == "HEAD")
        case .unsatisfiable:
            return .error(status: "416 Range Not Satisfiable")
        }
    }

    fileprivate var byteSource: TelegramCastByteSource? {
        return self.source
    }

    fileprivate final class Connection {
        private let connection: NWConnection
        private let queue: DispatchQueue
        private weak var server: TelegramCastLocalServer?
        private var buffer = Data()
        private var cancelRead: (() -> Void)?
        private var timeout: DispatchWorkItem?
        private var isClosed = false

        init(connection: NWConnection, queue: DispatchQueue, server: TelegramCastLocalServer) {
            self.connection = connection
            self.queue = queue
            self.server = server
        }

        func start() {
            self.connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled:
                    self?.close()
                default:
                    break
                }
            }
            self.connection.start(queue: self.queue)
            let timeout = DispatchWorkItem { [weak self] in
                self?.close()
            }
            self.timeout = timeout
            self.queue.asyncAfter(deadline: .now() + TelegramCastLocalServer.requestTimeout, execute: timeout)
            self.receive()
        }

        func close() {
            if self.isClosed {
                return
            }
            self.isClosed = true
            self.timeout?.cancel()
            self.cancelRead?()
            self.cancelRead = nil
            self.connection.cancel()
            self.server?.connectionClosed(self)
        }

        private func receive() {
            self.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
                guard let self, !self.isClosed else {
                    return
                }
                if let data {
                    self.buffer.append(data)
                }
                if let headerEnd = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                    self.timeout?.cancel()
                    self.handle(header: self.buffer.subdata(in: 0 ..< headerEnd.lowerBound))
                } else if self.buffer.count > TelegramCastLocalServer.maxHeaderSize {
                    self.sendError(status: "431 Request Header Fields Too Large")
                } else if isComplete || error != nil {
                    self.close()
                } else {
                    self.receive()
                }
            }
        }

        private func handle(header: Data) {
            guard let server = self.server, let text = String(data: header, encoding: .utf8) else {
                self.sendError(status: "400 Bad Request")
                return
            }
            let lines = text.components(separatedBy: "\r\n")
            let requestLine = lines[0].split(separator: " ")
            guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
                self.sendError(status: "400 Bad Request")
                return
            }
            var rangeHeader: String?
            for line in lines.dropFirst() {
                if let separator = line.firstIndex(of: ":"), line[..<separator].lowercased() == "range" {
                    rangeHeader = String(line[line.index(after: separator)...])
                }
            }
            switch server.response(method: String(requestLine[0]), target: String(requestLine[1]), rangeHeader: rangeHeader, connection: self.connection) {
            case let .error(status):
                self.sendError(status: status)
            case let .body(status, range, headOnly):
                if let source = server.byteSource {
                    self.sendBody(status: status, range: range, headOnly: headOnly, source: source)
                } else {
                    self.sendError(status: "404 Not Found")
                }
            case let .dynamic(path, source, headOnly):
                self.sendDynamic(path: path, source: source, headOnly: headOnly)
            case .preflight:
                let headers = "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, HEAD, OPTIONS\r\nAccess-Control-Allow-Headers: *\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                self.connection.send(content: Data(headers.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                    self?.close()
                })
            }
        }

        private func sendDynamic(path: String, source: TelegramCastDynamicSource, headOnly: Bool) {
            self.cancelRead = source.resource(path: path) { [weak self] resource in
                guard let self else {
                    return
                }
                self.queue.async {
                    self.cancelRead = nil
                    guard !self.isClosed else {
                        return
                    }
                    guard let resource else {
                        self.sendError(status: "404 Not Found")
                        return
                    }
                    var headers = "HTTP/1.1 200 OK\r\n"
                    headers += "Content-Type: \(resource.contentType)\r\n"
                    headers += "Content-Length: \(resource.data.count)\r\n"
                    headers += "Cache-Control: no-store\r\n"
                    // Cast fetches HLS from script, which needs this. The URL's token and the
                    // client lock remain the access control.
                    headers += "Access-Control-Allow-Origin: *\r\n"
                    headers += "Connection: close\r\n\r\n"
                    var response = Data(headers.utf8)
                    if !headOnly {
                        response.append(resource.data)
                    }
                    self.connection.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                        self?.close()
                    })
                }
            }
        }

        private func sendError(status: String) {
            var headers = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n"
            if status.hasPrefix("405") {
                headers += "Allow: GET, HEAD\r\n"
            }
            if status.hasPrefix("416"), let size = self.server?.byteSource?.size {
                headers += "Content-Range: bytes */\(size)\r\n"
            }
            self.connection.send(content: Data((headers + "\r\n").utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                self?.close()
            })
        }

        private func sendBody(status: String, range: Range<Int64>?, headOnly: Bool, source: TelegramCastByteSource) {
            let size = source.size
            let bodyRange = range ?? (0 ..< size)
            var headers = "HTTP/1.1 \(status)\r\n"
            headers += "Content-Type: \(source.contentType)\r\n"
            headers += "Content-Length: \(bodyRange.count)\r\n"
            headers += "Accept-Ranges: bytes\r\n"
            headers += "Cache-Control: no-store\r\n"
            headers += "Connection: close\r\n"
            if range != nil {
                headers += "Content-Range: bytes \(bodyRange.lowerBound)-\(bodyRange.upperBound - 1)/\(size)\r\n"
            }
            let headerData = Data((headers + "\r\n").utf8)
            if headOnly || bodyRange.isEmpty {
                self.connection.send(content: headerData, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                    self?.close()
                })
                return
            }
            self.connection.send(content: headerData, completion: .contentProcessed { [weak self] error in
                guard let self else {
                    return
                }
                if error != nil {
                    self.close()
                } else {
                    self.sendChunk(from: bodyRange.lowerBound, upperBound: bodyRange.upperBound, source: source)
                }
            })
        }

        // One chunk at a time, the next only after the network took the last: a device that
        // buffers ahead and stops reading then holds at most one chunk in memory.
        private func sendChunk(from lowerBound: Int64, upperBound: Int64, source: TelegramCastByteSource) {
            if self.isClosed {
                return
            }
            if lowerBound >= upperBound {
                self.connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                    self?.close()
                })
                return
            }
            let chunkEnd = min(upperBound, lowerBound + TelegramCastLocalServer.chunkSize)
            self.cancelRead = source.read(range: lowerBound ..< chunkEnd) { [weak self] data in
                guard let self else {
                    return
                }
                self.queue.async {
                    self.cancelRead = nil
                    guard !self.isClosed else {
                        return
                    }
                    guard let data, Int64(data.count) == chunkEnd - lowerBound else {
                        // The headers are gone, so an error status is impossible; closing
                        // short of Content-Length is how the client learns of the failure.
                        self.close()
                        return
                    }
                    self.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                        guard let self else {
                            return
                        }
                        if error != nil {
                            self.close()
                        } else {
                            self.sendChunk(from: chunkEnd, upperBound: upperBound, source: source)
                        }
                    })
                }
            }
        }
    }

    // The IPv4 address of the first active Wi-Fi or Ethernet interface. Cellular and VPN
    // interfaces are skipped: a Cast device could not reach them.
    public static func localNetworkAddress() -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else {
            return nil
        }
        defer {
            freeifaddrs(addresses)
        }
        var candidates: [(name: String, address: String)] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current {
            defer {
                current = interface.pointee.ifa_next
            }
            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else {
                continue
            }
            guard let socketAddress = interface.pointee.ifa_addr, socketAddress.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            let name = String(cString: interface.pointee.ifa_name)
            guard name.hasPrefix("en") else {
                continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(socketAddress, socklen_t(socketAddress.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                candidates.append((name, String(cString: host)))
            }
        }
        return candidates.sorted(by: { $0.name.count != $1.name.count ? $0.name.count < $1.name.count : $0.name < $1.name }).first?.address
    }
}
