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

/// The facts both ends of a transfer agree on: the protocol version, the
/// Bonjour service, the HTTP paths, and the shapes of the messages.
///
/// Both the phone and the TV compile this file, so a change here is the only
/// place a change to the wire format belongs.
enum TransferProtocol {

    /// Bumped whenever a message changes shape. A peer that speaks a different
    /// version is refused politely instead of half-working.
    ///
    /// Version 2 adds named save slots: besides "state" and battery saves,
    /// kinds can now be "state:autosave" and "state:slot-N". A version 1 peer
    /// would file those under the wrong file, so it is refused instead.
    static let version = 2

    /// How the host is advertised and found. Matches `NSBonjourServices` in
    /// both Info.plists.
    static let serviceType = "_cassowary._tcp"

    /// The header carrying a paired device's token.
    static let tokenHeader = "X-Cassowary-Token"

    enum Path {
        static let info = "/v1/info"
        static let pair = "/v1/pair"
        static let library = "/v1/library"
        static let artworkPrefix = "/v1/artwork/"
        static let gameFilePrefix = "/v1/games/"
        static let savesIndex = "/v1/saves/index"
        static let savesMerge = "/v1/saves/merge"
        static let savesPrefix = "/v1/saves/"
        /// `GET /v1/retroachievements`: the phone's RetroAchievements sign-in,
        /// for a paired TV, when the phone has chosen to share it.
        static let retroAchievements = "/v1/retroachievements"

        /// `GET|PUT /v1/saves/<gameID>/<kind>`. Kind is percent-encoded, so a
        /// battery save's core and file name survive the trip.
        static func save(gameID: String, kind: String) -> String {
            savesPrefix + gameID + "/" + (kind.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? kind)
        }

        /// `GET /v1/games/<gameID>/file`. One file per game today; the index
        /// is there so multi-disc games fit later.
        static func gameFile(gameID: String, index: Int = 0) -> String {
            gameFilePrefix + gameID + "/file/\(index)"
        }

        static func artwork(gameID: String) -> String {
            artworkPrefix + gameID
        }

        /// `PUT /v1/games/<gameID>/import?name=…` receives a whole game from
        /// another host. The body is the file's bytes.
        static func importGame(gameID: String, name: String) -> String {
            gameFilePrefix + gameID + "/import?name=" + (name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name)
        }
    }

    // MARK: - Messages

    /// `GET /v1/retroachievements`. The login token, never the password:
    /// the phone keeps no password to send.
    struct RetroAchievementsShare: Codable, Hashable {
        var username: String
        var displayName: String
        var token: String
        var hardcore: Bool
    }

    /// `GET /v1/info`.
    struct HostInfo: Codable, Hashable {
        var protocolVersion: Int
        var deviceID: String
        var deviceName: String
        /// False when this host trusts anyone on the network. Only used by the
        /// test scripts; the app always asks.
        var pairingRequired: Bool
        var appVersion: String
    }

    /// `POST /v1/pair`.
    struct PairRequest: Codable, Hashable {
        var deviceID: String
        var deviceName: String
        /// "ios", "tvos", "mac", for display.
        var platformName: String
    }

    struct PairResponse: Codable, Hashable {
        /// False when the host's user said no, or nobody answered in time.
        var accepted: Bool
        var token: String?
    }

    /// `GET /v1/library`.
    struct LibraryManifest: Codable, Hashable {
        var generation: String
        var games: [GameEntry]
    }

    struct GameEntry: Codable, Hashable, Identifiable {
        /// The SHA-256 of the file's bytes: the same game is the same id on
        /// every device, whatever the file is called.
        var id: String
        var title: String
        /// The file name on the host, which the TV keeps for a readable cache.
        var fileName: String
        var systemIdentifier: String
        var systemName: String
        var size: Int64
        var hasSaveState: Bool
        var hasArtwork: Bool
        var hasBatterySave: Bool
    }

    /// One save file, on either end.
    struct SaveBlobMeta: Codable, Hashable {
        var gameID: String
        /// "state", "state:autosave", "state:slot-N", or
        /// "battery:<core>:<file name>".
        var kind: String
        /// Goes up on every write. Device clocks cannot be trusted, so the
        /// counter decides who is newer, and the device id breaks ties.
        var version: Int
        var deviceID: String
        var hash: String
        var size: Int64
        var modifiedAt: Date
        /// True when this version is a deletion: the save was deleted on the
        /// device that wrote it, and the others should delete theirs. Left
        /// out (nil) by apps from before deletions travelled.
        var deleted: Bool? = nil

        var isDeleted: Bool { deleted == true }

        /// Stands in for a deleted save's fingerprint, so two deletions of
        /// the same save compare as the same.
        static let deletedHash = "deleted"
    }

    /// `GET /v1/saves/index` and the body of `POST /v1/saves/merge`.
    struct SavesIndex: Codable, Hashable {
        var deviceID: String
        var blobs: [SaveBlobMeta]
    }

    /// What the merge answer says: `send` are blobs the caller should fetch
    /// from the host; `need` are blobs the host wants the caller to upload.
    struct MergeResponse: Codable, Hashable {
        var send: [SaveBlobMeta]
        var need: [SaveBlobMeta]
    }

    /// `POST /v1/saves/<game>/<kind>` after a PUT, when the host had to ask
    /// which copy to keep. The response says what happened to the blob.
    struct SavePutResponse: Codable, Hashable {
        var stored: Bool
        /// True when the host kept its own copy and filed the incoming one as
        /// a conflict for the user to settle.
        var conflict: Bool
    }

    // MARK: - JSON

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// How a save file is named on disk, and how a game is recognized.
enum SaveKind {
    /// The main manual slot, one file per game beside the ROM. This is the
    /// kind version 1 knew, so old states keep working.
    static let state = "state"
    /// Written automatically when a game closes. Never overwritten by hand:
    /// it is how a game picks up where it was left, on any device.
    static let autosave = "state:autosave"
    /// How many extra manual slots a game gets, besides the main one.
    static let manualSlotCount = 3

    /// The kind for manual slot `index`, starting at 1.
    static func stateSlot(_ index: Int) -> String {
        "state:slot-\(index)"
    }

    /// Every save-state kind a game can hold: the main slot, the manual
    /// slots, and the autosave.
    static var allStateKinds: [String] {
        [state] + (1...manualSlotCount).map(stateSlot) + [autosave]
    }

    /// True for the main slot, the manual slots, and the autosave — anything
    /// that is a save state rather than a battery save or play history.
    static func isStateKind(_ kind: String) -> Bool {
        kind == state || kind == autosave || stateSlotIndex(kind) != nil
    }

    /// The manual slot number for a "state:slot-N" kind, if it is one.
    static func stateSlotIndex(_ kind: String) -> Int? {
        guard kind.hasPrefix("state:slot-") else { return nil }
        return Int(kind.dropFirst("state:slot-".count))
    }

    /// A short name for a state kind, for menus and conflict prompts.
    static func displayName(for kind: String) -> String {
        if kind == state { return "Main save" }
        if kind == autosave { return "Autosave" }
        if let index = stateSlotIndex(kind) { return "Slot \(index)" }
        return kind
    }
    /// What every device remembers about playing a game: last played, play
    /// count, favorite. It travels as a save blob so it uses the same queue,
    /// the same retries, and the same storage.
    static let playInfo = "playinfo"

    static func battery(core: String, file: String) -> String {
        "battery:\(core):\(file)"
    }

    static func batteryParts(_ kind: String) -> (core: String, file: String)? {
        let parts = kind.split(separator: ":", maxSplits: 2)
        guard parts.count == 3, parts[0] == "battery" else { return nil }
        return (String(parts[1]), String(parts[2]))
    }
}

/// What a device remembers about playing one game.
struct PlayInfo: Codable, Hashable {
    var lastPlayedAt: Date?
    var playCount: Int = 0
    var favorite: Bool = false

    static let empty = PlayInfo()

    /// Merges two records without losing anything: the later date, the higher
    /// count, and a favorite stays one.
    func merged(with other: PlayInfo) -> PlayInfo {
        PlayInfo(lastPlayedAt: [lastPlayedAt, other.lastPlayedAt].compactMap { $0 }.max(),
                 playCount: max(playCount, other.playCount),
                 favorite: favorite || other.favorite)
    }
}
