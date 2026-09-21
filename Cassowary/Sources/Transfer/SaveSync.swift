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

/// One save the two devices disagree about, waiting for the user.
struct SaveConflict: Codable, Identifiable, Hashable {
    var gameID: String
    var kind: String
    var local: TransferProtocol.SaveBlobMeta
    var remote: TransferProtocol.SaveBlobMeta
    /// The incoming bytes, held until the user decides.
    var heldFile: String
    var detectedAt: Date

    var id: String { "\(gameID)|\(kind)" }

    /// A readable name for the system's side of the choice.
    var title: String {
        kind == SaveKind.state ? "Save state" : "Battery save"
    }
}

/// The conflicts waiting for a decision, on either device.
@MainActor
final class ConflictStore: ObservableObject {

    static let shared = ConflictStore()

    @Published private(set) var conflicts: [SaveConflict] = []

    private init() {
        load()
    }

    func add(_ conflict: SaveConflict) {
        if let index = conflicts.firstIndex(where: { $0.id == conflict.id }) {
            conflicts[index] = conflict
        } else {
            conflicts.append(conflict)
        }
        save()
    }

    func remove(id: String) {
        conflicts.removeAll { $0.id == id }
        save()
    }

    func heldData(for conflict: SaveConflict) -> Data? {
        try? Data(contentsOf: Self.heldURL(for: conflict))
    }

    nonisolated static func heldURL(for conflict: SaveConflict) -> URL {
        SharingPaths.supportDirectory
            .appendingPathComponent("Conflicts", isDirectory: true)
            .appendingPathComponent(conflict.heldFile)
    }

    nonisolated static func hold(_ data: Data, gameID: String, kind: String) -> String? {
        let folder = SharingPaths.supportDirectory.appendingPathComponent("Conflicts", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let safe = "\(gameID)-\(kind)".replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let name = "\(safe).remote"
        do {
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            NSLog("[Cassowary] could not hold the incoming save: %@", error.localizedDescription)
            return nil
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: SharingPaths.conflicts),
              let saved = try? TransferProtocol.decoder.decode([SaveConflict].self, from: data)
        else { return }
        conflicts = saved
    }

    private func save() {
        guard let data = try? TransferProtocol.encoder.encode(conflicts) else { return }
        try? data.write(to: SharingPaths.conflicts, options: .atomic)
    }
}

/// What a sync run did, for the UI.
struct SaveSyncResult {
    var uploaded = 0
    var downloaded = 0
    var conflicts = 0
    var error: String?

    var summary: String {
        if let error { return error }
        if uploaded == 0, downloaded == 0, conflicts == 0 { return "Already in sync" }
        var parts: [String] = []
        if uploaded > 0 { parts.append("sent \(uploaded)") }
        if downloaded > 0 { parts.append("received \(downloaded)") }
        if conflicts > 0 { parts.append("\(conflicts) to choose") }
        return parts.joined(separator: ", ")
    }
}

/// Talking to the other device, whichever end we are.
protocol SavePeer {
    /// The other device's id, for messages.
    var peerDeviceID: String { get }
    func peerSavesIndex() async throws -> TransferProtocol.SavesIndex
    func mergeSaves(_ index: TransferProtocol.SavesIndex) async throws -> TransferProtocol.MergeResponse
    func fetchSaveBlob(_ meta: TransferProtocol.SaveBlobMeta) async throws -> Data
    func putSaveBlob(_ meta: TransferProtocol.SaveBlobMeta, data: Data) async throws -> TransferProtocol.SavePutResponse
}

/// The rules for moving saves between two devices.
///
/// The same code runs on both sides: one device calls `sync`, the other
/// answers its requests. Neither is the master.
enum SaveSyncEngine {

    // MARK: - The client half

    /// Sends what the other device does not have, takes what it does, and
    /// files anything the two disagree about for the user to choose.
    static func sync(games: [GameLocation], with peer: SavePeer) async -> SaveSyncResult {
        var result = SaveSyncResult()

        do {
            let localMetas = SaveStore.scan(games: games)
            let index = TransferProtocol.SavesIndex(deviceID: DeviceIdentity.current.id, blobs: localMetas)
            let answer = try await peer.mergeSaves(index)

            // What the other device wants from us.
            for wanted in answer.need {
                guard let local = localMetas.first(where: { $0.gameID == wanted.gameID && $0.kind == wanted.kind }),
                      let data = SaveStore.data(for: local, games: games)
                else { continue }

                let response = try await peer.putSaveBlob(local, data: data)
                if response.conflict {
                    result.conflicts += 1
                } else if response.stored {
                    markSynced(gameID: local.gameID, kind: local.kind)
                    result.uploaded += 1
                }
            }

            // What the other device has for us.
            for remote in answer.send {
                let data = try await peer.fetchSaveBlob(remote)
                let outcome = await apply(remote: remote, data: data, games: games)
                switch outcome {
                case .stored:      result.downloaded += 1
                case .conflict:    result.conflicts += 1
                case .ignored:     break
                }
            }
        } catch {
            result.error = error.localizedDescription
        }

        return result
    }

    /// Stores a save that arrived from another device, or files it as a
    /// conflict when this device has unsent changes of its own.
    @discardableResult
    static func apply(remote: TransferProtocol.SaveBlobMeta,
                      data: Data,
                      games: [GameLocation]) async -> IncomingOutcome {
        // Play history merges instead of being chosen.
        if remote.kind == SaveKind.playInfo {
            return mergePlayInfo(remote: remote, data: data, games: games)
        }

        let local = SaveIndexStore.shared.record(gameID: remote.gameID, kind: remote.kind)

        // Nothing here: take it.
        guard let local else {
            let stored = SaveStore.store(data: data, meta: remote, games: games, markPending: false)
            return stored ? .stored : .ignored
        }

        // Same bytes either way.
        let incomingHash = Hashing.sha256(of: data)
        if local.hash == incomingHash { return .ignored }

        // Local changes that have not gone out yet: only the user can say
        // which copy to keep.
        if local.pending {
            if let held = ConflictStore.hold(data, gameID: remote.gameID, kind: remote.kind) {
                let localMeta = TransferProtocol.SaveBlobMeta(gameID: remote.gameID,
                                                              kind: remote.kind,
                                                              version: local.version,
                                                              deviceID: local.deviceID,
                                                              hash: local.hash,
                                                              size: local.size,
                                                              modifiedAt: local.modifiedAt)
                await MainActor.run {
                    ConflictStore.shared.add(SaveConflict(gameID: remote.gameID,
                                                          kind: remote.kind,
                                                          local: localMeta,
                                                          remote: remote,
                                                          heldFile: held,
                                                          detectedAt: Date()))
                }
                return .conflict
            }
            return .ignored
        }

        // Nothing unsent here, so the newer copy wins.
        if remote.version >= local.version {
            let stored = SaveStore.store(data: data, meta: remote, games: games, markPending: false)
            return stored ? .stored : .ignored
        }

        return .ignored
    }

    /// Stores an upload on the host side. Kept separate from `apply` so the
    /// server can answer the sender in one response.
    static func storeIncoming(meta: TransferProtocol.SaveBlobMeta,
                              data: Data,
                              games: [GameLocation]) -> TransferProtocol.SavePutResponse {
        if meta.kind == SaveKind.playInfo {
            let outcome = mergePlayInfo(remote: meta, data: data, games: games)
            return TransferProtocol.SavePutResponse(stored: outcome != .ignored, conflict: false)
        }

        let local = SaveIndexStore.shared.record(gameID: meta.gameID, kind: meta.kind)
        let hash = Hashing.sha256(of: data)

        guard let local else {
            let stored = SaveStore.store(data: data, meta: meta, games: games, markPending: true)
            return TransferProtocol.SavePutResponse(stored: stored, conflict: false)
        }

        if local.hash == hash {
            return TransferProtocol.SavePutResponse(stored: true, conflict: false)
        }

        if local.pending {
            if let held = ConflictStore.hold(data, gameID: meta.gameID, kind: meta.kind) {
                let localMeta = TransferProtocol.SaveBlobMeta(gameID: meta.gameID,
                                                              kind: meta.kind,
                                                              version: local.version,
                                                              deviceID: local.deviceID,
                                                              hash: local.hash,
                                                              size: local.size,
                                                              modifiedAt: local.modifiedAt)
                Task { @MainActor in
                    ConflictStore.shared.add(SaveConflict(gameID: meta.gameID,
                                                          kind: meta.kind,
                                                          local: localMeta,
                                                          remote: meta,
                                                          heldFile: held,
                                                          detectedAt: Date()))
                }
                return TransferProtocol.SavePutResponse(stored: false, conflict: true)
            }
            return TransferProtocol.SavePutResponse(stored: false, conflict: false)
        }

        guard meta.version >= local.version else {
            return TransferProtocol.SavePutResponse(stored: false, conflict: false)
        }

        let stored = SaveStore.store(data: data, meta: meta, games: games, markPending: true)
        return TransferProtocol.SavePutResponse(stored: stored, conflict: false)
    }

    // MARK: - The host half

    /// The merge answer: what to send, and what to ask for.
    ///
    /// An equal version with different bytes goes both ways, so each side
    /// raises a conflict rather than one quietly overwriting the other.
    static func merge(local: [TransferProtocol.SaveBlobMeta],
                      remote: [TransferProtocol.SaveBlobMeta]) -> TransferProtocol.MergeResponse {
        var send: [TransferProtocol.SaveBlobMeta] = []
        var need: [TransferProtocol.SaveBlobMeta] = []

        for incoming in remote {
            guard let mine = local.first(where: { $0.gameID == incoming.gameID && $0.kind == incoming.kind }) else {
                need.append(incoming)
                continue
            }
            if mine.hash == incoming.hash { continue }

            if incoming.version > mine.version {
                need.append(incoming)
            } else if incoming.version < mine.version {
                send.append(mine)
            } else {
                send.append(mine)
                need.append(incoming)
            }
        }

        for mine in local where !remote.contains(where: { $0.gameID == mine.gameID && $0.kind == mine.kind }) {
            send.append(mine)
        }

        return TransferProtocol.MergeResponse(send: send, need: need)
    }

    // MARK: - Resolving

    enum ConflictChoice {
        case keepLocal
        case keepRemote
        case keepBoth
    }

    /// Settles one conflict. The chosen copy becomes the local one and is
    /// marked for upload, so the decision travels to the other devices.
    @MainActor
    static func resolve(_ conflict: SaveConflict, choice: ConflictChoice, games: [GameLocation]) {
        switch choice {
        case .keepLocal:
            break

        case .keepRemote, .keepBoth:
            if choice == .keepBoth {
                SaveStore.keepBackup(of: conflict.local, games: games)
            }
            if let data = ConflictStore.shared.heldData(for: conflict) {
                var meta = conflict.remote
                meta.version = max(conflict.local.version, conflict.remote.version) + 1
                meta.deviceID = DeviceIdentity.current.id
                meta.modifiedAt = Date()
                SaveStore.store(data: data, meta: meta, games: games, markPending: true)
            }
        }

        if choice == .keepLocal {
            // Make sure the local copy goes out with a version the other
            // devices will take.
            var meta = conflict.local
            meta.version = max(conflict.local.version, conflict.remote.version) + 1
            meta.deviceID = DeviceIdentity.current.id
            SaveIndexStore.shared.set(SaveVersionRecord(version: meta.version,
                                                        deviceID: meta.deviceID,
                                                        hash: meta.hash,
                                                        size: meta.size,
                                                        modifiedAt: meta.modifiedAt,
                                                        pending: true),
                                      gameID: conflict.gameID,
                                      kind: conflict.kind)
        }

        let held = ConflictStore.heldURL(for: conflict)
        try? FileManager.default.removeItem(at: held)
        ConflictStore.shared.remove(id: conflict.id)
    }

    // MARK: - Helpers

    /// Play history is counts and dates, not a document: the two sides are
    /// merged rather than one being chosen, and only a real change is stored.
    private static func mergePlayInfo(remote: TransferProtocol.SaveBlobMeta,
                                      data: Data,
                                      games: [GameLocation]) -> IncomingOutcome {
        guard let url = SaveStore.url(for: remote, games: games) else { return .ignored }

        let remoteInfo = (try? TransferProtocol.decoder.decode(PlayInfo.self, from: data)) ?? .empty
        let localData = try? Data(contentsOf: url)
        let localInfo = localData.flatMap { try? TransferProtocol.decoder.decode(PlayInfo.self, from: $0) } ?? .empty
        let merged = localInfo.merged(with: remoteInfo)

        guard let mergedData = try? TransferProtocol.encoder.encode(merged) else { return .ignored }
        if let localData, localData == mergedData { return .ignored }

        var meta = remote
        meta.version = (SaveIndexStore.shared.record(gameID: remote.gameID, kind: remote.kind)?.version ?? 0) + 1
        meta.deviceID = DeviceIdentity.current.id
        meta.hash = Hashing.sha256(of: mergedData)
        meta.size = Int64(mergedData.count)
        meta.modifiedAt = Date()

        let stored = SaveStore.store(data: mergedData, meta: meta, games: games, markPending: true)
        return stored ? .stored : .ignored
    }

    private static func markSynced(gameID: String, kind: String) {
        guard var record = SaveIndexStore.shared.record(gameID: gameID, kind: kind) else { return }
        record.pending = false
        SaveIndexStore.shared.set(record, gameID: gameID, kind: kind)
    }
}

enum IncomingOutcome: Equatable {
    case stored
    case conflict
    case ignored
}
