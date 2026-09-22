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

/// Builds cover art URLs for the public libretro-thumbnails server.
///
/// Every system has a folder, each folder has a `Named_Boxarts` directory, and
/// inside that each game is one image named after the game:
///
///     https://thumbnails.libretro.com/<System>/Named_Boxarts/<Game Name>.png
///
/// The names follow the No-Intro conventions, which is also how most ROM
/// collections are named, so a ROM's file name is usually the image's name
/// already. When it is not — a dump-tagged file like
/// `Super Mario World (USA) [!].sfc` — the annotations are stripped and the
/// name retried with a region tag for the user's locale.
///
/// The server is free and needs no account. It has no search API, so a lookup
/// starts as a guess at a URL; when the guesses miss, `LibretroThumbnailIndex`
/// reads the server's own listing for the system and picks the closest name.
enum LibretroThumbnailsClient {

    /// Where the mirrored box art lives.
    static let baseURL = URL(string: "https://thumbnails.libretro.com")!

    /// The libretro folder for each system plugin this app ships.
    ///
    /// Names are the server's, which are not OpenEmu's: they follow the
    /// libretro playlist names. Systems that are missing here (the VMU, for
    /// instance) simply have no box art to find.
    static let systemFolders: [String: String] = [
        "openemu.system.3do":           "The 3DO Company - 3DO",
        "openemu.system.2600":          "Atari - 2600",
        "openemu.system.5200":          "Atari - 5200",
        "openemu.system.7800":          "Atari - 7800",
        "openemu.system.arcade":        "MAME",
        "openemu.system.atari8bit":     "Atari - 8-bit",
        "openemu.system.c64":           "Commodore - 64",
        "openemu.system.colecovision":  "Coleco - ColecoVision",
        "openemu.system.dc":            "Sega - Dreamcast",
        "openemu.system.fds":           "Nintendo - Family Computer Disk System",
        "openemu.system.gb":            "Nintendo - Game Boy",
        "openemu.system.gba":           "Nintendo - Game Boy Advance",
        "openemu.system.gc":            "Nintendo - GameCube",
        "openemu.system.gg":            "Sega - Game Gear",
        "openemu.system.intellivision": "Mattel - Intellivision",
        "openemu.system.jaguar":        "Atari - Jaguar",
        "openemu.system.lynx":          "Atari - Lynx",
        "openemu.system.msx":           "Microsoft - MSX",
        "openemu.system.n64":           "Nintendo - Nintendo 64",
        "openemu.system.nds":           "Nintendo - Nintendo DS",
        "openemu.system.nes":           "Nintendo - Nintendo Entertainment System",
        "openemu.system.ngp":           "SNK - Neo Geo Pocket",
        "openemu.system.odyssey2":      "Magnavox - Odyssey2",
        "openemu.system.pce":           "NEC - PC Engine - TurboGrafx 16",
        "openemu.system.pcecd":         "NEC - PC Engine CD - TurboGrafx-CD",
        "openemu.system.pcfx":          "NEC - PC-FX",
        "openemu.system.pokemonmini":   "Nintendo - Pokemon Mini",
        "openemu.system.ps2":           "Sony - PlayStation 2",
        "openemu.system.psp":           "Sony - PlayStation Portable",
        "openemu.system.psx":           "Sony - PlayStation",
        "openemu.system.saturn":        "Sega - Saturn",
        "openemu.system.scd":           "Sega - Mega-CD - Sega CD",
        "openemu.system.sg":            "Sega - Mega Drive - Genesis",
        "openemu.system.sg1000":        "Sega - SG-1000",
        "openemu.system.sms":           "Sega - Master System - Mark III",
        "openemu.system.snes":          "Nintendo - Super Nintendo Entertainment System",
        "openemu.system.sv":            "Watara - Supervision",
        "openemu.system.vb":            "Nintendo - Virtual Boy",
        "openemu.system.vectrex":       "GCE - Vectrex",
        "openemu.system.wii":           "Nintendo - Wii",
        "openemu.system.ws":            "Bandai - WonderSwan",
    ]

    /// The folder for one ROM, which can differ from the system's when the
    /// plugin covers more than one platform.
    ///
    /// Game Boy, WonderSwan and Neo Geo Pocket plugins each handle the
    /// original and the Color model, and the server files their art in two
    /// separate folders. The file extension says which one this ROM is.
    static func systemFolder(for systemIdentifier: String, romName: String) -> String? {
        let fileExtension = (romName as NSString).pathExtension.lowercased()
        switch (systemIdentifier, fileExtension) {
        case ("openemu.system.gb", "gbc"):
            return "Nintendo - Game Boy Color"
        case ("openemu.system.ws", "wsc"):
            return "Bandai - WonderSwan Color"
        case ("openemu.system.ngp", "ngc"):
            return "SNK - Neo Geo Pocket Color"
        default:
            return systemFolders[systemIdentifier]
        }
    }

    /// The image URLs to try for one ROM, best guess first.
    ///
    /// A ROM that is already named the No-Intro way produces one URL. One with
    /// dump tags produces three at most: the name as-is, the cleaned name with
    /// the locale's region tag, and the cleaned name on its own.
    static func candidateURLs(
        romName: String,
        systemIdentifier: String,
        region: String? = Locale.current.region?.identifier
    ) -> [URL] {
        guard let folder = systemFolder(for: systemIdentifier, romName: romName) else { return [] }

        let base = (romName as NSString).deletingPathExtension
        var names: [String] = []

        func add(_ name: String) {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !names.contains(trimmed) else { return }
            names.append(trimmed)
        }

        add(base)

        let cleaned = strippingAnnotations(from: base)
        if let tag = regionTag(for: region) {
            add("\(cleaned) (\(tag))")
        }
        add(cleaned)

        return names.compactMap { imageURL(folder: folder, name: "\(normalizedName($0)).png") }
    }

    /// The image URL for one exact file name on the server.
    static func imageURL(folder: String, name: String) -> URL? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/\(folder)/Named_Boxarts/\(name)"
        return components?.url
    }

    /// Characters the server replaces with underscores when it stores a name.
    ///
    /// The same set RetroArch and the mirror use: `& * / : ` < > ? \ | "`
    static func normalizedName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "&*/:`<>?\\|\"")
        return name.unicodeScalars.map { forbidden.contains($0) ? "_" : String($0) }.joined()
    }

    /// Removes `(…)` and `[…]` annotations, which is what a No-Intro name
    /// looks like when it is missing them: `Super Mario World (USA) [!]`
    /// becomes `Super Mario World`.
    static func strippingAnnotations(from name: String) -> String {
        var stripped = name
            .replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if stripped.isEmpty {
            stripped = name
        }
        return stripped
    }

    /// The region tag to append when a ROM's name has none, from the device's
    /// own region. The server has no "World" for every game, so `World` is
    /// only used where a game is genuinely region-free in most sets.
    static func regionTag(for region: String?) -> String? {
        switch region?.uppercased() {
        case "US", "CA", "MX":  return "USA"
        case "JP":              return "Japan"
        case "GB", "IE", "AU", "NZ", "FR", "DE", "IT", "ES", "NL", "BE", "PT",
             "SE", "NO", "DK", "FI", "PL", "AT", "CH", "BR":
            return "Europe"
        default:
            return "USA"
        }
    }
}
