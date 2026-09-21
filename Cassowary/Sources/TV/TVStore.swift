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
import UIKit
import Combine

/// Everything the Apple TV knows and does: which phone it talks to, what the
/// phone's library looks like, what is downloaded, and how saves get home.
///
/// The TV is a borrower. Its library is a copy of the host's, its cache is
/// disposable, and the save vault exists so that throwing the cache away does
/// not throw away progress.
@MainActor
final class TVStore: ObservableObject {

    static let shared = TVStore()

    enum Connection: Equatable {
        case idle
        case connecting(String)
        case connected(MediaHost)
        case failed(String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    /// One game, as this TV knows it.
    struct LocalGame: Codable, Hashable, Identifiable {
        var id: String
        var title: String
        var fileName: String
        var systemIdentifier: String
        var systemName: String
        var size: Int64
        var hasArtwork: Bool
        var downloadedAt: Date?
        var lastPlayedAt: Date?
        var playCount: Int
        var favorite: Bool

        var isDownloaded: Bool { downloadedAt != nil }
    }

    struct State: Codable {
        var games: [String: LocalGame] = [:]
        var lastHostDeviceID: String?
        var lastHostName: String?
    }

    @Published private(set) var state = State()
    @Published private(set) var connection: Connection = .idle
    /// Download progress by game id, 0…1.
    @Published private(set) var downloads: [String: Double] = [:]
    @Published private(set) var syncSummary: String?
    @Published private(set) var conflicts: [SaveConflict] = []
    @Published private(set) var pendingUploads = 0
    @Published private(set) var cacheBytes: Int64 = 0
    @Published private(set) var artwork: [String: UIImage] = [:]
    @Published private(set) var libraryIsLoading = false

    let browser = PeerBrowser()

    private var client: MediaClient?
    private var host: MediaHost?
    private var syncTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var artworkFetches: Set<String> = []

    private init() {
        state = Self.loadState()
        updateCacheSize()
    }

    // MARK: - Starting

    func start() {
        browser.start()

        // Reconnect to the last phone by itself when it shows up again.
        browser.$hosts
            .sink { [weak self] hosts in
                guard let self else { return }

                // The test scripts ask for the first host without tapping.
                if UserDefaults.standard.bool(forKey: "cassowary.tvAutoConnectFirstHost"),
                   !self.connection.isConnected, !self.isConnecting,
                   let first = hosts.first {
                    Task { await self.connect(to: first) }
                    return
                }

                guard case .connected = self.connection else {
                    if let id = self.state.lastHostDeviceID,
                       let match = hosts.first(where: { $0.deviceID == id }),
                       !self.isConnecting {
                        Task { await self.connect(to: match) }
                    }
                    return
                }
            }
            .store(in: &cancellables)

        if let id = state.lastHostDeviceID,
           let match = browser.hosts.first(where: { $0.deviceID == id }) {
            Task { await self.connect(to: match) }
        }

        // A test, or a network without Bonjour, can name the host directly.
        if let direct = UserDefaults.standard.string(forKey: "cassowary.tvHostAddress") {
            let parts = direct.split(separator: ":")
            if parts.count == 2, let port = UInt16(parts[1]) {
                Task { await self.connectDirectly(address: String(parts[0]), port: port) }
            }
        }
    }

    private var isConnecting: Bool {
        if case .connecting = connection { return true }
        return false
    }

    // MARK: - Connecting

    func connect(to found: FoundHost) async {
        guard !isConnecting else { return }
        connection = .connecting(found.name)
        syncSummary = nil

        do {
            let address = try await BonjourResolver.resolve(found.endpoint)
            let host = MediaHost(deviceID: found.deviceID,
                                 name: found.name,
                                 address: address.host,
                                 port: address.port,
                                 platformName: found.platformName)
            await connect(toHost: host)
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    /// Connects straight to an address, skipping discovery. Used by the test
    /// scripts, and the way back in on a network that blocks Bonjour.
    func connectDirectly(address: String, port: UInt16) async {
        do {
            let probe = MediaClient(host: MediaHost(deviceID: "direct",
                                                    name: "Direct",
                                                    address: address,
                                                    port: port,
                                                    platformName: ""),
                                    token: nil)
            let info = try await probe.info()
            let host = MediaHost(deviceID: info.deviceID,
                                 name: info.deviceName,
                                 address: address,
                                 port: port,
                                 platformName: "ios")
            await connect(toHost: host)
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    private func connect(toHost host: MediaHost) async {
        connection = .connecting(host.name)
        syncSummary = nil

        do {
            var token = TrustStore.shared.peer(withID: host.deviceID)?.token
            if token == nil {
                let anonymous = MediaClient(host: host, token: nil)
                let response = try await anonymous.pair(TransferProtocol.PairRequest(
                    deviceID: DeviceIdentity.current.id,
                    deviceName: DeviceIdentity.current.name,
                    platformName: DeviceIdentity.current.platformName))

                guard response.accepted, let granted = response.token else {
                    connection = .failed("\(host.name) did not allow this Apple TV in.")
                    return
                }
                token = granted
            }

            let client = MediaClient(host: host, token: token)
            self.client = client
            self.host = host

            state.lastHostDeviceID = host.deviceID
            state.lastHostName = host.name
            saveState()

            try await refreshLibrary()

            connection = .connected(host)
            NSLog("[Cassowary] connected to %@ (%d games)", host.name, state.games.count)
            startSyncLoop()
            await syncNow()
            prefetchFavorites()
        } catch {
            NSLog("[Cassowary] connect failed: %@", error.localizedDescription)
            connection = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        syncTask?.cancel()
        syncTask = nil
        client = nil
        host = nil
        connection = .idle
    }

    func forgetHost() {
        disconnect()
        if let id = state.lastHostDeviceID {
            TrustStore.shared.remove(deviceID: id)
        }
        state.lastHostDeviceID = nil
        state.lastHostName = nil
        saveState()
    }

    // MARK: - Library

    var games: [LocalGame] {
        state.games.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var systems: [String] {
        Array(Set(state.games.values.map(\.systemName))).sorted()
    }

    private func refreshLibrary() async throws {
        guard let client else { return }
        libraryIsLoading = true
        defer { libraryIsLoading = false }

        let manifest = try await client.library()
        let known = state.games

        var updated: [String: LocalGame] = [:]
        for entry in manifest.games {
            if var existing = known[entry.id] {
                // Keep what is local — what is downloaded and how it was
                // played — and take the rest from the host.
                existing.title = entry.title
                existing.fileName = entry.fileName
                existing.systemIdentifier = entry.systemIdentifier
                existing.systemName = entry.systemName
                existing.size = entry.size
                existing.hasArtwork = entry.hasArtwork
                updated[entry.id] = existing
            } else {
                updated[entry.id] = LocalGame(id: entry.id,
                                              title: entry.title,
                                              fileName: entry.fileName,
                                              systemIdentifier: entry.systemIdentifier,
                                              systemName: entry.systemName,
                                              size: entry.size,
                                              hasArtwork: entry.hasArtwork,
                                              downloadedAt: nil,
                                              lastPlayedAt: nil,
                                              playCount: 0,
                                              favorite: false)
            }
        }

        // A game that is gone from the host stays only if it is still here.
        for (id, game) in known where updated[id] == nil && game.isDownloaded {
            updated[id] = game
        }

        state.games = updated
        saveState()
        refreshPlayInfo()
        loadArtwork()
        updateCacheSize()
    }

    // MARK: - Artwork

    private func loadArtwork() {
        for game in games where game.hasArtwork && artwork[game.id] == nil && !artworkFetches.contains(game.id) {
            let file = artworkURL(gameID: game.id)
            if let image = UIImage(contentsOfFile: file.path) {
                artwork[game.id] = image
                continue
            }
            fetchArtwork(for: game)
        }
    }

    private func fetchArtwork(for game: LocalGame) {
        guard let client, !artworkFetches.contains(game.id) else { return }
        artworkFetches.insert(game.id)

        Task { [weak self] in
            defer { self?.artworkFetches.remove(game.id) }
            guard let data = try? await client.artwork(gameID: game.id), !data.isEmpty else { return }

            let folder = SharingPaths.mediaCacheDirectory.deletingLastPathComponent()
                .appendingPathComponent("Artwork", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = self?.artworkURL(gameID: game.id) ?? folder.appendingPathComponent("\(game.id).png")
            try? data.write(to: file, options: .atomic)

            if let image = UIImage(data: data) {
                self?.artwork[game.id] = image
            }
        }
    }

    private func artworkURL(gameID: String) -> URL {
        SharingPaths.mediaCacheDirectory.deletingLastPathComponent()
            .appendingPathComponent("Artwork", isDirectory: true)
            .appendingPathComponent("\(gameID).png")
    }

    // MARK: - Downloads

    func progress(for id: String) -> Double? { downloads[id] }

    func download(_ game: LocalGame) async {
        guard let client, downloads[game.id] == nil else { return }
        downloads[game.id] = 0
        defer { downloads.removeValue(forKey: game.id) }

        let folder = SharingPaths.cachedGameFolder(id: game.id)
        let destination = folder.appendingPathComponent(game.fileName)
        let part = folder.appendingPathComponent(game.fileName + ".part")

        do {
            try await client.download(gameID: game.id, size: game.size, to: part) { value in
                Task { @MainActor in self.downloads[game.id] = value }
            }

            // The id is the content's hash, so a file that does not match is
            // not the game. Never hand a bad file to a core.
            let partURL = part
            let hash = await Task.detached(priority: .utility) {
                Hashing.sha256(ofFileAt: partURL)
            }.value

            guard hash == game.id else {
                try? FileManager.default.removeItem(at: part)
                syncSummary = "The download did not match its fingerprint, so it was thrown away."
                return
            }

            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.moveItem(at: part, to: destination)

            var updated = game
            updated.downloadedAt = Date()
            state.games[game.id] = updated
            saveState()
            updateCacheSize()
            evictIfNeeded(keeping: game.id)
        } catch {
            // A half file is left where it is: the next try resumes from it.
            // The hash check above is what rejects a bad download.
            syncSummary = "Download failed: \(error.localizedDescription)"
        }
    }

    func removeDownload(_ game: LocalGame) {
        try? FileManager.default.removeItem(at: SharingPaths.cachedGameFolder(id: game.id))
        var updated = game
        updated.downloadedAt = nil
        state.games[game.id] = updated
        saveState()
        updateCacheSize()
    }

    func playableURL(for game: LocalGame) -> URL? {
        guard game.isDownloaded else { return nil }
        let url = SharingPaths.cachedGameFolder(id: game.id).appendingPathComponent(game.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Cache budget

    var cacheBudget: Int64 {
        let stored = UserDefaults.standard.object(forKey: SharingDefaults.cacheBudgetKey) as? Int64
        return stored ?? SharingDefaults.defaultCacheBudget
    }

    func setCacheBudget(_ bytes: Int64) {
        UserDefaults.standard.set(bytes, forKey: SharingDefaults.cacheBudgetKey)
        evictIfNeeded(keeping: nil)
    }

    private func updateCacheSize() {
        let fm = FileManager.default
        var total: Int64 = 0
        if let files = try? fm.contentsOfDirectory(at: SharingPaths.mediaCacheDirectory,
                                                   includingPropertiesForKeys: [.fileSizeKey],
                                                   options: [.skipsHiddenFiles]) {
            for folder in files {
                guard let contents = try? fm.contentsOfDirectory(at: folder,
                                                                  includingPropertiesForKeys: [.fileSizeKey],
                                                                  options: [.skipsHiddenFiles]) else { continue }
                for file in contents {
                    total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            }
        }
        cacheBytes = total
    }

    /// Makes room by removing the games played least recently, never the one
    /// being downloaded or the one being played.
    private func evictIfNeeded(keeping keepID: String?) {
        var downloaded = games.filter { $0.isDownloaded && $0.id != keepID }
        guard cacheBytes > cacheBudget else { return }

        downloaded.sort { lhs, rhs in
            let left = lhs.lastPlayedAt ?? lhs.downloadedAt ?? .distantPast
            let right = rhs.lastPlayedAt ?? rhs.downloadedAt ?? .distantPast
            return left < right
        }

        for game in downloaded {
            guard cacheBytes > cacheBudget else { break }
            removeDownload(game)
            syncSummary = "Removed \(game.title) to stay inside the cache budget."
        }
    }

    // MARK: - Playing

    /// Puts the vault's save state beside the ROM the engine is about to open.
    func prepareForPlay(_ game: LocalGame) {
        guard let rom = playableURL(for: game) else { return }
        let vault = stateURL(gameID: game.id)
        let beside = SaveStore.saveStateURL(for: rom)

        let fm = FileManager.default
        let vaultDate = (try? vault.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let besideDate = (try? beside.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast

        if fm.fileExists(atPath: vault.path), vaultDate > besideDate {
            try? fm.removeItem(at: beside)
            try? fm.copyItem(at: vault, to: beside)
        }
    }

    /// Takes the save state back to the vault, records the session, and hands
    /// everything to the phone.
    func finishPlaying(_ game: LocalGame) {
        if let rom = playableURL(for: game) {
            let beside = SaveStore.saveStateURL(for: rom)
            let vault = stateURL(gameID: game.id)
            if FileManager.default.fileExists(atPath: beside.path) {
                try? FileManager.default.createDirectory(at: vault.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: vault)
                try? FileManager.default.copyItem(at: beside, to: vault)
            }
        }

        var info = SaveStore.loadPlayInfo(gameID: game.id)
        info.lastPlayedAt = Date()
        info.playCount += 1
        SaveStore.savePlayInfo(info, gameID: game.id)

        if var updated = state.games[game.id] {
            updated.lastPlayedAt = info.lastPlayedAt
            updated.playCount = info.playCount
            state.games[game.id] = updated
            saveState()
        }

        Task { await syncNow() }
    }

    func toggleFavorite(_ game: LocalGame) {
        var info = SaveStore.loadPlayInfo(gameID: game.id)
        info.favorite.toggle()
        SaveStore.savePlayInfo(info, gameID: game.id)

        if var updated = state.games[game.id] {
            updated.favorite = info.favorite
            state.games[game.id] = updated
            saveState()
        }

        Task { await syncNow() }
    }

    /// A readable name for a game id, for the conflict prompt.
    func title(forGameID id: String) -> String {
        state.games[id]?.title ?? "A game"
    }

    // MARK: - Saves

    /// Where a game's saves live on the TV: the vault, so throwing the cache
    /// away does not throw the saves away with it.
    private var locations: [GameLocation] {
        state.games.values.map { GameLocation(id: $0.id, romURL: vaultROMURL(gameID: $0.id)) }
    }

    private func vaultROMURL(gameID: String) -> URL {
        SharingPaths.tvSaveVault.appendingPathComponent("\(gameID).rom")
    }

    private func stateURL(gameID: String) -> URL {
        SaveStore.saveStateURL(for: vaultROMURL(gameID: gameID))
    }

    private func refreshPlayInfo() {
        for (id, game) in state.games {
            let info = SaveStore.loadPlayInfo(gameID: id)
            if info.lastPlayedAt != game.lastPlayedAt || info.playCount != game.playCount || info.favorite != game.favorite {
                var updated = game
                updated.lastPlayedAt = info.lastPlayedAt
                updated.playCount = info.playCount
                updated.favorite = info.favorite
                state.games[id] = updated
            }
        }
    }

    func syncNow() async {
        guard let client else { return }

        // Pick up games added on the phone since the last look.
        try? await refreshLibrary()

        let result = await SaveSyncEngine.sync(games: locations, with: client)
        pendingUploads = SaveIndexStore.shared.pendingCount()
        conflicts = ConflictStore.shared.conflicts
        syncSummary = result.summary
        refreshPlayInfo()
    }

    func resolve(_ conflict: SaveConflict, choice: SaveSyncEngine.ConflictChoice) {
        SaveSyncEngine.resolve(conflict, choice: choice, games: locations)

        // A settled state should be sitting beside the game if it is here.
        if choice != .keepLocal,
           let game = state.games[conflict.gameID],
           let rom = playableURL(for: game) {
            let vault = stateURL(gameID: game.id)
            let beside = SaveStore.saveStateURL(for: rom)
            try? FileManager.default.removeItem(at: beside)
            if FileManager.default.fileExists(atPath: vault.path) {
                try? FileManager.default.copyItem(at: vault, to: beside)
            }
        }

        conflicts = ConflictStore.shared.conflicts
        Task { await syncNow() }
    }

    private func startSyncLoop() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard let self, self.connection.isConnected else { return }
                await self.syncNow()
            }
        }
    }

    /// Downloads the games marked as favorites without being asked, so they
    /// are ready before they are picked. Budget and room come first.
    private func prefetchFavorites() {
        let wanted = games.filter { $0.favorite && !$0.isDownloaded }
        guard !wanted.isEmpty else { return }

        Task { [weak self] in
            for game in wanted {
                guard let self, self.connection.isConnected else { return }
                guard self.progress(for: game.id) == nil else { continue }
                guard self.cacheBytes + game.size < self.cacheBudget else { continue }
                await self.download(game)
            }
        }
    }

    // MARK: - State on disk

    private func saveState() {
        guard let data = try? TransferProtocol.encoder.encode(state) else { return }
        try? data.write(to: SharingPaths.tvLibraryIndex, options: .atomic)
    }

    private static func loadState() -> State {
        guard let data = try? Data(contentsOf: SharingPaths.tvLibraryIndex),
              let state = try? TransferProtocol.decoder.decode(State.self, from: data)
        else { return State() }
        return state
    }
}
