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
#if canImport(UIKit)
import UIKit
#endif

/// The settings the sharing feature keeps in UserDefaults.
enum SharingDefaults {
    static let enabledKey = "cassowary.sharing.enabled"
    static let deviceIDKey = "cassowary.sharing.deviceID"
    static let deviceNameKey = "cassowary.sharing.deviceName"
    static let trustedPeersKey = "cassowary.sharing.trustedPeers"
    /// The tvOS test hook: skip the Allow prompt.
    static let trustAllKey = "cassowary.sharing.trustAll"
    /// A pinned port, for the test scripts. Normally the system picks one.
    static let portKey = "cassowary.sharing.port"
    /// The TV remembers which host it last used.
    static let lastHostDeviceIDKey = "cassowary.tv.lastHost"
    /// The TV's cache budget, in bytes.
    static let cacheBudgetKey = "cassowary.tv.cacheBudget"
    static let defaultCacheBudget: Int64 = 2 * 1024 * 1024 * 1024
}

/// Who this device is on the network.
struct DeviceIdentity: Hashable {
    let id: String
    let name: String
    /// "ios", "tvos", or "mac", for display in the other device's list.
    let platformName: String

    /// The current device, made up once and kept.
    static var current: DeviceIdentity {
        let defaults = UserDefaults.standard

        var id = defaults.string(forKey: SharingDefaults.deviceIDKey)
        if id == nil {
            id = UUID().uuidString
            defaults.set(id, forKey: SharingDefaults.deviceIDKey)
        }

        var name = defaults.string(forKey: SharingDefaults.deviceNameKey)
        if name == nil {
            name = defaultName
        }

        return DeviceIdentity(id: id!, name: name!, platformName: platformName)
    }

    private static var defaultName: String {
#if os(tvOS)
        // The Apple TV's own name is not exposed to apps, and "Apple TV"
        // twice over on the list would be confusing, so say where it is.
        return "Apple TV"
#elseif os(macOS)
        return Host.current().localizedName ?? "This Mac"
#elseif targetEnvironment(macCatalyst)
        // Foundation's Host is not available in Mac Catalyst, so the Mac app
        // running on the Mac says what it is instead.
        return "This Mac"
#else
        return UIDevice.current.name
#endif
    }

    private static var platformName: String {
#if os(tvOS)
        return "tvos"
#elseif targetEnvironment(macCatalyst)
        return "mac"
#else
        return "ios"
#endif
    }
}

/// A device the user has allowed in.
struct TrustedPeer: Codable, Hashable, Identifiable {
    var deviceID: String
    var name: String
    var platformName: String
    var token: String
    var lastSeen: Date

    var id: String { deviceID }

    var platformLabel: String {
        switch platformName {
        case "tvos": return "Apple TV"
        case "mac":  return "Mac"
        default:     return "iPhone or iPad"
        }
    }
}

/// The hosts this device is allowed to talk to, and the devices this host has
/// allowed in. Kept in UserDefaults: it is a handful of short strings.
@MainActor
final class TrustStore: ObservableObject {

    static let shared = TrustStore()

    @Published private(set) var peers: [TrustedPeer] = []

    private init() {
        peers = Self.load()
    }
    func peer(withID id: String) -> TrustedPeer? {
        peers.first { $0.deviceID == id }
    }

    func add(_ peer: TrustedPeer) {
        if let index = peers.firstIndex(where: { $0.deviceID == peer.deviceID }) {
            peers[index] = peer
        } else {
            peers.append(peer)
        }
        save()
    }

    func remove(deviceID: String) {
        peers.removeAll { $0.deviceID == deviceID }
        save()
    }

    func removeAll() {
        peers.removeAll()
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(peers) else { return }
        UserDefaults.standard.set(data, forKey: SharingDefaults.trustedPeersKey)
    }

    private static func load() -> [TrustedPeer] {
        guard let data = UserDefaults.standard.data(forKey: SharingDefaults.trustedPeersKey),
              let peers = try? JSONDecoder().decode([TrustedPeer].self, from: data)
        else { return [] }
        return peers
    }
}

/// A token made up when a device is allowed in.
enum PairingToken {
    static func make() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
