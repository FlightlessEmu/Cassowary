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

/// A host the TV can talk to.
struct MediaHost: Identifiable, Hashable {
    var deviceID: String
    var name: String
    /// The address Bonjour resolved to, or one typed in by hand.
    var address: String
    var port: UInt16
    var platformName: String

    var id: String { deviceID }

    var baseURL: URL? { URL(string: "http://\(address):\(port)") }
}

enum MediaClientError: LocalizedError {
    case noAddress
    case badResponse(String)
    case http(Int)
    case notPaired
    case cancelled
    case shortRead

    var errorDescription: String? {
        switch self {
        case .noAddress:          return "That device has no address to reach it at."
        case .badResponse(let why): return "Unexpected answer: \(why)"
        case .http(let status):    return "The other device answered with error \(status)."
        case .notPaired:           return "This device is not allowed in. Pair it again from the phone."
        case .cancelled:           return "The transfer was cancelled."
        case .shortRead:           return "The transfer ended early."
        }
    }
}

/// Talks to one host: the library, the files, and the saves.
///
/// It is the client half of the protocol and also implements `SavePeer`, so
/// the same save-sync rules run whether the other end is a phone or a TV.
final class MediaClient: SavePeer {

    let host: MediaHost
    let token: String?

    private let session: URLSession

    init(host: MediaHost, token: String?) {
        self.host = host
        self.token = token

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    var peerDeviceID: String { host.deviceID }

    // MARK: - The simple calls

    func info() async throws -> TransferProtocol.HostInfo {
        try await getJSON(TransferProtocol.Path.info)
    }

    func pair(_ request: TransferProtocol.PairRequest) async throws -> TransferProtocol.PairResponse {
        try await postJSON(TransferProtocol.Path.pair, body: request)
    }

    func library() async throws -> TransferProtocol.LibraryManifest {
        try await getJSON(TransferProtocol.Path.library)
    }

    func artwork(gameID: String) async throws -> Data {
        try await getData(TransferProtocol.Path.artwork(gameID: gameID), allowMissing: true) ?? Data()
    }

    // MARK: - Files

    /// Copies a game down, a few megabytes at a time.
    ///
    /// The file already on disk decides where the transfer picks up, so a run
    /// that was interrupted carries on instead of starting over.
    func download(gameID: String,
                  size: Int64,
                  to destination: URL,
                  progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        if !fm.fileExists(atPath: destination.path) {
            fm.createFile(atPath: destination.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            throw MediaClientError.badResponse("could not open the cache file")
        }
        defer { try? handle.close() }

        var offset = Int64((try? fm.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0) ?? 0
        if offset > size {
            // A stale partial file from a different game: start over.
            try? handle.truncate(atOffset: 0)
            offset = 0
        }

        let chunkSize: Int64 = 8 * 1024 * 1024

        while offset < size {
            try Task.checkCancellation()

            let end = min(offset + chunkSize, size) - 1
            var request = URLRequest(url: try url(for: TransferProtocol.Path.gameFile(gameID: gameID)))
            addToken(to: &request)
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MediaClientError.badResponse("not an HTTP answer")
            }

            switch http.statusCode {
            case 206:
                break
            case 200 where offset == 0:
                break
            case 416:
                // The file is shorter than we thought: ask what it is now.
                throw MediaClientError.shortRead
            case 401, 403:
                throw MediaClientError.notPaired
            default:
                throw MediaClientError.http(http.statusCode)
            }

            guard !data.isEmpty else { throw MediaClientError.shortRead }

            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
            progress?(size > 0 ? Double(offset) / Double(size) : 1)
        }

        try handle.synchronize()
    }

    /// Sends a whole game to this host (another phone, or a TV letting the
    /// phone push to it).
    func uploadGame(gameID: String,
                    fileName: String,
                    from fileURL: URL,
                    progress: (@Sendable (Double) -> Void)? = nil) async throws {
        var request = URLRequest(url: try url(for: TransferProtocol.Path.importGame(gameID: gameID, name: fileName)))
        request.httpMethod = "PUT"
        addToken(to: &request)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await session.upload(for: request, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse else {
            throw MediaClientError.badResponse("not an HTTP answer")
        }
        guard http.statusCode == 200 else { throw MediaClientError.http(http.statusCode) }
        progress?(1)
    }

    // MARK: - SavePeer

    func peerSavesIndex() async throws -> TransferProtocol.SavesIndex {
        try await getJSON(TransferProtocol.Path.savesIndex)
    }

    func mergeSaves(_ index: TransferProtocol.SavesIndex) async throws -> TransferProtocol.MergeResponse {
        try await postJSON(TransferProtocol.Path.savesMerge, body: index)
    }

    func fetchSaveBlob(_ meta: TransferProtocol.SaveBlobMeta) async throws -> Data {
        try await getData(TransferProtocol.Path.save(gameID: meta.gameID, kind: meta.kind)) ?? Data()
    }

    func putSaveBlob(_ meta: TransferProtocol.SaveBlobMeta, data: Data) async throws -> TransferProtocol.SavePutResponse {
        var request = URLRequest(url: try url(for: TransferProtocol.Path.save(gameID: meta.gameID, kind: meta.kind)))
        request.httpMethod = "PUT"
        addToken(to: &request)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        // The version the sender has, so the receiver does not have to guess.
        request.setValue(String(meta.version), forHTTPHeaderField: "X-Cassowary-Version")

        let (body, response) = try await session.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse else {
            throw MediaClientError.badResponse("not an HTTP answer")
        }
        guard http.statusCode == 200 else { throw MediaClientError.http(http.statusCode) }
        return (try? TransferProtocol.decoder.decode(TransferProtocol.SavePutResponse.self, from: body))
            ?? TransferProtocol.SavePutResponse(stored: true, conflict: false)
    }

    // MARK: - Plumbing

    private func url(for path: String) throws -> URL {
        // Built through URLComponents because addresses come back as names,
        // IPv4, or bracketed IPv6, and only URLComponents takes all three.
        var components = URLComponents()
        components.scheme = "http"
        components.host = host.address
        components.port = Int(host.port)
        components.percentEncodedPath = path

        guard let url = components.url else {
            throw MediaClientError.noAddress
        }
        return url
    }

    private func addToken(to request: inout URLRequest) {
        request.setValue("\(TransferProtocol.version)", forHTTPHeaderField: "X-Cassowary-Protocol")
        if let token {
            request.setValue(token, forHTTPHeaderField: TransferProtocol.tokenHeader)
        }
    }

    private func getJSON<T: Decodable>(_ path: String) async throws -> T {
        try await requestJSON(path, method: "GET", body: nil)
    }

    private func postJSON<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        try await requestJSON(path, method: "POST", body: try TransferProtocol.encoder.encode(body))
    }

    private func requestJSON<T: Decodable>(_ path: String, method: String, body: Data?) async throws -> T {
        var request = URLRequest(url: try url(for: path))
        request.httpMethod = method
        addToken(to: &request)
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MediaClientError.badResponse("not an HTTP answer")
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw MediaClientError.notPaired }
        guard http.statusCode == 200 else { throw MediaClientError.http(http.statusCode) }

        do {
            return try TransferProtocol.decoder.decode(T.self, from: data)
        } catch {
            throw MediaClientError.badResponse(error.localizedDescription)
        }
    }

    private func getData(_ path: String, allowMissing: Bool = false) async throws -> Data? {
        var request = URLRequest(url: try url(for: path))
        addToken(to: &request)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MediaClientError.badResponse("not an HTTP answer")
        }
        if http.statusCode == 404, allowMissing { return nil }
        if http.statusCode == 401 || http.statusCode == 403 { throw MediaClientError.notPaired }
        guard http.statusCode == 200 else { throw MediaClientError.http(http.statusCode) }
        return data
    }
}
