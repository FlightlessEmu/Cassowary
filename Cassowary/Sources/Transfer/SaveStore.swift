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

/// What this device remembers about one save file.
struct SaveVersionRecord: Codable, Hashable {
    var version: Int
    var deviceID: String
    var hash: String
    var size: Int64
    var modifiedAt: Date
    /// True while the newest copy has not been handed to every paired device.
    var pending: Bool
}

/// The save versions, remembered across launches.
///
/// Deleting this file loses nothing that cannot be rebuilt: the files stay
/// where they are, and the next scan re-files them.
final class SaveIndexStore {

    static let shared = SaveIndexStore()

    private let lock = NSLock()
    private var records: [String: SaveVersionRecord] = [:]

    private init() {
        load()
    }

    static func key(gameID: String, kind: String) -> String { "\(gameID)|\(kind)" }

    func record(gameID: String, kind: String) -> SaveVersionRecord? {
        lock.lock(); defer { lock.unlock() }
        return records[Self.key(gameID: gameID, kind: kind)]
    }

    func allRecords() -> [String: SaveVersionRecord] {
        lock.lock(); defer { lock.unlock() }
        return records
    }

    func set(_ record: SaveVersionRecord, gameID: String, kind: String) {
        lock.lock()
        records[Self.key(gameID: gameID, kind: kind)] = record
        lock.unlock()
        save()
    }

    func remove(gameID: String, kind: String) {
        lock.lock()
        records.removeValue(forKey: Self.key(gameID: gameID, kind: kind))
        lock.unlock()
        save()
    }

    func pendingCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return records.values.filter(\.pending).count
    }

    private func load() {
        guard let data = try? Data(contentsOf: SharingPaths.saveIndex),
              let saved = try? JSONDecoder().decode([String: SaveVersionRecord].self, from: data)
        else { return }
        records = saved
    }

    private func save() {
        lock.lock()
        let copy = records
        lock.unlock()
        guard let data = try? TransferProtocol.encoder.encode(copy) else { return }
        try? data.write(to: SharingPaths.saveIndex, options: .atomic)
    }
}

/// Where a save lives for one game.
struct GameLocation: Hashable {
    let id: String
    let romURL: URL
}

/// Finds, reads and writes the save files on this device.
///
/// Save states live next to the ROM, the way the engine writes them. Battery
/// saves live where the engine keeps them, one folder per core. Both look the
/// same on the phone and on the TV, so one implementation serves both.
struct SaveStore {

    /// Every save blob this device has, with the versions refreshed for
    /// anything that changed since the last scan.
    ///
    /// - Parameter games: the games to look at. A save whose game is not in
    ///   the list is left alone rather than guessed at.
    static func scan(games: [GameLocation]) -> [TransferProtocol.SaveBlobMeta] {
        let deviceID = DeviceIdentity.current.id
        var metas: [TransferProtocol.SaveBlobMeta] = []

        for game in games {
            let stateURL = saveStateURL(for: game.romURL)
            if FileManager.default.fileExists(atPath: stateURL.path) {
                if let meta = meta(gameID: game.id, kind: SaveKind.state, url: stateURL, deviceID: deviceID) {
                    metas.append(meta)
                }
            }

            for battery in batterySaveURLs(forROMName: game.romURL.lastPathComponent) {
                if let meta = meta(gameID: game.id,
                                   kind: SaveKind.battery(core: battery.core, file: battery.file),
                                   url: battery.url,
                                   deviceID: deviceID) {
                    metas.append(meta)
                }
            }

            let infoURL = playInfoURL(gameID: game.id)
            if FileManager.default.fileExists(atPath: infoURL.path),
               let meta = meta(gameID: game.id, kind: SaveKind.playInfo, url: infoURL, deviceID: deviceID) {
                metas.append(meta)
            }
        }

        return metas
    }

    /// Reads one blob's bytes.
    static func data(for meta: TransferProtocol.SaveBlobMeta, games: [GameLocation]) -> Data? {
        guard let url = url(for: meta, games: games) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Writes one blob in place, keeping a copy of whatever was there.
    ///
    /// The version and the pending flag come from the caller because only it
    /// knows whether this copy came from another device.
    @discardableResult
    static func store(data: Data,
                      meta: TransferProtocol.SaveBlobMeta,
                      games: [GameLocation],
                      markPending: Bool) -> Bool {
        guard let url = url(for: meta, games: games) else { return false }

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[Cassowary] could not write save %@: %@", url.lastPathComponent, error.localizedDescription)
            return false
        }

        let record = SaveVersionRecord(version: meta.version,
                                       deviceID: meta.deviceID,
                                       hash: Hashing.sha256(of: data),
                                       size: Int64(data.count),
                                       modifiedAt: meta.modifiedAt,
                                       pending: markPending)
        SaveIndexStore.shared.set(record, gameID: meta.gameID, kind: meta.kind)

        return true
    }

    /// A copy of an existing save, kept when the user chooses "keep both".
    static func keepBackup(of meta: TransferProtocol.SaveBlobMeta, games: [GameLocation]) {
        guard let url = url(for: meta, games: games),
              FileManager.default.fileExists(atPath: url.path) else { return }

        let folder = SharingPaths.supportDirectory.appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let name = "\(meta.gameID)-\(meta.kind.replacingOccurrences(of: ":", with: "_"))-\(stamp)"
        let destination = folder.appendingPathComponent(name)
        try? FileManager.default.copyItem(at: url, to: destination)
    }

    // MARK: - Where files live

    /// The engine writes a save state beside the ROM, keeping the ROM's name
    /// and replacing its extension.
    static func saveStateURL(for romURL: URL) -> URL {
        romURL.deletingPathExtension().appendingPathExtension("oesavestate")
    }

    /// Battery saves are named after the ROM and live under the core that
    /// wrote them: `Application Support/OpenEmu/<core>/Battery Saves/`.
    static func batterySaveURLs(forROMName romName: String) -> [(core: String, file: String, url: URL)] {
        let base = (romName as NSString).deletingPathExtension
        let root = SharingPaths.batterySavesRoot
        let fm = FileManager.default

        guard let cores = try? fm.contentsOfDirectory(at: root,
                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }

        var found: [(core: String, file: String, url: URL)] = []
        for core in cores {
            let saves = core.appendingPathComponent("Battery Saves", isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(at: saves,
                                                          includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { continue }
            for file in files where (file.lastPathComponent as NSString).deletingPathExtension == base {
                found.append((core.lastPathComponent, file.lastPathComponent, file))
            }
        }
        return found
    }

    /// Where a blob lives, or would live, on this device.
    static func url(for meta: TransferProtocol.SaveBlobMeta, games: [GameLocation]) -> URL? {
        if meta.kind == SaveKind.playInfo {
            return playInfoURL(gameID: meta.gameID)
        }

        guard let game = games.first(where: { $0.id == meta.gameID }) else { return nil }

        if let parts = SaveKind.batteryParts(meta.kind) {
            return SharingPaths.batterySavesRoot
                .appendingPathComponent(parts.core, isDirectory: true)
                .appendingPathComponent("Battery Saves", isDirectory: true)
                .appendingPathComponent(parts.file)
        }

        return saveStateURL(for: game.romURL)
    }

    /// Play history lives beside the rest of the sharing state, not next to a
    /// game that may not be downloaded.
    static func playInfoURL(gameID: String) -> URL {
        SharingPaths.supportDirectory
            .appendingPathComponent("PlayInfo", isDirectory: true)
            .appendingPathComponent("\(gameID).json")
    }

    /// Reads a game's play history, empty when it has never been played.
    static func loadPlayInfo(gameID: String) -> PlayInfo {
        guard let data = try? Data(contentsOf: playInfoURL(gameID: gameID)),
              let info = try? TransferProtocol.decoder.decode(PlayInfo.self, from: data)
        else { return .empty }
        return info
    }

    /// Writes a game's play history. The next scan picks it up as a change
    /// and queues it for the other devices.
    static func savePlayInfo(_ info: PlayInfo, gameID: String) {
        let url = playInfoURL(gameID: gameID)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? TransferProtocol.encoder.encode(info) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Version bookkeeping

    private static func meta(gameID: String,
                             kind: String,
                             url: URL,
                             deviceID: String) -> TransferProtocol.SaveBlobMeta? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let modified = values.contentModificationDate
        else { return nil }

        var record = SaveIndexStore.shared.record(gameID: gameID, kind: kind)

        // Hashing every save on every scan would be wasteful; a file whose
        // size and date are unchanged is the file that was hashed last time.
        let hash: String
        if let record, record.size == Int64(size), record.modifiedAt == modified {
            hash = record.hash
        } else {
            guard let fresh = Hashing.sha256(ofFileAt: url) else { return nil }
            hash = fresh
        }

        // A file that changed since the last look is a new version written
        // here, and it has to go out to everyone else.
        if record == nil || record?.hash != hash {
            let version = (record?.version ?? 0) + 1
            let updated = SaveVersionRecord(version: version,
                                            deviceID: deviceID,
                                            hash: hash,
                                            size: Int64(size),
                                            modifiedAt: modified,
                                            pending: true)
            SaveIndexStore.shared.set(updated, gameID: gameID, kind: kind)
            record = updated
        } else if let existing = record, existing.size != Int64(size) || existing.modifiedAt != modified {
            let updated = SaveVersionRecord(version: existing.version,
                                            deviceID: existing.deviceID,
                                            hash: hash,
                                            size: Int64(size),
                                            modifiedAt: modified,
                                            pending: existing.pending)
            SaveIndexStore.shared.set(updated, gameID: gameID, kind: kind)
            record = updated
        }

        guard let record else { return nil }
        return TransferProtocol.SaveBlobMeta(gameID: gameID,
                                             kind: kind,
                                             version: record.version,
                                             deviceID: record.deviceID,
                                             hash: record.hash,
                                             size: record.size,
                                             modifiedAt: record.modifiedAt)
    }
}
