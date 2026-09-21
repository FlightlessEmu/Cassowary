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

/// Cover art settings: where images come from, and the account that unlocks
/// the optional second source.
struct CoverArtSettingsView: View {

    @StateObject private var library = GameLibrary()
    @StateObject private var store = CoverArtStore.shared

    @AppStorage(CoverArtSetting.automaticKey) private var automatic = true

    @State private var credentials = ScreenScraperCredentialStore.load()
    @State private var developerID = ""
    @State private var developerPassword = ""
    @State private var status: Status = .idle
    @State private var showAppKey = false

    /// What the last credential check said.
    private enum Status: Equatable {
        case idle
        case checking
        case valid
        case invalid(String)
    }

    var body: some View {
        List {
            Section {
                Toggle("Download Automatically", isOn: $automatic)
                Text("New games get their cover art in the background as the library is scanned.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Cover Art")
            } footer: {
                Text("Cassowary looks each game up on libretro-thumbnails, which is free and needs no account, and then on ScreenScraper when an app key is set up below. Downloaded images stay on this device.")
            }

            Section {
                LabeledContent("Games", value: "\(library.games.count)")
                LabeledContent("With Cover Art", value: "\(library.games.count - store.missingCount(in: library.games))")
                Button("Download Missing Artwork") {
                    store.downloadMissing(for: library.games)
                }
                .disabled(store.missingCount(in: library.games) == 0)

                if !store.images.isEmpty {
                    Button("Remove All Cover Art", role: .destructive) {
                        store.removeAllArtwork()
                    }
                }

                if let error = store.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Library")
            } footer: {
                Text("A game that is not found is left alone for a week before it is looked up again. Long-press a game for a single re-download.")
            }

            screenScraperSection
        }
        .navigationTitle("Cover Art")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { library.refresh() }
    }

    // MARK: - ScreenScraper

    private var screenScraperSection: some View {
        Section {
            TextField("Username", text: $credentials.username)
                .textContentType(.username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            SecureField("Password", text: $credentials.password)
                .textContentType(.password)

            Button("Save Account") {
                save(credentials)
            }
            .disabled(credentials.username.isEmpty || credentials.password.isEmpty)

            if credentials.hasAccount {
                Button("Sign Out", role: .destructive) {
                    var cleared = credentials
                    cleared.username = ""
                    cleared.password = ""
                    save(cleared)
                }
            }

            statusLine

            DisclosureGroup("App Key", isExpanded: $showAppKey) {
                if ScreenScraperCredentialStore.hasBundledAppKey {
                    Text("This build already includes an app key. The fields below replace it if you fill them in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("Developer ID", text: $developerID)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("Developer Password", text: $developerPassword)
                Button("Save App Key") {
                    var updated = credentials
                    updated.developerID = developerID
                    updated.developerPassword = developerPassword
                    save(updated)
                }
                .disabled(developerID.isEmpty || developerPassword.isEmpty)

                Text("ScreenScraper issues these to software developers. Without one, cover art still downloads from libretro-thumbnails.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("ScreenScraper")
        } footer: {
            Text("Optional. A free screenscraper.fr account raises your daily lookup limit. The password is kept in the keychain, not in the app's preferences.")
        }
        .onAppear {
            // Show the saved names but never a password that is not there.
            developerID = credentials.developerID
            developerPassword = credentials.developerPassword
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .idle:
            if credentials.isUsable {
                Text(credentials.hasAccount
                     ? "Signed in as \(credentials.username)."
                     : "No account attached. Lookups use the app key alone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No app key. Cover art downloads from libretro-thumbnails only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .valid:
            Label("Sign-in works.", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .invalid(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    /// Saves, then checks the credentials with ScreenScraper so the result is
    /// known now rather than at the next download.
    private func save(_ updated: ScreenScraperCredentials) {
        ScreenScraperCredentialStore.save(updated)

        // Keep the fields in step with what was saved, including the app key
        // that came out of the build.
        credentials = ScreenScraperCredentialStore.load()
        developerID = credentials.developerID
        developerPassword = credentials.developerPassword

        guard credentials.isUsable else {
            status = .idle
            return
        }

        status = .checking
        let checking = credentials
        Task { @MainActor in
            do {
                let ok = try await ScreenScraperClient.verify(checking)
                status = ok ? .valid : .invalid("ScreenScraper refused that login.")
            } catch let error as ScreenScraperClient.FetchError {
                status = .invalid(error.errorDescription ?? "Couldn't check the login.")
            } catch {
                status = .invalid("Couldn't check the login.")
            }
        }
    }
}
