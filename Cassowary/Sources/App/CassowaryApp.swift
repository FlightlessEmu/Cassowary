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
import OpenEmuBase
import OpenEmuKit

@main
struct CassowaryApp: App {
#if targetEnvironment(macCatalyst)
    @Environment(\.openWindow) private var openWindow
#endif

    init() {
        // Plugins are discovered by scanning the app bundle and Application
        // Support. This has to run before any plugin is looked up.
        OECorePlugin.registerClass()
        OESystemPlugin.registerClass()

        // Ask the system for the crash and hang reports it has collected. They
        // arrive on a later launch, so this is set up before anything can run.
        DiagnosticsStore.shared.start()

        // Listens for a Nintendo DS game asking for the microphone; nothing is
        // captured, or asked for, until one does.
        MicrophoneCapture.shared.start()

#if DEBUG
        // Seed a report so the Diagnostics screen can be looked at without
        // waiting for a real crash. Used by Scripts/cassowary/run-cassowary.sh.
        if UserDefaults.standard.bool(forKey: "cassowary.writeSampleDiagnostics") {
            DiagnosticsStore.shared.writeSampleReport()
        }

        // Stand in a RetroAchievements sign-in, written as "name:token", and
        // share it with the TV, so sharing the sign-in can be checked without
        // a real account. "off" clears it and stops sharing.
        if let spec = UserDefaults.standard.string(forKey: "cassowary.testRetroAchievementsSignIn") {
            if spec == "off" {
                RetroAchievementsCredentialStore.clear()
                RetroAchievementsCredentialStore.sharesWithTV = false
            } else {
                let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    RetroAchievementsCredentialStore.save(username: parts[0], displayName: parts[0], token: parts[1])
                    RetroAchievementsCredentialStore.sharesWithTV = true
                }
            }
        }
#endif
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
        }
        .commands {
            SidebarCommands()
#if targetEnvironment(macCatalyst)
            CommandGroup(after: .newItem) {
                Button("Add Games…") {
                    NotificationCenter.default.post(name: .addGames, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
#endif
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
#if targetEnvironment(macCatalyst)
                    openWindow(id: "settings", value: "settings")
#else
                    NotificationCenter.default.post(name: .showSettings, object: nil)
#endif
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Library") {
#if targetEnvironment(macCatalyst)
                Button("Search Games") {
                    NotificationCenter.default.post(name: .searchGames, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
                Menu("Sort Games By") {
                    Button("Title") {
                        NotificationCenter.default.post(name: .sortGames, object: "title")
                    }
                    Button("System") {
                        NotificationCenter.default.post(name: .sortGames, object: "system")
                    }
                }
                Divider()
#endif
                Button("Refresh Library") {
                    NotificationCenter.default.post(name: .refreshLibrary, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
#if targetEnvironment(macCatalyst)
        WindowGroup("Settings", id: "settings", for: String.self) { _ in
            SettingsView()
        } defaultValue: {
            "settings"
        }
        .defaultSize(width: 760, height: 600)
#endif
    }
}
