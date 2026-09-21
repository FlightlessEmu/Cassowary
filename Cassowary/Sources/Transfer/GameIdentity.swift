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
import CryptoKit

/// Hashing a file without loading it all into memory.
enum Hashing {

    static func sha256(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().hexString
    }

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).hexString
    }
}

extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

/// Where the sharing feature keeps its own small files.
///
/// None of this is the library itself: the games stay where they are, and
/// everything here can be deleted and rebuilt.
enum SharingPaths {

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sharing", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// What the host knows about its own games, keyed by content hash.
    static var gameIndex: URL { supportDirectory.appendingPathComponent("games.json") }

    /// The save versions and the upload queue, on either device.
    static var saveIndex: URL { supportDirectory.appendingPathComponent("saves.json") }

    /// Saves that could not be stored because the user has to choose.
    static var conflicts: URL { supportDirectory.appendingPathComponent("conflicts.json") }

    /// The TV's downloaded games. Under Caches, so the system may reclaim it.
    static var mediaCacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// The TV's copy of the host's library index, and what it has downloaded.
    static var tvLibraryIndex: URL { supportDirectory.appendingPathComponent("tv-library.json") }

    /// Save states the TV keeps beside a downloaded game. Mirrored here so
    /// evicting the game does not take the save with it.
    static var tvSaveVault: URL {
        let base = supportDirectory.appendingPathComponent("Saves", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Where the engine writes battery saves, one folder per core.
    static var batterySavesRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenEmu", isDirectory: true)
    }

    /// A game's folder in the TV's cache.
    static func cachedGameFolder(id: String) -> URL {
        mediaCacheDirectory.appendingPathComponent(id, isDirectory: true)
    }
}

/// What is known about one game file on this device.
struct GameRecord: Codable, Hashable {
    var sha256: String
    var path: String
    var size: Int64
    /// File modification date, used to notice a replaced file without
    /// hashing it again.
    var modifiedAt: Date
    var title: String
    var systemIdentifier: String
    var systemName: String

    var url: URL { URL(fileURLWithPath: path) }
}

/// The games this device can serve, remembered across launches so the big
/// files are hashed once.
///
/// It is a sidecar: deleting it costs one hashing pass and nothing else.
final class GameIndexStore {

    static let shared = GameIndexStore()

    private let lock = NSLock()
    private var recordsByHash: [String: GameRecord] = [:]

    private init() {
        load()
    }

    func allRecords() -> [GameRecord] {
        lock.lock(); defer { lock.unlock() }
        return Array(recordsByHash.values)
    }

    func record(forHash hash: String) -> GameRecord? {
        lock.lock(); defer { lock.unlock() }
        return recordsByHash[hash]
    }

    func record(forPath path: String) -> GameRecord? {
        lock.lock(); defer { lock.unlock() }
        return recordsByHash.values.first { $0.path == path }
    }

    func upsert(_ record: GameRecord) {
        lock.lock()
        recordsByHash[record.sha256] = record
        lock.unlock()
        save()
    }

    func remove(hash: String) {
        lock.lock()
        recordsByHash.removeValue(forKey: hash)
        lock.unlock()
        save()
    }

    /// Drops records whose files are gone.
    func pruneMissingFiles() {
        let fm = FileManager.default
        lock.lock()
        let missing = recordsByHash.filter { !fm.fileExists(atPath: $0.value.path) }.map(\.key)
        for hash in missing {
            recordsByHash.removeValue(forKey: hash)
        }
        lock.unlock()
        if !missing.isEmpty { save() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: SharingPaths.gameIndex),
              let records = try? JSONDecoder().decode([GameRecord].self, from: data)
        else { return }
        recordsByHash = Dictionary(uniqueKeysWithValues: records.map { ($0.sha256, $0) })
    }

    private func save() {
        lock.lock()
        let records = Array(recordsByHash.values)
        lock.unlock()
        guard let data = try? TransferProtocol.encoder.encode(records) else { return }
        try? data.write(to: SharingPaths.gameIndex, options: .atomic)
    }
}
