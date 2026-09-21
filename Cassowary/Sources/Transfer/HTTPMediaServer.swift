// Copyright (c) 2026, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the OpenEmu Team nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import Foundation
import Network

/// One request, as it came off the wire.
struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data
    /// Large uploads are streamed here instead of into memory. The handler
    /// owns the file and should move or delete it.
    var bodyFileURL: URL?

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

/// One response, ready to be written.
struct HTTPResponse {
    var status: Int
    var reason: String
    var headers: [String: String] = [:]
    var body: Data = Data()
    /// A file to send instead of `body`. A range of it is sent when the
    /// request asked for one.
    var fileURL: URL?
    var fileOffset: Int64 = 0
    var fileLength: Int64?

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        var response = HTTPResponse(status: status, reason: Self.reason(for: status))
        response.headers["Content-Type"] = "application/json"
        response.body = (try? TransferProtocol.encoder.encode(value)) ?? Data()
        return response
    }

    static func text(_ message: String, status: Int = 200) -> HTTPResponse {
        var response = HTTPResponse(status: status, reason: Self.reason(for: status))
        response.headers["Content-Type"] = "text/plain; charset=utf-8"
        response.body = Data(message.utf8)
        return response
    }

    static func empty(status: Int) -> HTTPResponse {
        HTTPResponse(status: status, reason: Self.reason(for: status))
    }

    static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 416: return "Range Not Satisfiable"
        case 500: return "Internal Server Error"
        default:  return "OK"
        }
    }
}

/// A small HTTP/1.1 server, enough for the transfer endpoints.
///
/// It is deliberately not a general-purpose server: one request per
/// connection, no TLS, no chunked bodies. On a home network with a paired
/// device that is all the protocol needs, and it keeps the parsing small
/// enough to trust.
final class HTTPMediaServer {

    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let queue = DispatchQueue(label: "org.cassowary.media-server")
    private var listener: NWListener?
    private let handler: Handler

    /// The port the server actually got. Zero until it is listening.
    private(set) var port: UInt16 = 0

    /// Request bodies bigger than this go to a file instead of memory.
    private static let largeBodyThreshold = 4 * 1024 * 1024

    /// The Bonjour name this host advertises.
    var serviceName: String = "Cassowary"

    /// What the host says about itself in its Bonjour record, so a browser
    /// can show a name without connecting.
    var serviceTXT: [String: String] = [:]

    private(set) var isRunning = false

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start(preferredPort: UInt16? = nil) throws {
        guard !isRunning else { return }

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        if let preferredPort, let nwPort = NWEndpoint.Port(rawValue: preferredPort) {
            listener = try NWListener(using: parameters, on: nwPort)
        } else {
            listener = try NWListener(using: parameters)
        }

        listener.service = NWListener.Service(name: serviceName,
                                              type: TransferProtocol.serviceType,
                                              domain: nil,
                                              txtRecord: serviceTXT.isEmpty ? nil : PeerBrowser.txtData(serviceTXT))

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = listener.port?.rawValue ?? 0
                self.isRunning = true
                // The port is only known once the listener is up, so this is
                // the line to read when a test needs to know where to look.
                NSLog("[Cassowary] sharing listening on port %d", self.port)
            case .failed(let error):
                NSLog("[Cassowary] media server failed: %@", error.localizedDescription)
                self.isRunning = false
            case .cancelled:
                self.isRunning = false
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        port = 0
    }

    // MARK: - Connections

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHeaders(on: connection, buffer: Data())
    }

    private func readHeaders(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var buffer = buffer
            if let data { buffer.append(data) }

            if let error {
                NSLog("[Cassowary] media server read error: %@", error.localizedDescription)
                connection.cancel()
                return
            }

            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer[..<headerEnd.lowerBound]
                var rest = Data(buffer[headerEnd.upperBound...])

                guard let head = String(data: headerData, encoding: .utf8),
                      let request = Self.parseHead(head) else {
                    Self.send(.text("Bad Request", status: 400), on: connection)
                    return
                }

                // A body that arrived with the headers needs no more reading.
                let contentLength = Int(request.headers["content-length"] ?? "0") ?? 0
                if contentLength <= 0 {
                    self.respond(to: request, on: connection)
                    return
                }

                if contentLength > Self.largeBodyThreshold {
                    // A whole game: write it to a file rather than into
                    // memory, so a disc image does not arrive all at once.
                    let uploadURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("cassowary-upload-\(UUID().uuidString)")
                    FileManager.default.createFile(atPath: uploadURL.path, contents: nil)
                    guard let handle = try? FileHandle(forWritingTo: uploadURL) else {
                        Self.send(.text("Server cannot hold the upload", status: 500), on: connection)
                        return
                    }

                    let alreadyRead = rest.count
                    if !rest.isEmpty {
                        try? handle.write(contentsOf: rest)
                        rest = Data()
                    }

                    if alreadyRead >= contentLength {
                        try? handle.close()
                        var complete = request
                        complete.bodyFileURL = uploadURL
                        self.respond(to: complete, on: connection)
                        return
                    }

                    self.readBody(on: connection,
                                  request: request,
                                  buffer: Data(),
                                  remaining: contentLength - alreadyRead,
                                  fileURL: uploadURL,
                                  handle: handle)
                    return
                }

                if rest.count >= contentLength {
                    var complete = request
                    complete.body = rest.prefix(contentLength)
                    self.respond(to: complete, on: connection)
                    return
                }

                self.readBody(on: connection,
                              request: request,
                              buffer: rest,
                              remaining: contentLength - rest.count,
                              fileURL: nil,
                              handle: nil)
                return
            }

            if isComplete {
                connection.cancel()
                return
            }

            self.readHeaders(on: connection, buffer: buffer)
        }
    }

    private func readBody(on connection: NWConnection,
                          request: HTTPRequest,
                          buffer: Data,
                          remaining: Int,
                          fileURL: URL?,
                          handle: FileHandle?) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4 * 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var buffer = buffer
            var remaining = remaining

            if let data {
                remaining -= data.count
                if let handle {
                    try? handle.write(contentsOf: data)
                } else {
                    buffer.append(data)
                }
            }

            if let error {
                NSLog("[Cassowary] media server body error: %@", error.localizedDescription)
                try? handle?.close()
                if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
                connection.cancel()
                return
            }

            if remaining <= 0 {
                try? handle?.close()

                var complete = request
                if let fileURL {
                    complete.bodyFileURL = fileURL
                } else if buffer.count > 0 {
                    complete.body = buffer.prefix(remaining < 0 ? buffer.count + remaining : buffer.count)
                }
                self.respond(to: complete, on: connection)
                return
            }

            if isComplete {
                try? handle?.close()
                if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
                connection.cancel()
                return
            }

            self.readBody(on: connection,
                          request: request,
                          buffer: buffer,
                          remaining: remaining,
                          fileURL: fileURL,
                          handle: handle)
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        Task {
            let response = await handler(request)
            Self.send(response, on: connection)
        }
    }

    // MARK: - Writing

    private static func send(_ response: HTTPResponse, on connection: NWConnection) {
        var headers = response.headers
        headers["Connection"] = "close"
        headers["Server"] = "Cassowary"

        if let fileURL = response.fileURL {
            sendFile(response, fileURL: fileURL, headers: headers, on: connection)
            return
        }

        headers["Content-Length"] = String(response.body.count)

        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"

        var payload = Data(head.utf8)
        payload.append(response.body)

        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func sendFile(_ response: HTTPResponse,
                                 fileURL: URL,
                                 headers: [String: String],
                                 on connection: NWConnection) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            send(.empty(status: 404), on: connection)
            return
        }

        let total = Int64((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0) ?? 0
        let start = response.fileOffset
        let length = min(response.fileLength ?? (total - start), total - start)

        var headers = headers
        headers["Content-Length"] = String(length)
        headers["Accept-Ranges"] = "bytes"

        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"

        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })

        if start > 0 {
            try? handle.seek(toOffset: UInt64(start))
        }

        var remaining = length
        func pump() {
            guard remaining > 0 else {
                try? handle.close()
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() })
                return
            }

            let chunkSize = Int(min(remaining, 4 * 1024 * 1024))
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                try? handle.close()
                connection.cancel()
                return
            }
            remaining -= Int64(chunk.count)

            connection.send(content: chunk, completion: .contentProcessed { error in
                if error != nil {
                    try? handle.close()
                    connection.cancel()
                    return
                }
                pump()
            })
        }
        pump()
    }

    // MARK: - Parsing

    private static func parseHead(_ head: String) -> HTTPRequest? {
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        let target = String(parts[1])

        var path = target
        var query: [String: String] = [:]
        if let mark = target.firstIndex(of: "?") {
            path = String(target[..<mark])
            let queryString = String(target[target.index(after: mark)...])
            for pair in queryString.split(separator: "&") {
                let halves = pair.split(separator: "=", maxSplits: 1)
                let name = String(halves[0]).removingPercentEncoding ?? String(halves[0])
                let value = halves.count > 1 ? (String(halves[1]).removingPercentEncoding ?? String(halves[1])) : ""
                query[name] = value
            }
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        return HTTPRequest(method: method,
                           path: path.removingPercentEncoding ?? path,
                           query: query,
                           headers: headers,
                           body: Data())
    }
}

/// A file range, as the client asked for it.
struct ByteRange {
    var start: Int64
    var end: Int64
}

enum RangeHeader {
    /// Parses `bytes=start-end`, including the open-ended forms.
    static func parse(_ value: String?, totalSize: Int64) -> ByteRange? {
        guard let value, value.hasPrefix("bytes=") else { return nil }
        let spec = value.dropFirst("bytes=".count)
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        if parts[0].isEmpty {
            // bytes=-N: the last N bytes.
            guard let length = Int64(parts[1]) else { return nil }
            return ByteRange(start: max(0, totalSize - length), end: totalSize - 1)
        }

        guard let start = Int64(parts[0]) else { return nil }
        let end = parts[1].isEmpty ? totalSize - 1 : (Int64(parts[1]) ?? totalSize - 1)
        guard start <= end, start < totalSize else { return nil }
        return ByteRange(start: start, end: min(end, totalSize - 1))
    }
}
