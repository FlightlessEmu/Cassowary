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

/// Looks a game up on screenscraper.fr and returns its box art.
///
/// OpenEmu used OpenVGDB for this, a database it downloaded and queried
/// locally. Cassowary has no database, so the optional second source is
/// ScreenScraper's web API: it matches on the ROM's file name (and size) and
/// answers with the images it holds. It needs an app key, so this source only
/// runs when one is configured — see `ScreenScraperCredentials`.
///
/// This mirrors the ScreenScraper client the macOS app grew, with the ROM hash
/// left out: hashing every file on a phone to find art is not worth the time
/// it takes, and the name-and-size match is what the API falls back to anyway.
enum ScreenScraperClient {

    enum FetchError: Error, Equatable, LocalizedError {
        /// The request never made it there.
        case networkUnavailable(String)
        /// The app key or the account was refused.
        case rejectedCredentials
        /// Too many lookups for today.
        case rateLimited
        /// An answer that could not be read.
        case unexpectedResponse
        /// No app key is configured.
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .networkUnavailable(let detail):
                return "Couldn't reach ScreenScraper — check your connection. (\(detail))"
            case .rejectedCredentials:
                return "ScreenScraper refused the login. Check the account and app key in Settings → Cover Art."
            case .rateLimited:
                return "ScreenScraper's daily quota is used up. Try again tomorrow."
            case .unexpectedResponse:
                return "ScreenScraper returned an unexpected answer."
            case .notConfigured:
                return "ScreenScraper needs an app key before it can look games up."
            }
        }
    }

    static let apiBase = "https://www.screenscraper.fr/api2"

    /// How the app introduces itself to the API.
    static let softwareName = "Cassowary"

    // MARK: - Lookup

    /// The box art URL for one ROM, or nil when ScreenScraper has no match.
    ///
    /// A miss is not an error: it means the game is not in their database.
    /// Problems the user can act on — a refused login, a full quota, no
    /// network — are thrown.
    static func boxArtURL(
        romName: String,
        fileSize: Int64?,
        systemIdentifier: String,
        credentials: ScreenScraperCredentials
    ) async throws -> URL? {
        guard credentials.isUsable else { throw FetchError.notConfigured }
        guard let systemID = systemID(for: systemIdentifier, romName: romName) else { return nil }

        if let game = try await gameInfo(
            romName: romName,
            fileSize: fileSize,
            systemID: systemID,
            credentials: credentials
        ) {
            return boxArtURL(in: game)
        }

        // Games saved under their dump-tagged name — "Super Mario World (USA)
        // [!].sfc" — are common, and the API indexes the plain name. One
        // retry costs a request only when the first lookup missed.
        let cleaned = cleanedROMName(romName)
        if cleaned != romName,
           let game = try await gameInfo(
               romName: cleaned,
               fileSize: fileSize,
               systemID: systemID,
               credentials: credentials
           ) {
            return boxArtURL(in: game)
        }
        return nil
    }

    /// Checks a username and password against the API without using up a
    /// game lookup. Returns false when they are refused.
    static func verify(_ credentials: ScreenScraperCredentials) async throws -> Bool {
        guard credentials.isUsable else { throw FetchError.notConfigured }
        var components = URLComponents(string: "\(apiBase)/ssuserInfos.php")!
        var items = developerQueryItems(credentials)
        items.append(URLQueryItem(name: "output", value: "json"))
        components.queryItems = items

        guard let url = components.url else { throw FetchError.unexpectedResponse }
        let (_, response) = try await send(url)
        guard let http = response as? HTTPURLResponse else { throw FetchError.unexpectedResponse }

        switch http.statusCode {
        case 200..<300: return true
        case 401, 403:  return false
        case 430:       throw FetchError.rateLimited
        default:        throw FetchError.unexpectedResponse
        }
    }

    // MARK: - HTTP

    /// One `jeuInfos.php` call. Returns the `jeu` object, or nil when the game
    /// was not found.
    private static func gameInfo(
        romName: String,
        fileSize: Int64?,
        systemID: Int,
        credentials: ScreenScraperCredentials
    ) async throws -> [String: Any]? {
        var components = URLComponents(string: "\(apiBase)/jeuInfos.php")!
        var items = developerQueryItems(credentials)
        items.append(URLQueryItem(name: "output", value: "json"))
        items.append(URLQueryItem(name: "systemeid", value: String(systemID)))
        items.append(URLQueryItem(name: "romnom", value: romName))
        if let fileSize, fileSize > 0 {
            // Size disambiguates dumps that share a name, and costs nothing.
            items.append(URLQueryItem(name: "romtaille", value: String(fileSize)))
        }
        components.queryItems = items

        guard let url = components.url else { throw FetchError.unexpectedResponse }
        let (data, response) = try await send(url)
        guard let http = response as? HTTPURLResponse else { throw FetchError.unexpectedResponse }

        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw FetchError.rejectedCredentials
        case 404:
            return nil
        case 430:
            throw FetchError.rateLimited
        default:
            os_log(.error, log: .default, "ScreenScraper answered HTTP %d", http.statusCode)
            throw FetchError.unexpectedResponse
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["response"] as? [String: Any]
        else { throw FetchError.unexpectedResponse }

        return response["jeu"] as? [String: Any]
    }

    /// A request with the app's own timeout, so one unreachable host does not
    /// hold up a whole library's worth of downloads.
    private static func send(_ url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("\(softwareName)/\(appVersion)", forHTTPHeaderField: "User-Agent")
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            throw FetchError.networkUnavailable(error.localizedDescription)
        }
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// The parts of every request that identify the app and the account.
    private static func developerQueryItems(_ credentials: ScreenScraperCredentials) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "softname", value: softwareName),
            URLQueryItem(name: "devid", value: credentials.developerID),
            URLQueryItem(name: "devpassword", value: credentials.developerPassword),
        ]
        if credentials.hasAccount {
            items.append(URLQueryItem(name: "ssid", value: credentials.username))
            items.append(URLQueryItem(name: "sspassword", value: credentials.password))
        }
        return items
    }

    // MARK: - Response parsing

    /// Picks a box image out of a `jeu` object, preferring the user's region.
    static func boxArtURL(in game: [String: Any]) -> URL? {
        guard let medias = game["medias"] as? [[String: Any]] else { return nil }
        let boxes = medias.filter { ($0["type"] as? String) == "box-2D" }
        guard !boxes.isEmpty else { return nil }

        for region in preferredRegions() {
            if let match = boxes.first(where: { ($0["region"] as? String) == region }),
               let text = match["url"] as? String,
               let url = URL(string: text) {
                return url
            }
        }
        if let text = boxes.first?["url"] as? String {
            return URL(string: text)
        }
        return nil
    }

    /// ScreenScraper's region names, in the order this device would rather see
    /// them. The tags are lower case in their API.
    static func preferredRegions() -> [String] {
        switch Locale.current.region?.identifier {
        case "US", "CA", "MX":  return ["us", "wor", "eu", "jp"]
        case "JP":              return ["jp", "wor", "us", "eu"]
        case "FR", "DE", "IT", "ES", "NL", "BE", "PT", "SE", "NO", "DK", "FI",
             "PL", "AT", "CH", "IE", "GB", "AU", "NZ", "BR":
            return ["eu", "wor", "us", "jp"]
        default:
            return ["wor", "us", "eu", "jp"]
        }
    }

    // MARK: - Systems

    /// ScreenScraper's numeric system IDs, keyed by OpenEmu's identifiers.
    ///
    /// Verified against `systemesListe.php`; several entries were wrong in the
    /// past and quietly looked games up in the wrong console's catalogue.
    static let systemIDs: [String: Int] = [
        // Nintendo
        "openemu.system.nes":           3,
        "openemu.system.fds":         106,
        "openemu.system.snes":          4,
        "openemu.system.n64":          14,
        "openemu.system.gc":           13,
        "openemu.system.wii":          16,
        "openemu.system.gb":            9,   // .gbc routes to 10 below
        "openemu.system.gba":          12,
        "openemu.system.nds":          15,
        "openemu.system.vb":           11,
        "openemu.system.pokemonmini": 211,

        // Sony
        "openemu.system.psx":          57,
        "openemu.system.ps2":          58,
        "openemu.system.psp":          61,

        // Sega
        "openemu.system.sg":            1,
        "openemu.system.sg1000":      109,
        "openemu.system.sms":           2,
        "openemu.system.gg":           21,
        "openemu.system.scd":          20,
        "openemu.system.32x":          19,
        "openemu.system.saturn":       22,
        "openemu.system.dc":           23,

        // Atari
        "openemu.system.2600":         26,
        "openemu.system.5200":         40,
        "openemu.system.7800":         41,
        "openemu.system.jaguar":       27,
        "openemu.system.lynx":         28,
        "openemu.system.atari8bit":    43,

        // NEC
        "openemu.system.pce":          31,
        "openemu.system.pcecd":       114,
        "openemu.system.pcfx":         72,

        // SNK and Bandai
        "openemu.system.ngp":          25,   // .ngc routes to 82 below
        "openemu.system.ws":           45,   // .wsc routes to 46 below

        // The rest
        "openemu.system.3do":          29,
        "openemu.system.colecovision": 48,
        "openemu.system.intellivision": 115,
        "openemu.system.odyssey2":    104,
        "openemu.system.vectrex":     102,
        "openemu.system.sv":          207,
        "openemu.system.msx":         113,
        "openemu.system.c64":          66,
        "openemu.system.arcade":       75,
    ]

    /// The system ID for a ROM, accounting for plugins that cover two
    /// platforms. Game Boy Color, WonderSwan Color and Neo Geo Pocket Color
    /// are separate catalogues on ScreenScraper even though one core plays both.
    static func systemID(for systemIdentifier: String, romName: String) -> Int? {
        guard let base = systemIDs[systemIdentifier] else { return nil }
        let fileExtension = (romName as NSString).pathExtension.lowercased()
        switch (systemIdentifier, fileExtension) {
        case ("openemu.system.gb", "gbc"):   return 10
        case ("openemu.system.ws", "wsc"):   return 46
        case ("openemu.system.ngp", "ngc"):  return 82
        default:                             return base
        }
    }

    /// Strips `(…)` and `[…]` annotations from a file name while keeping its
    /// extension: `Super Mario World (USA) [!].sfc` → `Super Mario World.sfc`.
    static func cleanedROMName(_ filename: String) -> String {
        let name = filename as NSString
        let fileExtension = name.pathExtension
        let base = name.deletingPathExtension

        var stripped = base
            .replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        guard !stripped.isEmpty else { return filename }
        return fileExtension.isEmpty ? stripped : "\(stripped).\(fileExtension)"
    }
}
