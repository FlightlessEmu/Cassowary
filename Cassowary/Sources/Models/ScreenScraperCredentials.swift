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
import Security

/// What ScreenScraper needs before it will answer a lookup.
///
/// There are two separate logins. The app credentials (`devid` and
/// `devpassword`) identify the software, are issued to developers by
/// screenscraper.fr, and are required. The user account is optional: signing
/// in a screenscraper.fr account raises that person's daily quota.
struct ScreenScraperCredentials: Sendable, Equatable {
    var developerID = ""
    var developerPassword = ""
    var username = ""
    var password = ""

    /// Whether lookups can be made at all.
    var isUsable: Bool {
        !developerID.isEmpty && !developerPassword.isEmpty
    }

    /// Whether a personal account is attached to the app credentials.
    var hasAccount: Bool {
        !username.isEmpty && !password.isEmpty
    }

    /// Whether every field is empty.
    var isEmpty: Bool {
        developerID.isEmpty && developerPassword.isEmpty
            && username.isEmpty && password.isEmpty
    }
}

/// Reads and writes the ScreenScraper logins.
///
/// The two passwords go to the keychain; the two names are in user defaults,
/// where they are easier to read back in Settings. A build can also carry an
/// app key: if `ScreenScraperDevCredentials.plist` is copied into the app's
/// resources (it is not committed, see `Cassowary/README.md`), its values are
/// the defaults and anything saved here overrides them.
enum ScreenScraperCredentialStore {

    private static let developerIDKey = "cassowary.screenScraper.developerID"
    private static let usernameKey = "cassowary.screenScraper.username"
    private static let developerPasswordKey = "ScreenScraperDeveloperPassword"
    private static let passwordKey = "ScreenScraperPassword"

    /// The app key shipped with this build, if there is one.
    private static let bundled: (developerID: String, developerPassword: String)? = {
        guard let url = Bundle.main.url(forResource: "ScreenScraperDevCredentials", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
              let developerID = plist["devid"], !developerID.isEmpty,
              let developerPassword = plist["devpassword"], !developerPassword.isEmpty
        else { return nil }
        return (developerID, developerPassword)
    }()

    /// Whether this build has an app key in its resources.
    static var hasBundledAppKey: Bool { bundled != nil }

    static func load() -> ScreenScraperCredentials {
        var credentials = ScreenScraperCredentials()
        credentials.developerID = UserDefaults.standard.string(forKey: developerIDKey) ?? ""
        credentials.developerPassword = KeychainStore.string(for: developerPasswordKey) ?? ""
        credentials.username = UserDefaults.standard.string(forKey: usernameKey) ?? ""
        credentials.password = KeychainStore.string(for: passwordKey) ?? ""

        if let bundled {
            if credentials.developerID.isEmpty { credentials.developerID = bundled.developerID }
            if credentials.developerPassword.isEmpty { credentials.developerPassword = bundled.developerPassword }
        }
        return credentials
    }

    static func save(_ credentials: ScreenScraperCredentials) {
        let defaults = UserDefaults.standard
        defaults.set(credentials.developerID, forKey: developerIDKey)
        defaults.set(credentials.username, forKey: usernameKey)
        KeychainStore.set(credentials.developerPassword, for: developerPasswordKey)
        KeychainStore.set(credentials.password, for: passwordKey)
    }

    static func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: developerIDKey)
        defaults.removeObject(forKey: usernameKey)
        KeychainStore.set(nil, for: developerPasswordKey)
        KeychainStore.set(nil, for: passwordKey)
    }
}

/// The small slice of the keychain this app needs: one string per key.
enum KeychainStore {

    private static let service = "org.cassowary.Cassowary"

    private static func query(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    static func string(for key: String) -> String? {
        var query = query(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for key: String) {
        guard let value, !value.isEmpty else {
            SecItemDelete(query(for: key) as CFDictionary)
            return
        }

        let data = Data(value.utf8)
        let updated = SecItemUpdate(
            query(for: key) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updated == errSecItemNotFound {
            var attributes = query(for: key)
            attributes[kSecValueData as String] = data
            // Readable after the first unlock, which covers a download that
            // starts while the phone is in a pocket.
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }
}
