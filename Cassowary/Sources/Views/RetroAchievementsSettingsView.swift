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

import SwiftUI

/// RetroAchievements sign-in and hardcore preference.
///
/// Signing in earns achievements, leaderboards, and rich presence in the
/// cores that support them. It takes effect for games launched afterwards.
struct RetroAchievementsSettingsView: View {

    @State private var credentials = RetroAchievementsCredentialStore.load()
    @State private var enteredUsername = ""
    @State private var password = ""
    @State private var hardcore = RetroAchievementsCredentialStore.hardcoreEnabled
    @State private var status: Status = .idle

    private enum Status: Equatable {
        case idle
        case signingIn
        case signedIn
        case failed(String)
    }

    var body: some View {
        List {
            Section {
                if credentials.isSignedIn {
                    LabeledContent("Signed In", value: credentials.displayName)
                    Button("Sign Out", role: .destructive) {
                        RetroAchievementsCredentialStore.clear()
                        credentials = RetroAchievementsCredentialStore.load()
                        password = ""
                        status = .idle
                    }
                } else {
                    TextField("Username", text: $enteredUsername)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    Button("Sign In") {
                        signIn()
                    }
                    .disabled(enteredUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty || status == .signingIn)
                }

                statusLine
            } header: {
                Text("Account")
            } footer: {
                Text("A free retroachievements.org account. The password is used once to sign in and is never kept; only the login token is stored, in the keychain. Signing in or out takes effect for games launched afterwards.")
            }

            Section {
                Toggle("Hardcore Mode", isOn: $hardcore)
                    .onChange(of: hardcore) { _, newValue in
                        RetroAchievementsCredentialStore.hardcoreEnabled = newValue
                    }
                Text("Hardcore is what RetroAchievements recommends: unlocks earned without it never upgrade. While it is on, save states, rewind, cheats, and slow motion are turned off, and they stay off when no achievement set is loaded either.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Hardcore")
            } footer: {
                Text(credentials.isSignedIn
                     ? "Applies to games launched afterwards."
                     : "Sign in above to earn achievements. Hardcore only matters while signed in.")
            }
        }
        .navigationTitle("Achievements")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .idle:
            if credentials.isSignedIn {
                Text("Achievements, leaderboards, and rich presence are on for supported cores.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not signed in. Games play normally with no achievements.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .signingIn:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Signing in…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .signedIn:
            Label("Sign-in works.", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func signIn() {
        let username = enteredUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = password
        guard !username.isEmpty, !secret.isEmpty else { return }
        status = .signingIn
        Task { @MainActor in
            do {
                let result = try await RetroAchievementsLogin.signIn(username: username, password: secret)
                RetroAchievementsCredentialStore.save(username: result.username,
                                                      displayName: result.displayName,
                                                      token: result.token)
                credentials = RetroAchievementsCredentialStore.load()
                enteredUsername = ""
                password = ""
                status = .signedIn
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }
}
