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
#if canImport(UIKit)
import UIKit
#endif

/// The host side of a transfer: the server, the Allow prompt, and the state
/// the Sharing screen shows.
///
/// It serves the library in Documents, answers save questions, and accepts a
/// game pushed from another device. Nothing at all happens while sharing is
/// switched off.
@MainActor
final class HostShareController: ObservableObject {

    static let shared = HostShareController()

    struct PairingPrompt: Identifiable {
        let id: String
        let request: TransferProtocol.PairRequest
    }

    struct ConnectedPeer: Identifiable, Hashable {
        let deviceID: String
        let name: String
        let platformName: String
        var lastSeen: Date
        var id: String { deviceID }

        var platformLabel: String {
            switch platformName {
            case "tvos": return "Apple TV"
            case "mac":  return "Mac"
            default:     return "iPhone or iPad"
            }
        }
    }

    struct Transfer: Identifiable {
        let id: String
        var title: String
        var progress: Double
    }

    @Published private(set) var isRunning = false
    @Published private(set) var port: UInt16 = 0
    @Published private(set) var connectedPeers: [ConnectedPeer] = []
    @Published var pendingPairing: PairingPrompt?
    @Published private(set) var lastAction: String?
    @Published private(set) var pendingSaveCount = 0
    @Published private(set) var conflicts: [SaveConflict] = []
    @Published private(set) var transfers: [Transfer] = []
    @Published private(set) var indexedGames = 0

    /// The library as the server sees it. The library view hands this over
    /// whenever it refreshes.
    private(set) var games: [Game] = []

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: SharingDefaults.enabledKey)
    }

    /// The test hook: allow anyone, so the scripts do not have to tap Allow.
    var trustAll: Bool {
        UserDefaults.standard.bool(forKey: SharingDefaults.trustAllKey)
    }

    private var server: HTTPMediaServer?
    private var pairingContinuations: [String: CheckedContinuation<Bool, Never>] = [:]
    private var pruneTask: Task<Void, Never>?

    private init() {
        conflicts = []
    }

    // MARK: - Lifecycle

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: SharingDefaults.enabledKey)
        enabled ? start() : stop()
    }

    func start() {
        guard server == nil else { return }

        let server = HTTPMediaServer { request in
            await HostShareController.shared.handle(request)
        }
        let identity = DeviceIdentity.current
        server.serviceName = identity.name
        server.serviceTXT = ["id": identity.id,
                             "name": identity.name,
                             "platform": identity.platformName]

        do {
            // A test can pin the port; normally the system picks one. The
            // launch argument arrives as a string, and a stored number as a
            // number, so both spellings are accepted.
            var preferred: UInt16?
            if let number = UserDefaults.standard.object(forKey: SharingDefaults.portKey) as? Int {
                preferred = UInt16(exactly: number)
            } else if let text = UserDefaults.standard.string(forKey: SharingDefaults.portKey) {
                preferred = UInt16(text)
            }
            try server.start(preferredPort: preferred)
        } catch {
            lastAction = "Could not start sharing: \(error.localizedDescription)"
            return
        }

        self.server = server
        isRunning = true
        port = server.port
        // The port is not known until the listener is ready; the media server
        // logs it when that happens.
        NSLog("[Cassowary] sharing started as %@", identity.name)

        // Serving needs the app awake and in front, so the screen stays on
        // while sharing is switched on.
#if !os(tvOS) && canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = true
#endif

        // The server learns its port when the listener is ready.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.port = server.port
        }

        startPruningPeers()
        refreshSaveState()
        lastAction = "Waiting for a device to connect."
    }

    func stop() {
        server?.stop()
        server = nil
        isRunning = false
        port = 0
        connectedPeers = []
        pruneTask?.cancel()
        pruneTask = nil
        lastAction = nil

#if !os(tvOS) && canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = false
#endif
    }

    /// Called when the library changes, so the manifest stays right and the
    /// save versions pick up anything the user just played.
    func updateGames(_ games: [Game]) {
        self.games = games
        HostLibrary.shared.reindex(games)
        indexedGames = HostLibrary.shared.indexedCount
        refreshSaveState()
    }

    func refreshSaveState() {
        let locations = HostLibrary.shared.locations(for: games)
        _ = SaveStore.scan(games: locations)
        pendingSaveCount = SaveIndexStore.shared.pendingCount()
        conflicts = ConflictStore.shared.conflicts
    }

    // MARK: - Pairing

    func resolvePairing(id: String, accept: Bool) {
        guard let continuation = pairingContinuations.removeValue(forKey: id) else { return }
        pendingPairing = nil
        continuation.resume(returning: accept)
    }

    private func askUser(_ request: TransferProtocol.PairRequest) async -> Bool {
        if trustAll { return true }

        let id = UUID().uuidString
        return await withCheckedContinuation { continuation in
            pairingContinuations[id] = continuation
            pendingPairing = PairingPrompt(id: id, request: request)

            // Nobody at the phone: give up rather than leaving the TV hanging.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard let self, self.pairingContinuations[id] != nil else { return }
                self.resolvePairing(id: id, accept: false)
            }
        }
    }

    // MARK: - Requests

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard let clientVersion = Int(request.header("X-Cassowary-Protocol") ?? ""),
              clientVersion == TransferProtocol.version else {
            return .text("This device speaks a different Cassowary version.", status: 400)
        }

        switch (request.method, request.path) {
        case ("GET", TransferProtocol.Path.info):
            return .json(TransferProtocol.HostInfo(protocolVersion: TransferProtocol.version,
                                                   deviceID: DeviceIdentity.current.id,
                                                   deviceName: DeviceIdentity.current.name,
                                                   pairingRequired: !trustAll,
                                                   appVersion: appVersion))

        case ("POST", TransferProtocol.Path.pair):
            return await handlePair(request)

        default:
            break
        }

        guard let peer = authorizedPeer(for: request) else {
            return .text("Pair this device first.", status: 401)
        }
        noteSeen(peer)

        if request.method == "GET", request.path == TransferProtocol.Path.library {
            return handleLibrary()
        }

        if request.method == "GET", request.path == TransferProtocol.Path.savesIndex {
            let metas = SaveStore.scan(games: HostLibrary.shared.locations(for: games))
            pendingSaveCount = SaveIndexStore.shared.pendingCount()
            conflicts = ConflictStore.shared.conflicts
            return .json(TransferProtocol.SavesIndex(deviceID: DeviceIdentity.current.id, blobs: metas))
        }

        if request.method == "POST", request.path == TransferProtocol.Path.savesMerge {
            NSLog("[Cassowary] sharing: saves merge with %@", peer.name)
            return handleMerge(request)
        }

        if request.path.hasPrefix(TransferProtocol.Path.gameFilePrefix) {
            return handleGameRequest(request)
        }

        if request.path.hasPrefix(TransferProtocol.Path.artworkPrefix) {
            return handleArtwork(request)
        }

        if request.path.hasPrefix(TransferProtocol.Path.savesPrefix) {
            return handleSaveRequest(request)
        }

        return .text("Not found", status: 404)
    }

    // MARK: - Pairing route

    private func handlePair(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = try? TransferProtocol.decoder.decode(TransferProtocol.PairRequest.self, from: request.body) else {
            return .text("Bad pair request", status: 400)
        }

        if let existing = TrustStore.shared.peer(withID: body.deviceID) {
            var updated = existing
            updated.lastSeen = Date()
            updated.name = body.deviceName
            TrustStore.shared.add(updated)
            noteSeen(updated)
            return .json(TransferProtocol.PairResponse(accepted: true, token: existing.token))
        }

        let allowed = await askUser(body)
        guard allowed else {
            lastAction = "\(body.deviceName) was not allowed in."
            return .json(TransferProtocol.PairResponse(accepted: false, token: nil))
        }

        let token = PairingToken.make()
        let peer = TrustedPeer(deviceID: body.deviceID,
                               name: body.deviceName,
                               platformName: body.platformName,
                               token: token,
                               lastSeen: Date())
        TrustStore.shared.add(peer)
        noteSeen(peer)
        lastAction = "\(body.deviceName) was allowed in."
        return .json(TransferProtocol.PairResponse(accepted: true, token: token))
    }

    // MARK: - Library routes

    private func handleLibrary() -> HTTPResponse {
        let entries = HostLibrary.shared.entries(for: games)
        let manifest = TransferProtocol.LibraryManifest(
            generation: HostLibrary.shared.generation(for: games),
            games: entries
        )
        return .json(manifest)
    }

    private func handleGameRequest(_ request: HTTPRequest) -> HTTPResponse {
        // /v1/games/<id>/file/<n>  or  /v1/games/<id>/import?name=…
        let parts = request.path.split(separator: "/").map(String.init)
        guard parts.count >= 3 else { return .text("Bad game path", status: 400) }
        let gameID = parts[2]

        if parts.count >= 4, parts[3] == "file" {
            guard let url = HostLibrary.shared.gameFileURL(withID: gameID) else {
                return .text("No such game", status: 404)
            }
            let total = Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)

            if let range = RangeHeader.parse(request.header("Range"), totalSize: total) {
                return HTTPResponse(status: 206,
                                    reason: "Partial Content",
                                    headers: [
                                        "Content-Type": "application/octet-stream",
                                        "Content-Range": "bytes \(range.start)-\(range.end)/\(total)",
                                    ],
                                    fileURL: url,
                                    fileOffset: range.start,
                                    fileLength: range.end - range.start + 1)
            }

            return HTTPResponse(status: 200,
                                reason: "OK",
                                headers: ["Content-Type": "application/octet-stream"],
                                fileURL: url,
                                fileOffset: 0,
                                fileLength: total)
        }

        if parts.count >= 4, parts[3] == "import", request.method == "PUT" {
            return handleImport(request, gameID: gameID)
        }

        return .text("Not found", status: 404)
    }

    private func handleImport(_ request: HTTPRequest, gameID: String) -> HTTPResponse {
        guard let tempURL = request.bodyFileURL else {
            return .text("The upload did not arrive", status: 400)
        }
        guard let name = request.query["name"], !name.isEmpty,
              !name.contains("/") else {
            try? FileManager.default.removeItem(at: tempURL)
            return .text("The upload needs a file name", status: 400)
        }

        // The id is the content's hash, so a file that does not match is not
        // the game it says it is.
        guard let hash = Hashing.sha256(ofFileAt: tempURL), hash == gameID else {
            try? FileManager.default.removeItem(at: tempURL)
            return .text("The file does not match its game id", status: 400)
        }

        let destination = GameLibrary.documentsDirectory.appendingPathComponent(name)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return .text("Could not store the game: \(error.localizedDescription)", status: 500)
        }

        lastAction = "Received \(name)"
        return .text("Stored")
    }

    private func handleArtwork(_ request: HTTPRequest) -> HTTPResponse {
        let gameID = String(request.path.dropFirst(TransferProtocol.Path.artworkPrefix.count))
        guard let record = GameIndexStore.shared.record(forHash: gameID),
              let game = games.first(where: { $0.url.path == record.path }),
              let artwork = HostLibrary.shared.artworkURL(for: game),
              let data = try? Data(contentsOf: artwork)
        else {
            return .empty(status: 404)
        }

        return HTTPResponse(status: 200,
                            reason: "OK",
                            headers: ["Content-Type": "image/png"],
                            body: data)
    }

    // MARK: - Save routes

    private func handleMerge(_ request: HTTPRequest) -> HTTPResponse {
        guard let incoming = try? TransferProtocol.decoder.decode(TransferProtocol.SavesIndex.self, from: request.body) else {
            return .text("Bad merge request", status: 400)
        }

        let locations = HostLibrary.shared.locations(for: games)
        let local = SaveStore.scan(games: locations)
        let answer = SaveSyncEngine.merge(local: local, remote: incoming.blobs)
        conflicts = ConflictStore.shared.conflicts
        return .json(answer)
    }

    private func handleSaveRequest(_ request: HTTPRequest) -> HTTPResponse {
        // /v1/saves/<gameID>/<kind>
        let remainder = String(request.path.dropFirst(TransferProtocol.Path.savesPrefix.count))
        let parts = remainder.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return .text("Bad save path", status: 400) }

        let gameID = parts[0]
        let kind = parts[1]
        let locations = HostLibrary.shared.locations(for: games)
        let meta = TransferProtocol.SaveBlobMeta(gameID: gameID, kind: kind,
                                                 version: 0, deviceID: "",
                                                 hash: "", size: 0, modifiedAt: Date())

        guard let url = SaveStore.url(for: meta, games: locations) else {
            return .text("No such game", status: 404)
        }

        if request.method == "GET" {
            guard let data = try? Data(contentsOf: url) else {
                return .empty(status: 404)
            }
            let version = SaveIndexStore.shared.record(gameID: gameID, kind: kind)
            return HTTPResponse(status: 200,
                                reason: "OK",
                                headers: [
                                    "Content-Type": "application/octet-stream",
                                    "X-Cassowary-Version": String(version?.version ?? 0),
                                ],
                                body: data)
        }

        if request.method == "PUT", !request.body.isEmpty {
            let hash = Hashing.sha256(of: request.body)
            let record = SaveIndexStore.shared.record(gameID: gameID, kind: kind)

            // The counter only has to go up; the sender's is used when it is
            // already ahead, so a save that arrived from the TV does not look
            // older than it is.
            let senderVersion = Int(request.header("X-Cassowary-Version") ?? "") ?? 0
            let incoming = TransferProtocol.SaveBlobMeta(gameID: gameID,
                                                         kind: kind,
                                                         version: max(senderVersion, (record?.version ?? 0) + 1),
                                                         deviceID: DeviceIdentity.current.id,
                                                         hash: hash,
                                                         size: Int64(request.body.count),
                                                         modifiedAt: Date())

            let response = SaveSyncEngine.storeIncoming(meta: incoming, data: request.body, games: locations)
            refreshSaveState()
            lastAction = response.conflict
                ? "A save needs your choice."
                : "Saves synced with \(connectedPeers.first?.name ?? "a device")."
            return .json(response)
        }

        return .text("Not supported", status: 400)
    }

    // MARK: - Peers

    private func authorizedPeer(for request: HTTPRequest) -> TrustedPeer? {
        if trustAll {
            if let id = request.header("X-Cassowary-Device") {
                return TrustStore.shared.peer(withID: id)
                    ?? TrustedPeer(deviceID: id, name: "Test device", platformName: "tvos",
                                   token: "", lastSeen: Date())
            }
            // The test scripts pair first, so a token usually exists.
        }

        guard let token = request.header(TransferProtocol.tokenHeader), !token.isEmpty else { return nil }
        return TrustStore.shared.peers.first { $0.token == token }
    }

    private func noteSeen(_ peer: TrustedPeer) {
        if let index = connectedPeers.firstIndex(where: { $0.deviceID == peer.deviceID }) {
            connectedPeers[index].lastSeen = Date()
        } else {
            connectedPeers.append(ConnectedPeer(deviceID: peer.deviceID,
                                                name: peer.name,
                                                platformName: peer.platformName,
                                                lastSeen: Date()))
        }
        lastAction = "\(peer.name) is connected."
    }

    private func startPruningPeers() {
        pruneTask?.cancel()
        pruneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                let cutoff = Date().addingTimeInterval(-120)
                let before = self.connectedPeers.count
                self.connectedPeers.removeAll { $0.lastSeen < cutoff }
                if self.connectedPeers.count != before, self.connectedPeers.isEmpty {
                    self.lastAction = "Waiting for a device to connect."
                }
            }
        }
    }

    // MARK: - Pulling from a TV

    /// Pushes one game to another host. Used by the phone's "Send to…" menu.
    func send(game: Game, to host: MediaHost, token: String?, progress: @escaping @MainActor (Double) -> Void) async -> String {
        guard let record = GameIndexStore.shared.record(forPath: game.url.path) else {
            return "That game has not been fingerprinted yet. Try again in a moment."
        }

        let transferID = UUID().uuidString
        transfers.append(Transfer(id: transferID, title: "Sending \(game.title)", progress: 0))
        defer { transfers.removeAll { $0.id == transferID } }

        let client = MediaClient(host: host, token: token)
        do {
            try await client.uploadGame(gameID: record.sha256,
                                        fileName: game.url.lastPathComponent,
                                        from: game.url) { value in
                Task { @MainActor in
                    progress(value)
                    if let index = self.transfers.firstIndex(where: { $0.id == transferID }) {
                        self.transfers[index].progress = value
                    }
                }
            }
            lastAction = "Sent \(game.title) to \(host.name)."
            return "Sent to \(host.name)."
        } catch {
            lastAction = "Could not send \(game.title): \(error.localizedDescription)"
            return error.localizedDescription
        }
    }

    // MARK: - Conflicts

    func resolve(_ conflict: SaveConflict, choice: SaveSyncEngine.ConflictChoice) {
        let locations = HostLibrary.shared.locations(for: games)
        SaveSyncEngine.resolve(conflict, choice: choice, games: locations)
        conflicts = ConflictStore.shared.conflicts
        refreshSaveState()
        lastAction = "Save conflict settled."
    }

    /// A readable name for a game id, for the conflict prompt.
    func title(forGameID id: String) -> String {
        if let record = GameIndexStore.shared.record(forHash: id) {
            return record.title
        }
        return "A game"
    }

    // MARK: - Helpers

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}
