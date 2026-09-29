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
import OpenEmuKit

/// The RetroAchievements account this device plays with.
///
/// The login token lives in the keychain; the display name is in user
/// defaults so Settings can show it without unlocking anything. The password
/// itself is never kept: it is used once to sign in and then dropped.
struct RetroAchievementsCredentials: Sendable, Equatable {
    var username = ""
    var displayName = ""
    var token = ""

    var isSignedIn: Bool { !username.isEmpty && !token.isEmpty }
}

/// Reads and writes the RetroAchievements login.
///
/// Mirrors `ScreenScraperCredentialStore`: names in user defaults, the secret
/// in the keychain.
enum RetroAchievementsCredentialStore {

    private static let usernameKey = "cassowary.retroachievements.username"
    private static let displayNameKey = "cassowary.retroachievements.displayName"
    private static let tokenKey = "RetroAchievementsToken"

    /// Whether the user wants hardcore mode when signed in. On by default:
    /// that is what RetroAchievements recommends, and unlocks earned in
    /// softcore never upgrade. Turning it off allows save states, rewind,
    /// and cheats, but earns softcore unlocks only.
    static let hardcoreKey = "cassowary.retroachievements.hardcore"

    static var hardcoreEnabled: Bool {
        get {
            // A missing key means "never chose": default on.
            UserDefaults.standard.object(forKey: hardcoreKey) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: hardcoreKey) }
    }

    static func load() -> RetroAchievementsCredentials {
        var credentials = RetroAchievementsCredentials()
        credentials.username = UserDefaults.standard.string(forKey: usernameKey) ?? ""
        credentials.displayName = UserDefaults.standard.string(forKey: displayNameKey) ?? ""
        credentials.token = KeychainStore.string(for: tokenKey) ?? ""
        return credentials
    }

    static func save(username: String, displayName: String, token: String) {
        UserDefaults.standard.set(username, forKey: usernameKey)
        UserDefaults.standard.set(displayName, forKey: displayNameKey)
        KeychainStore.set(token, for: tokenKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: usernameKey)
        UserDefaults.standard.removeObject(forKey: displayNameKey)
        KeychainStore.set(nil, for: tokenKey)
    }
}

/// Signs in with a RetroAchievements username and password.
///
/// Goes through the shared `rc_client` login (the same transport the games
/// use), not a hand-rolled web request, so the token it returns is the one
/// the emulator cores expect.
enum RetroAchievementsLogin {

    struct Result: Sendable, Equatable {
        var username: String
        var displayName: String
        var token: String
    }

    enum LoginError: LocalizedError {
        case message(String)

        var errorDescription: String? {
            if case .message(let text) = self { return text }
            return nil
        }
    }

    static func signIn(username: String, password: String) async throws -> Result {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await withCheckedThrowingContinuation { continuation in
            OERetroAchievementsLoginClient.login(withUsername: trimmed, password: password) { token, displayName, error in
                if let token, !token.isEmpty {
                    continuation.resume(returning: Result(
                        username: trimmed,
                        displayName: (displayName?.isEmpty == false) ? displayName! : trimmed,
                        token: token
                    ))
                } else {
                    let message = (error as? LocalizedError)?.errorDescription
                        ?? error?.localizedDescription
                        ?? "RetroAchievements refused that login."
                    continuation.resume(throwing: LoginError.message(message))
                }
            }
        }
    }
}
