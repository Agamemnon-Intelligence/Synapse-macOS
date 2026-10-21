import Foundation
import Network
import UniformTypeIdentifiers

struct HTTPRequest {
    var method: String
    var path: String
    var query: String
    var headers: [String: String]
    var body: Data
}

/// Writes a response back on a connection. Supports both full and streamed bodies.
final class HTTPResponder: @unchecked Sendable {
    private let connection: NWConnection
    init(_ c: NWConnection) { connection = c }

    static func reason(_ s: Int) -> String {
        [200: "OK", 204: "No Content", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed", 500: "Internal Server Error", 502: "Bad Gateway"][s] ?? "OK"
    }

    func send(status: Int, headers: [String: String] = [:], body: Data) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var h = headers
        h["Content-Length"] = String(body.count)
        h["Connection"] = "close"
        h["Access-Control-Allow-Origin"] = "*"
        for (k, v) in h { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { [connection] _ in connection.cancel() })
    }

    func sendJSON(status: Int = 200, _ obj: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        send(status: status, headers: ["Content-Type": "application/json"], body: data)
    }

    func beginStream(status: Int, contentType: String) {
        let head = "HTTP/1.1 \(status) \(Self.reason(status))\r\nContent-Type: \(contentType)\r\nCache-Control: no-cache\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
    }

    func write(_ data: Data) { connection.send(content: data, completion: .contentProcessed { _ in }) }

    func end() { connection.send(content: nil, isComplete: true, completion: .contentProcessed { [connection] _ in connection.cancel() }) }
}

final class HTTPServer: @unchecked Sendable {
    let port: UInt16
    private var listener: NWListener?
    private let handler: @Sendable (HTTPRequest, HTTPResponder) async -> Void
    private let queue = DispatchQueue(label: "synapse.http")

    init(port: UInt16, handler: @escaping @Sendable (HTTPRequest, HTTPResponder) async -> Void) {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        listener = l
    }

    func stop() { listener?.cancel(); listener = nil }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = Self.parse(buf) {
                let responder = HTTPResponder(c)
                let handler = self.handler
                Task { await handler(req, responder) }
            } else if complete || error != nil || buf.count > 50_000_000 {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    /// Returns a request once headers and the full body have arrived.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<sep.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            if let i = l.firstIndex(of: ":") {
                headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[sep.upperBound...]
        guard body.count >= length else { return nil }
        let target = String(first[1])
        let parts = target.split(separator: "?", maxSplits: 1)
        return HTTPRequest(method: String(first[0]), path: parts.first.map(String.init)?.removingPercentEncoding ?? "/",
                           query: parts.count > 1 ? String(parts[1]) : "", headers: headers, body: Data(body.prefix(length)))
    }

    /// Serves files from a folder.
    static func staticHandler(root: URL) -> @Sendable (HTTPRequest, HTTPResponder) async -> Void {
        return { req, res in
            var rel = req.path
            if rel.hasSuffix("/") { rel += "index.html" }
            let file = root.appendingPathComponent(String(rel.drop(while: { $0 == "/" }))).standardizedFileURL
            guard file.path.hasPrefix(root.standardizedFileURL.path) else {
                res.send(status: 404, body: Data("Not found".utf8)); return
            }
            var isDir: ObjCBool = false
            var target = file
            if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), isDir.boolValue {
                target = file.appendingPathComponent("index.html")
            }
            guard let data = try? Data(contentsOf: target) else {
                res.send(status: 404, headers: ["Content-Type": "text/html"], body: Data("<h1>404</h1><p>\(req.path) not found</p>".utf8))
                return
            }
            let mime = UTType(filenameExtension: target.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            res.send(status: 200, headers: ["Content-Type": mime + (mime.hasPrefix("text/") ? "; charset=utf-8" : "")], body: data)
        }
    }
}
