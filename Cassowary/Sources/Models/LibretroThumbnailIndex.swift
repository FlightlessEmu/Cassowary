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
import os.log

/// Finds the server's own name for a game by reading its folder listing.
///
/// The URLs `LibretroThumbnailsClient` builds are guesses: they only land
/// when a ROM is already named the server's way. A name that came from
/// somewhere else — a scene release, a differently tagged dump, a hack —
/// needs the real list. The server publishes one for every system as a
/// directory index, and this reads it.
///
/// A listing is a few hundred kilobytes for most systems, so it is kept on
/// disk and in memory and only fetched again after a month. A folder whose
/// listing is too big to be worth reading — MAME's runs into tens of
/// megabytes — is skipped, and those games are left to the guesses.
actor LibretroThumbnailIndex {

    static let shared = LibretroThumbnailIndex()

    /// The biggest listing worth downloading. MAME's is far larger than this,
    /// and arcade ROMs are named nothing like their titles anyway.
    private static let sizeLimit: Int64 = 5 * 1024 * 1024

    /// How close a listed name has to be to a ROM's name to count as the same
    /// game. "Golf Mania" against the server's "Golfamania" scores about
    /// 0.82, while two unrelated games score well under 0.7.
    private static let minimumSimilarity = 0.8

    /// Tags that mean the image is of an unfinished version of the game.
    /// They are allowed to match, just not to win against a finished cover.
    private static let roughTags = ["beta", "proto", "demo", "sample", "unl", "kiosk", "hack"]

    /// Where listings are kept. A sibling of the cover art folder, so
    /// "Remove All Cover Art" does not take them with it.
    nonisolated static var directory: URL {
        CoverArtStore.directory.deletingLastPathComponent()
            .appendingPathComponent("CoverArtIndex", isDirectory: true)
    }

    /// Listings already read, by folder.
    private var listings: [String: [String]] = [:]

    /// A download in flight, so four games of one system in the same batch do
    /// not each pull the same listing.
    private var running: [String: Task<[String], Never>] = [:]

    /// The image URL for the listed name closest to a ROM's name, or nil when
    /// nothing is close enough — a homebrew game the server has never heard
    /// of, say.
    func bestMatchURL(for romName: String, systemIdentifier: String) async -> URL? {
        guard let folder = LibretroThumbnailsClient.systemFolder(for: systemIdentifier,
                                                                 romName: romName) else {
            return nil
        }
        let names = await self.names(forFolder: folder)
        guard let name = Self.bestMatch(for: romName, in: names) else { return nil }
        return LibretroThumbnailsClient.imageURL(folder: folder, name: name)
    }

    // MARK: - Getting a listing

    /// The file names one system folder holds, from memory, from disk, or
    /// from the server.
    private func names(forFolder folder: String) async -> [String] {
        if let names = listings[folder] { return names }
        if let names = Self.read(folder: folder) {
            listings[folder] = names
            return names
        }

        if let task = running[folder] { return await task.value }

        let task = Task.detached { await Self.fetchNames(folder: folder) }
        running[folder] = task
        let names = await task.value
        running[folder] = nil

        guard !names.isEmpty else { return [] }
        listings[folder] = names
        Self.write(names, folder: folder)
        return names
    }

    /// Reads a listing over the network, or returns nothing when it is too
    /// large to be worth it or the server cannot be reached. A failure here is
    /// not an error to report: the game is simply looked up by guess alone.
    private static func fetchNames(folder: String) async -> [String] {
        guard let listing = listingURL(folder: folder) else { return [] }

        var head = URLRequest(url: listing)
        head.httpMethod = "HEAD"
        head.timeoutInterval = 20
        head.setValue(CoverArtFetcher.userAgent, forHTTPHeaderField: "User-Agent")

        if let (_, response) = try? await URLSession.shared.data(for: head),
           let http = response as? HTTPURLResponse,
           http.expectedContentLength > sizeLimit {
            os_log(.info, log: .default, "Cover art: %{public}@ listing is %lld bytes; skipping",
                   folder, http.expectedContentLength)
            return []
        }

        var request = URLRequest(url: listing)
        request.timeoutInterval = 60
        request.setValue(CoverArtFetcher.userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            return []
        }
        return parse(html)
    }

    private static func listingURL(folder: String) -> URL? {
        var components = URLComponents(url: LibretroThumbnailsClient.baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/\(folder)/Named_Boxarts/"
        return components?.url
    }

    /// Pulls the image names out of an Apache directory index. Its links are
    /// percent-encoded file names, like `href="Chrono%20Trigger%20(USA).png"`.
    static func parse(_ html: String) -> [String] {
        let pattern = "href=\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var names: [String] = []
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in regex.matches(in: html, range: range) {
            guard let href = Range(match.range(at: 1), in: html) else { continue }
            let link = String(html[href])
            guard link.lowercased().hasSuffix(".png") else { continue }
            let name = link.removingPercentEncoding ?? link
            guard !name.contains("/") else { continue }
            names.append(name)
        }
        return names
    }

    // MARK: - The copy on disk

    private static func file(folder: String) -> URL {
        directory.appendingPathComponent("\(folder).txt")
    }

    /// The cached listing, or nil when there is none or it is older than the
    /// refresh interval. The date is written in the file, so nothing has to
    /// rely on file timestamps.
    private static func read(folder: String) -> [String]? {
        guard let text = try? String(contentsOf: file(folder: folder), encoding: .utf8) else {
            return nil
        }
        var lines = text.components(separatedBy: .newlines)
        guard let stamp = lines.first,
              let date = ISO8601DateFormatter().date(from: stamp),
              Date().timeIntervalSince(date) < CoverArtSetting.indexRefreshInterval else {
            return nil
        }
        lines.removeFirst()
        let names = lines.filter { !$0.isEmpty }
        return names.isEmpty ? nil : names
    }

    private static func write(_ names: [String], folder: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date())
            try ([stamp] + names).joined(separator: "\n")
                .write(to: file(folder: folder), atomically: true, encoding: .utf8)
        } catch {
            // The next lookup downloads it again; not worth telling the user.
            os_log(.error, log: .default, "Cover art: could not save the %{public}@ listing: %{public}@",
                   folder, error.localizedDescription)
        }
    }

    // MARK: - Picking a name

    /// The listed name closest to a ROM's own name, or nil when none is close
    /// enough. Ties go to the name with fewer annotations, then the shorter
    /// one, so a plain "(USA)" cover wins over a "(USA) (Rev 1)" one.
    static func bestMatch(for romName: String, in names: [String]) -> String? {
        let wanted = comparable(romName)
        guard wanted.count >= 4 else { return nil }

        var best: (name: String, score: Double, annotations: Int)?

        for name in names {
            let candidate = comparable(name)
            guard !candidate.isEmpty else { continue }

            var score = similarity(wanted, candidate)
            if roughTags.contains(where: { name.lowercased().contains($0) }) {
                score -= 0.05
            }
            guard score >= minimumSimilarity else { continue }

            let annotations = name.filter { $0 == "(" }.count
            if let current = best {
                let better = score > current.score
                    || (score == current.score && annotations < current.annotations)
                    || (score == current.score && annotations == current.annotations
                        && name.count < current.name.count)
                guard better else { continue }
            }
            best = (name, score, annotations)
        }
        return best?.name
    }

    /// A name reduced to what makes it that name: no file extension, no
    /// annotations like `(USA)` or `[!]`, no leading scene number, no case,
    /// no accents, no punctuation and no spaces. So "0102 - Nintendogs -
    /// Labrador & Friends (E)(Squirrels).nds" and "Nintendogs - Labrador _
    /// Friends (Europe) (En,Fr,De,Es,It).png" both come out as
    /// "nintendogslabradorfriends".
    static func comparable(_ name: String) -> String {
        var text = (name as NSString).deletingPathExtension
            .replacingOccurrences(of: "\\([^)]*\\)", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\[[^\\]]*\\]", with: " ", options: .regularExpression)
        text = text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                            locale: Locale(identifier: "en_US_POSIX"))

        let allowed = CharacterSet.alphanumerics
        let letters = String(text.unicodeScalars.filter { allowed.contains($0) })

        // "0102 - Nintendogs" is the same game as "Nintendogs", so a leading
        // number goes. A name that is all digits — "1942" — keeps them.
        let withoutNumber = String(letters.drop { $0.isNumber })
        return withoutNumber.isEmpty ? letters : withoutNumber
    }

    /// How alike two comparable names are, from 0 to 1. One means the same
    /// name; the score falls off with the number of edits it would take to
    /// turn one into the other.
    static func similarity(_ one: String, _ other: String) -> Double {
        if one == other { return 1 }
        let longest = max(one.count, other.count)
        guard longest > 0 else { return 0 }
        return 1 - Double(editDistance(one, other)) / Double(longest)
    }

    /// The number of insertions, deletions and swaps that turn one string
    /// into the other.
    static func editDistance(_ one: String, _ other: String) -> Int {
        let a = Array(one), b = Array(other)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
