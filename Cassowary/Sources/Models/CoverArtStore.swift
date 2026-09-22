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
import os.log

/// Which service an image came from.
enum CoverArtSource: String, Sendable {
    case libretro
    case screenScraper

    var displayName: String {
        switch self {
        case .libretro:       return "libretro-thumbnails"
        case .screenScraper:  return "ScreenScraper"
        }
    }
}

/// Settings and timings for cover art.
enum CoverArtSetting {
    /// Whether the library fetches art for its games on its own.
    static let automaticKey = "cassowary.downloadCoverArt"

    /// How long a game that was not found is left alone before trying again.
    /// Without this, every refresh would ask about every unmatched game.
    static let retryInterval: TimeInterval = 60 * 60 * 24 * 7

    /// How many images download at once. Enough to fill the grid quickly,
    /// few enough to be polite to a free server.
    static let parallelDownloads = 4

    /// How long a system's file listing is kept before it is read again. The
    /// server adds art rarely, so a month is soon enough.
    static let indexRefreshInterval: TimeInterval = 60 * 60 * 24 * 30
}

/// Downloads and caches cover art for the library.
///
/// This is the iOS side of the box art feature OpenEmu has: each game is
/// matched by name, its image is downloaded once, and it is kept on disk so
/// the grid can show it from then on. Games that are never matched are not
/// retried for a week.
///
/// Sources are tried in order:
///
///  1. libretro-thumbnails, which needs no account
///  2. ScreenScraper, when an app key is configured
@MainActor
final class CoverArtStore: ObservableObject {

    static let shared = CoverArtStore()

    /// Cover art for games, keyed by the ROM's URL.
    @Published private(set) var images: [URL: UIImage] = [:]

    /// Games with a download in flight, so the grid can show it.
    @Published private(set) var fetching: Set<URL> = []

    /// The last problem worth telling the user about — a refused
    /// ScreenScraper login, a full quota, no network. A game that simply was
    /// not found is not an error.
    @Published private(set) var lastError: String?

    /// Games tried this session and not found, so a refresh does not ask again.
    private var missed: Set<URL> = []

    /// Games waiting for a download slot.
    private var queue: [Game] = []
    private var runner: Task<Void, Never>?

    // MARK: - Where art lives

    /// The folder downloaded art is kept in.
    ///
    /// Application Support rather than Documents: this is the app's own cache,
    /// and Documents is the folder the user browses in the Files app.
    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CoverArt", isDirectory: true)
    }

    /// The image file for a game, whether or not it has been downloaded.
    /// The ROM's own file name keeps the folder readable.
    nonisolated static func imageURL(for game: Game) -> URL? {
        guard let system = game.system?.identifier else { return nil }
        return directory
            .appendingPathComponent(system, isDirectory: true)
            .appendingPathComponent("\(game.url.lastPathComponent).png")
    }

    /// The marker left behind when a lookup found nothing. Its date is when
    /// that happened.
    nonisolated static func missMarkerURL(for game: Game) -> URL? {
        imageURL(for: game)?.appendingPathExtension("missing")
    }

    // MARK: - Reading

    func image(for game: Game) -> UIImage? { images[game.id] }

    func hasArtwork(for game: Game) -> Bool { images[game.id] != nil }

    func isFetching(_ game: Game) -> Bool { fetching.contains(game.id) }

    /// How many of these games have no art yet.
    func missingCount(in games: [Game]) -> Int {
        games.filter { images[$0.id] == nil }.count
    }

    // MARK: - Loading and downloading

    /// Show what is already on disk, then fetch what is missing.
    ///
    /// Called by the library whenever its games are rescanned, so a game that
    /// was added a moment ago gets its art on the next pass.
    func refresh(for games: [Game], downloading: Bool) async {
        await loadFromDisk(games)
        if downloading {
            downloadMissing(for: games)
        }
    }

    /// Fetch one game's art now, even if it was looked up before.
    func download(for game: Game) {
        enqueue([game], force: true)
    }

    /// Fetch art for every game in the list that has none.
    func downloadMissing(for games: [Game]) {
        enqueue(games, force: false)
    }

    private func enqueue(_ games: [Game], force: Bool) {
        let candidates = games.filter { shouldDownload($0, force: force) }
        guard !candidates.isEmpty else { return }

        // A forced download starts from scratch: the old image and the "looked
        // for, not found" marker both go, so the lookup runs again.
        if force {
            for game in candidates {
                removeArtwork(for: game)
            }
        }

        queue.append(contentsOf: candidates)
        startRunner()
    }

    private func shouldDownload(_ game: Game, force: Bool) -> Bool {
        // No system plugin means no name to look up, so nothing to do.
        guard game.system?.identifier != nil else { return false }
        guard !fetching.contains(game.id), !queue.contains(where: { $0.id == game.id }) else { return false }
        if force { return true }
        guard images[game.id] == nil else { return false }
        return !missed.contains(game.id)
    }

    /// Reads the images already on disk, off the main thread.
    private func loadFromDisk(_ games: [Game]) async {
        let candidates: [(id: URL, file: URL)] = games.compactMap { game in
            guard images[game.id] == nil, let file = Self.imageURL(for: game) else { return nil }
            return (game.id, file)
        }
        guard !candidates.isEmpty else { return }

        let existing = await Task.detached(priority: .utility) {
            candidates.filter { FileManager.default.fileExists(atPath: $0.file.path) }
        }.value

        for candidate in existing where images[candidate.id] == nil {
            if let image = UIImage(contentsOfFile: candidate.file.path) {
                images[candidate.id] = image
            }
        }
    }

    // MARK: - The download queue

    private func startRunner() {
        guard runner == nil else { return }
        runner = Task { [weak self] in
            await self?.runQueue()
        }
    }

    private func runQueue() async {
        while !queue.isEmpty {
            let batch = Array(queue.prefix(CoverArtSetting.parallelDownloads))
            queue.removeFirst(batch.count)

            let credentials = ScreenScraperCredentialStore.load()
            let requests = batch.compactMap { Self.request(for: $0) }
            fetching.formUnion(requests.map(\.romURL))

            var networkFailed = false
            var completed = false
            await withTaskGroup(of: CoverArtOutcome.self) { group in
                for request in requests {
                    group.addTask {
                        await CoverArtFetcher.fetch(request, credentials: credentials)
                    }
                }
                for await outcome in group {
                    apply(outcome)
                    networkFailed = networkFailed || outcome.networkFailed
                    // A game that got an answer — found, missed, or skipped —
                    // proves the network works. Only a batch where every game
                    // failed to reach the server means it is time to stop.
                    completed = completed || !outcome.networkFailed
                }
            }

            // Nothing reached the server for the whole batch: stop, and leave
            // the rest of the library for the next refresh. One flaky game no
            // longer discards every game behind it.
            if networkFailed && !completed {
                os_log(.info, log: .default, "Cover art: network unavailable, pausing downloads")
                queue.removeAll()
                break
            }
        }
        runner = nil
    }

    private func apply(_ outcome: CoverArtOutcome) {
        fetching.remove(outcome.romURL)

        if let file = outcome.fileURL, let image = UIImage(contentsOfFile: file.path) {
            images[outcome.romURL] = image
            missed.remove(outcome.romURL)
            // A download just worked, so whatever was wrong before is over.
            lastError = nil
            if let source = outcome.source {
                os_log(.debug, log: .default, "Cover art: found %{public}@ via %{public}@",
                       outcome.romURL.lastPathComponent, source.displayName)
            }
            return
        }

        if !outcome.skipped {
            missed.insert(outcome.romURL)
        }
        if let error = outcome.error {
            lastError = error
        }
    }

    // MARK: - Removing

    /// Deletes one game's image and forgets it was looked up.
    func removeArtwork(for game: Game) {
        if let file = Self.imageURL(for: game) {
            try? FileManager.default.removeItem(at: file)
        }
        if let marker = Self.missMarkerURL(for: game) {
            try? FileManager.default.removeItem(at: marker)
        }
        images.removeValue(forKey: game.id)
        missed.remove(game.id)
    }

    /// Deletes every downloaded image. Lookups start fresh afterwards.
    func removeAllArtwork() {
        try? FileManager.default.removeItem(at: Self.directory)
        images.removeAll()
        missed.removeAll()
    }

    // MARK: - Requests

    /// The bits of a game a background download needs. `Game` itself holds a
    /// `UIImage`, so it does not travel between actors; this does.
    private static func request(for game: Game) -> CoverArtRequest? {
        guard let system = game.system?.identifier else { return nil }
        return CoverArtRequest(romURL: game.url, systemIdentifier: system)
    }
}

/// One game to fetch art for.
struct CoverArtRequest: Sendable {
    let romURL: URL
    let systemIdentifier: String
}

/// What came of one lookup.
struct CoverArtOutcome: Sendable {
    let romURL: URL
    /// The image file on disk, when one was found and written.
    let fileURL: URL?
    let source: CoverArtSource?
    /// A problem worth telling the user about.
    let error: String?
    /// True when the game was left alone because it was looked up recently.
    let skipped: Bool
    /// True when the request never reached the server. The queue pauses only
    /// when a whole batch fails this way, rather than working through the
    /// whole library offline.
    let networkFailed: Bool

    static func found(romURL: URL, fileURL: URL, source: CoverArtSource) -> CoverArtOutcome {
        CoverArtOutcome(romURL: romURL, fileURL: fileURL, source: source, error: nil,
                        skipped: false, networkFailed: false)
    }

    static func notFound(romURL: URL) -> CoverArtOutcome {
        CoverArtOutcome(romURL: romURL, fileURL: nil, source: nil, error: nil,
                        skipped: false, networkFailed: false)
    }

    static func skippedLookup(romURL: URL) -> CoverArtOutcome {
        CoverArtOutcome(romURL: romURL, fileURL: nil, source: nil, error: nil,
                        skipped: true, networkFailed: false)
    }

    static func failed(romURL: URL, error: String, networkFailed: Bool) -> CoverArtOutcome {
        CoverArtOutcome(romURL: romURL, fileURL: nil, source: nil, error: error,
                        skipped: false, networkFailed: networkFailed)
    }
}

/// The network half of a cover art download, away from the main actor.
enum CoverArtFetcher {

    /// The app's own name in the requests it makes to both services.
    static var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "Cassowary/\(version)"
    }

    /// What the user is told when a request never left the device.
    private static let unreachableError = "Couldn't reach libretro-thumbnails. Check your connection."

    static func fetch(_ request: CoverArtRequest, credentials: ScreenScraperCredentials?) async -> CoverArtOutcome {
        guard let destination = destination(for: request) else {
            return .notFound(romURL: request.romURL)
        }

        // A game that was looked for recently and not found is left alone.
        // The marker holds the date of that lookup, so nothing has to rely on
        // file timestamps.
        if let marker = missMarker(for: request),
           let stamp = try? String(contentsOf: marker, encoding: .utf8),
           let date = ISO8601DateFormatter().date(from: stamp),
           Date().timeIntervalSince(date) < CoverArtSetting.retryInterval {
            return .skippedLookup(romURL: request.romURL)
        }

        let romName = request.romURL.lastPathComponent
        var fileSize: Int64?
        if let values = try? request.romURL.resourceValues(forKeys: [.fileSizeKey]),
           let size = values.fileSize {
            fileSize = Int64(size)
        }

        // 1. libretro-thumbnails. Its URLs are guesses, so a miss is expected
        //    and just means trying the next name. A busy server (rate limit,
        //    outage) is not a miss: stop guessing and fall through to
        //    ScreenScraper instead. Only a request that never reached the
        //    server means the device is offline, and ScreenScraper would fail
        //    too, so that returns right away.
        var libretroBusy = false
        for url in LibretroThumbnailsClient.candidateURLs(
            romName: romName,
            systemIdentifier: request.systemIdentifier
        ) {
            switch await fetchImage(at: url) {
            case .image(let data):
                if let file = write(data, to: destination) {
                    return .found(romURL: request.romURL, fileURL: file, source: .libretro)
                }
                return .notFound(romURL: request.romURL)
            case .notFound:
                continue
            case .serverBusy:
                libretroBusy = true
            case .unreachable:
                return .failed(romURL: request.romURL,
                               error: unreachableError,
                               networkFailed: true)
            }
            if libretroBusy { break }
        }

        // 2. The server's own listing, for a name that is not the server's own.
        //    This downloads the system's file list — a few hundred kilobytes,
        //    kept for a month — so it runs only after every guess has missed.
        if !libretroBusy,
           let url = await LibretroThumbnailIndex.shared.bestMatchURL(
               for: romName,
               systemIdentifier: request.systemIdentifier
           ) {
            switch await fetchImage(at: url) {
            case .image(let data):
                if let file = write(data, to: destination) {
                    return .found(romURL: request.romURL, fileURL: file, source: .libretro)
                }
                return .notFound(romURL: request.romURL)
            case .unreachable:
                return .failed(romURL: request.romURL,
                               error: unreachableError,
                               networkFailed: true)
            case .notFound, .serverBusy:
                break
            }
        }

        // 3. ScreenScraper, when an app key is set up.
        if let credentials, credentials.isUsable {
            do {
                if let url = try await ScreenScraperClient.boxArtURL(
                    romName: romName,
                    fileSize: fileSize,
                    systemIdentifier: request.systemIdentifier,
                    credentials: credentials
                ), case .image(let data) = await fetchImage(at: url) {
                    if let file = write(data, to: destination) {
                        return .found(romURL: request.romURL, fileURL: file, source: .screenScraper)
                    }
                }
            } catch let error as ScreenScraperClient.FetchError {
                writeMissMarker(for: request)
                var networkFailed = false
                if case .networkUnavailable = error { networkFailed = true }
                return .failed(romURL: request.romURL,
                               error: error.errorDescription ?? "ScreenScraper could not be reached.",
                               networkFailed: networkFailed)
            } catch {
                // A lookup that missed is not a problem to report.
            }
        }

        // The server was busy rather than missing the game, so this is not a
        // miss: leave no marker and report it. The game is tried again on the
        // next refresh instead of being left alone for a week.
        // networkFailed stays false so the rest of the queue still runs.
        if libretroBusy {
            return .failed(romURL: request.romURL,
                           error: "libretro-thumbnails is busy. Try again later.",
                           networkFailed: false)
        }

        writeMissMarker(for: request)
        return .notFound(romURL: request.romURL)
    }

    /// Where the image and its miss marker go. The folder is made here, off
    /// the main thread, so the first download does not stall the UI.
    private static func destination(for request: CoverArtRequest) -> URL? {
        let folder = CoverArtStore.directory.appendingPathComponent(request.systemIdentifier, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            os_log(.error, log: .default, "Cover art: could not make %{public}@: %{public}@",
                   folder.path, error.localizedDescription)
            return nil
        }
        return folder.appendingPathComponent("\(request.romURL.lastPathComponent).png")
    }

    private static func missMarker(for request: CoverArtRequest) -> URL? {
        destination(for: request)?.appendingPathExtension("missing")
    }

    private static func writeMissMarker(for request: CoverArtRequest) {
        guard let marker = missMarker(for: request) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        try? stamp.write(to: marker, atomically: true, encoding: .utf8)
    }

    /// Writes an image, re-encoded as PNG. Both services send different
    /// formats (PNG, JPEG) and one extension keeps the folder predictable.
    private static func write(_ data: Data, to destination: URL) -> URL? {
        guard let image = UIImage(data: data), let png = image.pngData() else { return nil }
        do {
            try png.write(to: destination, options: .atomic)
            return destination
        } catch {
            os_log(.error, log: .default, "Cover art: could not write %{public}@: %{public}@",
                   destination.path, error.localizedDescription)
            return nil
        }
    }

    // MARK: - Fetching one image

    private enum ImageResult {
        case image(Data)
        /// The guess missed, or the answer was not an image. Try the next
        /// candidate; a game that simply is not there is not an error.
        case notFound
        /// The server answered but is rate-limiting or having problems
        /// (429, 408, 5xx). Not a miss and not the connection: back off.
        case serverBusy
        /// The request never reached the server (no connection, DNS, TLS,
        /// timeout). Nothing else will work right now.
        case unreachable
    }

    private static func fetchImage(at url: URL) async -> ImageResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            switch http.statusCode {
            case 200:
                // Trust the bytes over the status: a captive portal or a
                // server error page answers 200 with HTML.
                guard let mime = http.mimeType, mime.hasPrefix("image/"),
                      UIImage(data: data) != nil else { return .notFound }
                return .image(data)
            case 404, 403, 400:
                // A bad guess, not a broken connection. 400 covers names the
                // server cannot serve; the next candidate may still hit.
                return .notFound
            case 408, 429, 500, 502, 503, 504:
                return .serverBusy
            default:
                // Any other answer is unexpected but still an answer: treat
                // the guess as missed rather than crying wolf about the
                // connection.
                return .notFound
            }
        } catch {
            return .unreachable
        }
    }
}
