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
import OpenEmuBase
import OpenEmuKit

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

    /// One game, as this TV knows it. It stays in the list even when the
    /// device it came from is away: what is here is this TV's library, not a
    /// window onto someone else's.
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
        /// Which source this came from. Optional so a library saved before
        /// sources existed still loads.
        var sourceDeviceID: String?
        var sourceName: String?

        var isDownloaded: Bool { downloadedAt != nil }
    }

    /// A source this TV can borrow games from. The phone is one; a network
    /// mount would be another, and both would be listed here.
    struct KnownHost: Codable, Hashable, Identifiable {
        var deviceID: String
        var name: String
        var platformName: String
        var lastConnectedAt: Date

        var id: String { deviceID }

        var platformLabel: String {
            switch platformName {
            case "ios":  return "iPhone or iPad"
            case "mac":  return "Mac"
            default:     return "Phone"
            }
        }
    }

    struct State: Codable {
        var games: [String: LocalGame] = [:]
        var hosts: [String: KnownHost] = [:]
        var lastHostDeviceID: String?
        var lastHostName: String?
    }

    @Published private(set) var state = State()
    @Published private(set) var connection: Connection = .idle
    /// Download progress by game id, 0…1.
    @Published private(set) var downloads: [String: Double] = [:]
    @Published private(set) var syncSummary: String?
    @Published private(set) var conflicts: [SaveConflict] = []
    /// Saves the connected source has not had yet.
    @Published private(set) var pendingUploads = 0
    /// Saves waiting for a source that is not the connected one: they are
    /// for games only another device has.
    @Published private(set) var savesWaitingElsewhere = 0
    /// When saves last synced without an error. Kept across launches, so
    /// the library can say how fresh its saves are.
    @Published private(set) var lastSyncedAt: Date? =
        UserDefaults.standard.object(forKey: TVStore.lastSyncedKey) as? Date
    /// The RetroAchievements account games here sign in as, and the device
    /// it came from. The TV has no sign-in of its own: typing a password
    /// with the remote is miserable, so it borrows the phone's.
    @Published private(set) var retroAchievementsAccount: String?
    @Published private(set) var retroAchievementsSource: String?
    /// Whether to use a sign-in a source shares. Switching it off signs out.
    @Published private(set) var usesSharedRetroAchievements =
        UserDefaults.standard.object(forKey: TVStore.useSharedRAKey) as? Bool ?? true
    private static let useSharedRAKey = "cassowary.tv.useSharedRetroAchievements"
    private static let raSourceIDKey = "cassowary.tv.retroAchievementsSourceID"
    private static let raSourceNameKey = "cassowary.tv.retroAchievementsSourceName"

    /// True while a sync is running.
    @Published private(set) var isSyncing = false
    private var syncsRunning = 0
    private static let lastSyncedKey = "cassowary.tv.lastSyncedAt"
    @Published private(set) var cacheBytes: Int64 = 0
    @Published private(set) var artwork: [String: UIImage] = [:]
    @Published private(set) var libraryIsLoading = false

    let browser = PeerBrowser()

    private var client: MediaClient?
    private var host: MediaHost?
    private var syncTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var playingGameID: String?
    private var recordedPlay = false
    /// Set when the person disconnects or forgets a source on purpose, so the
    /// reconnect loop does not drag them straight back in.
    private var autoReconnectPaused = false
    /// Failed syncs in a row. One is allowed to pass; two mean the phone is
    /// really gone.
    private var syncFailures = 0
    private var cancellables: Set<AnyCancellable> = []
    /// Games with an artwork download in flight, so the grid can show it.
    @Published private(set) var artworkFetches: Set<String> = []
    /// Games the source had no art for, this launch. Without this every sync
    /// would re-ask for every game the phone never had art for.
    private var artworkMissed: Set<String> = []

    private init() {
        state = Self.loadState()
        updateCacheSize()
    }

    // MARK: - Starting

    func start() {
        conflicts = ConflictStore.shared.conflicts
        loadRetroAchievementsAccount()
        browser.start()
        importBundledDemos()
        // A killed app may have left newer saves in the disposable cache.
        // One scan after filing them all: a scan per game is slow with a big
        // library.
        for game in games where game.isDownloaded {
            fileSessionSaves(game, scan: false)
        }
        _ = SaveStore.scan(games: locations)
        startReconnectLoop()

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
                       let known = self.state.hosts[id],
                       let match = self.discovered(known),
                       !self.isConnecting {
                        Task { await self.connect(to: match) }
                    }
                    return
                }
            }
            .store(in: &cancellables)

        if let id = state.lastHostDeviceID,
           let known = state.hosts[id],
           let match = discovered(known) {
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

    /// The discovered host that is this known source, if it is around. The id
    /// comes from the Bonjour TXT record when there is one and from the
    /// service name when there is not, so both are compared.
    private func discovered(_ known: KnownHost) -> FoundHost? {
        browser.hosts.first { $0.deviceID == known.deviceID || $0.name == known.name }
    }

    private var isConnecting: Bool {
        if case .connecting = connection { return true }
        return false
    }

    // MARK: - Connecting

    func connect(to found: FoundHost) async {
        guard !isConnecting else { return }
        // Reaching this point means someone asked for this source, so the
        // reconnect loop may look after it again.
        autoReconnectPaused = false
        connection = .connecting(found.name)
        syncSummary = nil

        do {
            let host = try await BonjourResolver.identify(found)
            await connect(toHost: host)
        } catch {
            connection = .failed(Self.connectionMessage(for: error, host: found.name))
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
            connection = .failed(Self.connectionMessage(for: error, host: "the source"))
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
            state.hosts[host.deviceID] = KnownHost(deviceID: host.deviceID,
                                                   name: host.name,
                                                   platformName: host.platformName,
                                                   lastConnectedAt: Date())
            saveState()

            try await refreshLibrary()

            connection = .connected(host)
            NSLog("[Cassowary] connected to %@ (%d games)", host.name, state.games.count)
            startSyncLoop()
            await syncNow()
            prefetchFavorites()
        } catch {
            NSLog("[Cassowary] connect failed: %@", error.localizedDescription)
            connection = .failed(Self.connectionMessage(for: error, host: host.name))
        }
    }

    /// Turns a networking error into something a person can act on. The one
    /// that matters: iOS stops serving when the phone's app is put away, so a
    /// timeout usually means "keep the app open", not a broken network.
    static func connectionMessage(for error: Error, host: String) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut, NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost:
                return "Can't reach \(host). Keep Cassowary open on it with sharing switched on, and check both devices are on the same Wi-Fi."
            default:
                break
            }
        }
        return error.localizedDescription
    }

    func disconnect() {
        syncTask?.cancel()
        syncTask = nil
        client = nil
        host = nil
        autoReconnectPaused = true
        connection = .idle
    }

    func forgetHost() {
        if let id = state.lastHostDeviceID {
            forgetHost(deviceID: id)
        } else {
            disconnect()
        }
    }

    /// Forgets one remembered source, leaving the rest of the library alone.
    func forgetHost(deviceID: String) {
        TrustStore.shared.remove(deviceID: deviceID)
        state.hosts.removeValue(forKey: deviceID)

        if state.lastHostDeviceID == deviceID {
            state.lastHostDeviceID = nil
            state.lastHostName = nil
            disconnect()
        }

        saveState()
    }

    /// Every source this TV has connected to before, newest first.
    var knownHosts: [KnownHost] {
        state.hosts.values.sorted { $0.lastConnectedAt > $1.lastConnectedAt }
    }

    /// Whether a game's source is the one right now. The demo game has no
    /// source, so it is always available.
    /// False only when the game's own source is connected and no longer
    /// lists it: then it cannot be downloaded again, and its saves have
    /// nowhere to go. Unknown counts as still there.
    func sourceStillHas(_ game: LocalGame) -> Bool {
        guard let source = game.sourceDeviceID,
              case .connected(let host) = connection,
              source == host.deviceID
        else { return true }
        return hostGameIDs.contains(game.id)
    }

    func isSourceAvailable(for game: LocalGame) -> Bool {
        guard let source = game.sourceDeviceID else { return true }
        guard case .connected(let host) = connection else { return false }
        return source == host.deviceID
    }

    // MARK: - Library

    var games: [LocalGame] {
        state.games.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var systems: [String] {
        Array(Set(state.games.values.map(\.systemName))).sorted()
    }

    /// The game that ships with the app belongs in the library like any other:
    /// it is already here, it needs no source, and it is the way to check the
    /// TV without a phone.
    func importBundledDemos() {
        for demo in TVDemoLibrary.load() {
            guard let hash = Hashing.sha256(ofFileAt: demo.url), state.games[hash] == nil else { continue }

            let size = Int64((try? demo.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let systemID = TVDemoLibrary.systemPlugin(forExtension: demo.url.pathExtension)?.systemIdentifier ?? ""

            state.games[hash] = LocalGame(id: hash,
                                          title: demo.title,
                                          fileName: demo.url.lastPathComponent,
                                          systemIdentifier: systemID,
                                          systemName: demo.systemName,
                                          size: size,
                                          hasArtwork: false,
                                          downloadedAt: Date(),
                                          lastPlayedAt: nil,
                                          playCount: 0,
                                          favorite: false,
                                          sourceDeviceID: nil,
                                          sourceName: "This Apple TV")
        }
        loadArtwork()
        saveState()
    }

    private func refreshLibrary() async throws {
        guard let client else { return }
        libraryIsLoading = true
        defer { libraryIsLoading = false }

        let manifest = try await client.library()
        let host = self.host

        var updated = state.games
        for entry in manifest.games {
            if var existing = updated[entry.id] {
                // Keep what is local — what is downloaded and how it was
                // played — and take the rest from the source.
                existing.title = entry.title
                existing.fileName = entry.fileName
                existing.systemIdentifier = entry.systemIdentifier
                existing.systemName = entry.systemName
                existing.size = entry.size
                existing.hasArtwork = entry.hasArtwork
                existing.sourceDeviceID = host?.deviceID ?? existing.sourceDeviceID
                existing.sourceName = host?.name ?? existing.sourceName
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
                                              favorite: false,
                                              sourceDeviceID: host?.deviceID,
                                              sourceName: host?.name)
            }
        }

        // A game the source no longer lists is kept once it is downloaded:
        // this TV's library is its own, and a game that is here plays here
        // regardless. One that was never copied down cannot be played or
        // fetched any more, so it goes rather than sit there as a ghost.
        let listed = Set(manifest.games.map(\.id))
        if let hostID = host?.deviceID {
            updated = updated.filter { id, game in
                game.sourceDeviceID != hostID || game.isDownloaded || listed.contains(id)
            }
        }
        hostGameIDs = listed

        state.games = updated
        saveState()
        refreshPlayInfo()
        loadArtwork()
        updateCacheSize()
    }

    // MARK: - Artwork

    /// Whether an artwork download for this game is running, for the tile.
    func isFetchingArtwork(_ id: String) -> Bool { artworkFetches.contains(id) }

    /// Whether this TV has a save state filed for the game, for the tile's
    /// bookmark. The vault is what survives the cache being thrown away.
    func hasLocalSaveState(for game: LocalGame) -> Bool {
        FileManager.default.fileExists(atPath: stateURL(gameID: game.id).path)
    }

    /// Fetch one game's art again, even if the source came up empty before.
    func retryArtwork(for game: LocalGame) {
        artworkMissed.remove(game.id)
        if artwork[game.id] == nil {
            fetchArtwork(for: game)
        }
    }

    private func loadArtwork() {
        for game in games where artwork[game.id] == nil
            && !artworkFetches.contains(game.id)
            && !artworkMissed.contains(game.id) {
            let file = artworkURL(gameID: game.id)
            if let image = UIImage(contentsOfFile: file.path) {
                artwork[game.id] = image
                continue
            }
            // Without a connection there is nothing to ask. When connected,
            // every game missing art is asked about — not only ones the
            // manifest flagged — because that flag goes stale when the phone
            // downloads art after the TV last looked.
            if client != nil {
                fetchArtwork(for: game)
            }
        }
    }

    private func fetchArtwork(for game: LocalGame) {
        guard let client, !artworkFetches.contains(game.id) else { return }
        artworkFetches.insert(game.id)

        Task { [weak self] in
            defer { self?.artworkFetches.remove(game.id) }
            guard let data = try? await client.artwork(gameID: game.id), !data.isEmpty else {
                self?.artworkMissed.insert(game.id)
                return
            }

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
        guard let client else {
            syncSummary = "Connect to a source to download this game."
            return
        }
        guard downloads[game.id] == nil else { return }
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
        // A game that belongs to this TV is re-copied from the bundle on the
        // next launch, so there is nothing to remove.
        guard game.sourceDeviceID != nil else { return }

        try? FileManager.default.removeItem(at: SharingPaths.cachedGameFolder(id: game.id))
        var updated = game
        updated.downloadedAt = nil
        state.games[game.id] = updated
        saveState()
        updateCacheSize()
    }

    /// Forgets a game its source no longer has: the download, its saves on
    /// this TV and their records, its play history, art and any conflict.
    /// Without this its saves waited for that source for ever.
    func forget(_ game: LocalGame) {
        guard game.sourceDeviceID != nil else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: SharingPaths.cachedGameFolder(id: game.id))
        let vaultROM = vaultROMURL(gameID: game.id)
        for kind in SaveKind.allStateKinds {
            let state = SaveStore.saveStateURL(for: vaultROM, kind: kind)
            try? fm.removeItem(at: state)
            try? fm.removeItem(at: SaveStore.screenshotURL(forStateURL: state))
        }
        for battery in SaveStore.batterySaveURLs(forROMName: vaultROM.lastPathComponent) {
            try? fm.removeItem(at: battery.url)
        }
        SaveStore.deletePlayInfo(gameID: game.id)
        for key in SaveIndexStore.shared.allRecords().keys where key.hasPrefix(game.id + "|") {
            SaveIndexStore.shared.remove(gameID: game.id, kind: String(key.dropFirst(game.id.count + 1)))
        }
        for conflict in ConflictStore.shared.conflicts where conflict.gameID == game.id {
            ConflictStore.shared.remove(id: conflict.id)
        }
        conflicts = ConflictStore.shared.conflicts
        try? fm.removeItem(at: artworkURL(gameID: game.id))
        artwork[game.id] = nil

        state.games[game.id] = nil
        saveState()
        updateCacheSize()
        let pending = SaveIndexStore.shared.pendingCount(forGames: hostGameIDs)
        pendingUploads = pending
        savesWaitingElsewhere = SaveIndexStore.shared.pendingCount() - pending
        note("Forgot \(game.title).")
    }

    func playableURL(for game: LocalGame) -> URL? {
        guard game.isDownloaded else { return nil }
        let url = fileURL(for: game)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Where a game's ROM lives. A game that belongs to this TV (the bundled
    /// demo) sits in its own folder; anything borrowed sits in the cache.
    private func fileURL(for game: LocalGame) -> URL {
        if game.sourceDeviceID == nil {
            return SharingPaths.supportDirectory
                .appendingPathComponent("Demo Games", isDirectory: true)
                .appendingPathComponent(game.fileName)
        }
        return SharingPaths.cachedGameFolder(id: game.id).appendingPathComponent(game.fileName)
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

    /// Stages the vault's save states beside the ROM the engine is about to
    /// open, every slot and their screenshots.
    ///
    /// The vault is the source of truth on this device: sync writes to the
    /// vault, never beside the ROM, so whatever the vault holds is what the
    /// game opens with.
    func prepareForPlay(_ game: LocalGame) {
        guard let rom = playableURL(for: game) else { return }
        playingGameID = game.id
        recordedPlay = false
        for kind in SaveKind.allStateKinds {
            stageVaultFile(stateURL(gameID: game.id, kind: kind),
                           to: SaveStore.saveStateURL(for: rom, kind: kind))
        }
    }

    private func stageVaultFile(_ vault: URL, to beside: URL) {
        // No vault copy means the slot is empty or was deleted, here or on
        // the phone. A copy left beside the ROM from an earlier session would
        // otherwise load, and be filed back into the vault afterwards.
        guard FileManager.default.fileExists(atPath: vault.path) else {
            try? FileManager.default.removeItem(at: beside)
            try? FileManager.default.removeItem(at: SaveStore.screenshotURL(forStateURL: beside))
            return
        }
        try? FileManager.default.removeItem(at: beside)
        try? FileManager.default.copyItem(at: vault, to: beside)
        // Screenshots ride along so the menus can show them.
        let vaultShot = SaveStore.screenshotURL(forStateURL: vault)
        if FileManager.default.fileExists(atPath: vaultShot.path) {
            let besideShot = SaveStore.screenshotURL(forStateURL: beside)
            try? FileManager.default.removeItem(at: besideShot)
            try? FileManager.default.copyItem(at: vaultShot, to: besideShot)
        }
    }

    /// Takes the save states back to the vault, records the session, and
    /// hands everything to the phone.
    func finishPlaying(_ game: LocalGame) {
        fileSessionSaves(game)
        recordPlay(game)
        Task { await syncNow() }
    }

    /// Copies this session's save states from beside the ROM into the vault.
    /// Safe to call more than once: a vault copy newer than the one beside
    /// the ROM (one the phone sent) is kept.
    func fileSessionSaves(_ game: LocalGame, scan: Bool = true) {
        if let rom = playableURL(for: game) {
            for kind in SaveKind.allStateKinds {
                fileVaultFile(SaveStore.saveStateURL(for: rom, kind: kind),
                              to: stateURL(gameID: game.id, kind: kind))
            }
            // Filing the vault copies changed what is on disk. Scan again so
            // the versions remember the new files and mark them for upload —
            // without it a session played here would never reach the phone.
            if scan {
                _ = SaveStore.scan(games: locations)
            }
        }
    }

    /// Notes that the game was played, for Continue Playing and the phone.
    /// Counts the session once however often it is called.
    func recordPlay(_ game: LocalGame) {
        guard playingGameID == game.id else { return }
        var info = SaveStore.loadPlayInfo(gameID: game.id)
        if recordedPlay {
            info.lastPlayedAt = Date()
        } else {
            info.recordPlay(on: DeviceIdentity.current.id)
            recordedPlay = true
        }
        SaveStore.savePlayInfo(info, gameID: game.id)

        if var updated = state.games[game.id] {
            updated.lastPlayedAt = info.lastPlayedAt
            updated.playCount = info.playCount
            state.games[game.id] = updated
            saveState()
        }
    }

    /// Deletes a save-state slot here, the copy the running game uses and
    /// the vault's alike, and tells the phone at the next sync.
    func deleteState(_ game: LocalGame, kind: String) {
        if let rom = playableURL(for: game) {
            let beside = SaveStore.saveStateURL(for: rom, kind: kind)
            try? FileManager.default.removeItem(at: beside)
            try? FileManager.default.removeItem(at: SaveStore.screenshotURL(forStateURL: beside))
        }
        SaveStore.deleteState(gameID: game.id, romURL: vaultROMURL(gameID: game.id), kind: kind)
        Task { await syncNow() }
    }

    func toggleFavorite(_ game: LocalGame) {
        var info = SaveStore.loadPlayInfo(gameID: game.id)
        info.setFavorite(!info.favorite)
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

    /// Whether this TV has a core that can run the game's system. A game
    /// whose system has no core here can still be downloaded, but there would
    /// be nothing to start, so the grid says so first.
    func hasCore(for game: LocalGame) -> Bool {
        !OECorePlugin.corePlugins(forSystemIdentifier: game.systemIdentifier).isEmpty
    }

    /// Puts a line on the library screen: used for things like a missing core.
    func note(_ message: String) {
        syncSummary = message
    }

    // MARK: - Saves

    /// Where a game's saves live on the TV: the vault, so throwing the cache
    /// away does not throw the saves away with it. Games that belong to this
    /// TV and nowhere else (the bundled demo) are left out: there is no other
    /// device that would have the same game.
    /// The games the connected source listed last time, so a sync only
    /// offers it saves for games it has.
    private var hostGameIDs: Set<String> = []

    private var locations: [GameLocation] {
        state.games.values
            .filter { $0.sourceDeviceID != nil }
            .map { GameLocation(id: $0.id, romURL: vaultROMURL(gameID: $0.id)) }
    }

    private func vaultROMURL(gameID: String) -> URL {
        SharingPaths.tvSaveVault.appendingPathComponent("\(gameID).rom")
    }

    private func stateURL(gameID: String, kind: String = SaveKind.state) -> URL {
        SaveStore.saveStateURL(for: vaultROMURL(gameID: gameID), kind: kind)
    }

    private func fileVaultFile(_ beside: URL, to vault: URL) {
        guard FileManager.default.fileExists(atPath: beside.path) else { return }
        // Repeated filing must keep a newer copy received from the phone.
        let besideDate = try? beside.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let vaultDate = try? vault.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let vaultDate, let besideDate, besideDate <= vaultDate { return }
        try? FileManager.default.createDirectory(at: vault.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: vault)
        try? FileManager.default.copyItem(at: beside, to: vault)
        let besideShot = SaveStore.screenshotURL(forStateURL: beside)
        if FileManager.default.fileExists(atPath: besideShot.path) {
            let vaultShot = SaveStore.screenshotURL(forStateURL: vault)
            try? FileManager.default.removeItem(at: vaultShot)
            try? FileManager.default.copyItem(at: besideShot, to: vaultShot)
        }
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
        // Several can overlap (the reconnect loop, leaving a game, Sync Now),
        // so count them rather than flip one flag.
        syncsRunning += 1
        isSyncing = true
        defer {
            syncsRunning -= 1
            isSyncing = syncsRunning > 0
        }

        // Pick up games added on the phone since the last look, and its
        // RetroAchievements sign-in if it shares one.
        try? await refreshLibrary()
        await refreshRetroAchievements(from: client)

        // Only the games this source has: the phone answers 404 for any
        // other, and that would show as an error on every sync. Saves for a
        // game from elsewhere wait for its own source.
        let result = await SaveSyncEngine.sync(games: locations.filter { hostGameIDs.contains($0.id) },
                                               with: client)
        let pending = SaveIndexStore.shared.pendingCount(forGames: hostGameIDs)
        pendingUploads = pending
        savesWaitingElsewhere = SaveIndexStore.shared.pendingCount() - pending
        conflicts = ConflictStore.shared.conflicts
        // "Already in sync" is not news: the status line says when it last
        // synced instead.
        syncSummary = result.movedAny ? result.summary : nil
        refreshPlayInfo()

        #if DEBUG
        // Forgets every game the source no longer has, to check forgetting
        // without a remote. Only set from the command line.
        if UserDefaults.standard.bool(forKey: "cassowary.testForgetGone") {
            games.filter { !sourceStillHas($0) }.forEach(forget)
        }
        #endif

        // One failed sync can be a hiccup — the phone's app may have just been
        // put away and brought back. Two in a row means the link is really
        // gone: the reconnect loop takes over and the status says why.
        if let error = result.error {
            syncFailures += 1
            let message = Self.connectionMessage(for: error, host: host?.name ?? "the phone")
            if syncFailures >= 2 {
                connection = .failed(message)
            } else {
                syncSummary = message
            }
        } else {
            syncFailures = 0
            lastSyncedAt = Date()
            UserDefaults.standard.set(lastSyncedAt, forKey: Self.lastSyncedKey)
            if case .failed = connection, let host {
                connection = .connected(host)
            }
        }
    }

    // MARK: - RetroAchievements

    /// Takes the source's shared sign-in, or lets go of one it no longer
    /// shares. A sign-in from another source is left alone, and so is
    /// everything when the source cannot be reached.
    private func refreshRetroAchievements(from client: MediaClient) async {
        guard usesSharedRetroAchievements, let host else { return }
        let share: TransferProtocol.RetroAchievementsShare?
        do {
            share = try await client.retroAchievementsShare()
        } catch {
            return
        }

        let defaults = UserDefaults.standard
        if let share {
            RetroAchievementsCredentialStore.save(username: share.username,
                                                  displayName: share.displayName,
                                                  token: share.token)
            RetroAchievementsCredentialStore.hardcoreEnabled = share.hardcore
            defaults.set(host.deviceID, forKey: Self.raSourceIDKey)
            defaults.set(host.name, forKey: Self.raSourceNameKey)
        } else if defaults.string(forKey: Self.raSourceIDKey) == host.deviceID {
            signOutOfRetroAchievements()
        }
        loadRetroAchievementsAccount()
    }

    func setUsesSharedRetroAchievements(_ uses: Bool) {
        usesSharedRetroAchievements = uses
        UserDefaults.standard.set(uses, forKey: Self.useSharedRAKey)
        if uses {
            Task { await syncNow() }
        } else {
            signOutOfRetroAchievements()
            loadRetroAchievementsAccount()
        }
    }

    private func signOutOfRetroAchievements() {
        RetroAchievementsCredentialStore.clear()
        UserDefaults.standard.removeObject(forKey: Self.raSourceIDKey)
        UserDefaults.standard.removeObject(forKey: Self.raSourceNameKey)
    }

    private func loadRetroAchievementsAccount() {
        let credentials = RetroAchievementsCredentialStore.load()
        retroAchievementsAccount = credentials.isSignedIn ? credentials.displayName : nil
        retroAchievementsSource = credentials.isSignedIn
            ? UserDefaults.standard.string(forKey: Self.raSourceNameKey) : nil
    }

    func resolve(_ conflict: SaveConflict, choice: SaveSyncEngine.ConflictChoice) {
        SaveSyncEngine.resolve(conflict, choice: choice, games: locations)

        // A settled state should be sitting beside the game if it is here.
        if choice != .keepLocal,
           SaveKind.isStateKind(conflict.kind),
           let game = state.games[conflict.gameID],
           let rom = playableURL(for: game) {
            let vault = stateURL(gameID: game.id, kind: conflict.kind)
            let beside = SaveStore.saveStateURL(for: rom, kind: conflict.kind)
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

    /// Tries to get back to a source without being asked. The phone comes and
    /// goes — its app is put away, the network flaps — and the TV should find
    /// it again rather than needing a trip to the Sources screen. It only
    /// looks at hosts the browser can see right now, so a phone that is not
    /// there is not hammered.
    private func startReconnectLoop() {
        guard reconnectTask == nil else { return }

        reconnectTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard let self else { return }
                guard !self.autoReconnectPaused,
                      !self.connection.isConnected,
                      !self.isConnecting else { continue }

                // The remembered phone comes first. A TV that has never been
                // connected to anything takes the first source it sees, which
                // saves a tap on first setup.
                let remembered = self.state.lastHostDeviceID
                let target = remembered.flatMap { id in self.state.hosts[id].flatMap { self.discovered($0) } }
                    ?? (remembered == nil ? self.browser.hosts.first : nil)

                guard let target else { continue }
                await self.connect(to: target)
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
