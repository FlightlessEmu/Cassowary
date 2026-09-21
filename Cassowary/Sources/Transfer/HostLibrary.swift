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

/// What the host knows about the games it can serve.
///
/// The library itself is still just files in Documents. This adds the one
/// thing a transfer needs: a name for each game that means the same thing on
/// every device, which is the hash of its content. The hashing happens in the
/// background and is remembered, so a big library is only slow once.
@MainActor
final class HostLibrary: ObservableObject {

    static let shared = HostLibrary()

    /// True while files are being hashed.
    @Published private(set) var isIndexing = false
    @Published private(set) var indexedCount = 0
    @Published private(set) var totalCount = 0

    private var indexTask: Task<Void, Never>?

    /// A plain copy of what hashing needs, so it can run off the main actor.
    private struct Candidate: Sendable {
        var path: String
        var size: Int64
        var modifiedAt: Date
        var title: String
        var systemIdentifier: String
        var systemName: String
    }

    /// Makes sure every game has a content hash, then stops.
    func reindex(_ games: [Game]) {
        totalCount = games.count
        indexedCount = games.filter { GameIndexStore.shared.record(forPath: $0.url.path) != nil }.count

        guard indexTask == nil else { return }

        let candidates: [Candidate] = games.compactMap { game in
            guard let values = try? game.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  let modified = values.contentModificationDate
            else { return nil }
            return Candidate(path: game.url.path,
                             size: Int64(size),
                             modifiedAt: modified,
                             title: game.title,
                             systemIdentifier: game.system?.identifier ?? "",
                             systemName: game.systemName ?? "")
        }

        isIndexing = true
        indexTask = Task { [weak self] in
            await Task.detached(priority: .utility) {
                for candidate in candidates {
                    if let existing = GameIndexStore.shared.record(forPath: candidate.path),
                       existing.size == candidate.size,
                       existing.modifiedAt == candidate.modifiedAt {
                        continue
                    }

                    let url = URL(fileURLWithPath: candidate.path)
                    guard let hash = Hashing.sha256(ofFileAt: url) else { continue }

                    GameIndexStore.shared.upsert(GameRecord(sha256: hash,
                                                            path: candidate.path,
                                                            size: candidate.size,
                                                            modifiedAt: candidate.modifiedAt,
                                                            title: candidate.title,
                                                            systemIdentifier: candidate.systemIdentifier,
                                                            systemName: candidate.systemName))

                    await MainActor.run { self?.indexedCount += 1 }
                }
                GameIndexStore.shared.pruneMissingFiles()
            }.value

            await MainActor.run { self?.isIndexing = false }
            self?.indexTask = nil
        }
    }

    /// The games in the order the manifest lists them.
    func entries(for games: [Game]) -> [TransferProtocol.GameEntry] {
        games.compactMap { entry(for: $0) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func entry(for game: Game) -> TransferProtocol.GameEntry? {
        guard let record = GameIndexStore.shared.record(forPath: game.url.path) else { return nil }

        let stateURL = SaveStore.saveStateURL(for: game.url)
        return TransferProtocol.GameEntry(
            id: record.sha256,
            title: record.title,
            fileName: game.url.lastPathComponent,
            systemIdentifier: record.systemIdentifier,
            systemName: record.systemName,
            size: record.size,
            hasSaveState: FileManager.default.fileExists(atPath: stateURL.path),
            hasArtwork: artworkURL(for: game).map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
            hasBatterySave: !SaveStore.batterySaveURLs(forROMName: game.url.lastPathComponent).isEmpty
        )
    }

    /// Where the cover art for a game lives, if it has any.
    func artworkURL(for game: Game) -> URL? {
        CoverArtStore.imageURL(for: game)
    }

    /// The games as the save code sees them.
    func locations(for games: [Game]) -> [GameLocation] {
        games.compactMap { game in
            guard let record = GameIndexStore.shared.record(forPath: game.url.path) else { return nil }
            return GameLocation(id: record.sha256, romURL: game.url)
        }
    }

    /// The file for a game id, with the hash check the caller expects.
    func gameFileURL(withID id: String) -> URL? {
        guard let record = GameIndexStore.shared.record(forHash: id) else { return nil }
        return record.url
    }

    /// A number that changes whenever the library does, so the TV can tell
    /// whether its copy of the index is still good.
    func generation(for games: [Game]) -> String {
        let parts = games.compactMap { game -> String? in
            guard let record = GameIndexStore.shared.record(forPath: game.url.path) else { return nil }
            return "\(record.sha256):\(record.size)"
        }
        return Hashing.sha256(of: Data(parts.sorted().joined(separator: "|").utf8))
    }
}
