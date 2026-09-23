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
    static let version = 1

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
        /// "state", or "battery:<core>:<file name>".
        var kind: String
        /// Goes up on every write. Device clocks cannot be trusted, so the
        /// counter decides who is newer, and the device id breaks ties.
        var version: Int
        var deviceID: String
        var hash: String
        var size: Int64
        var modifiedAt: Date
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
    static let state = "state"
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
