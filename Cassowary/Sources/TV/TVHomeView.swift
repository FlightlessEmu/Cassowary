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

/// The Apple TV app's root: the library, the sources, and settings, with the
/// game on top when one is running.
///
/// The tabs are the platform's own navigation on purpose. A hand-rolled header
/// of buttons looked right but the focus engine could not always reach it,
/// and on a TV reachable is the whole game. The tab bar is always one swipe
/// up from anywhere.
struct TVHomeView: View {

    @ObservedObject private var store = TVStore.shared

    @State private var playing: TVStore.LocalGame?

    /// A game picked before the source was reachable, waiting for the link.
    @State private var waitingToPlay: TVStore.LocalGame?

    var body: some View {
        Group {
            if let playing, let url = store.playableURL(for: playing) {
                TVPlayerView(title: playing.title,
                             url: url,
                             onFinished: { store.finishPlaying(playing) }) {
                    // Test runs start the first game by themselves. Clearing
                    // the flag here, when the game closes, keeps the
                    // download-then-play path working and still shows the
                    // library afterwards rather than starting again.
                    UserDefaults.standard.set(false, forKey: "cassowary.autoPlayFirstGame")
                    self.playing = nil
                }
            } else {
                TabView {
                    TVLibraryView { game in
                        play(game)
                    }
                    .tabItem {
                        Label("Library", systemImage: "square.grid.2x2")
                    }

                    TVSourcesView()
                        .tabItem {
                            Label("Sources", systemImage: "rectangle.2.swap")
                        }

                    TVSettingsView()
                        .tabItem {
                            Label("Settings", systemImage: "gearshape")
                        }
                }
            }
        }
        .onAppear {
            store.start()
            autoPlayIfAsked()
        }
        .onChange(of: store.games) { _, _ in
            autoPlayIfAsked()
        }
        .onChange(of: store.connection) { _, _ in
            // A game picked while the phone was away starts as soon as the
            // link is back, so a tap is never wasted.
            if store.connection.isConnected, let waiting = waitingToPlay {
                waitingToPlay = nil
                play(waiting)
            }
        }
    }

    private func play(_ game: TVStore.LocalGame) {
        guard store.hasCore(for: game) else {
            store.note("No core for \(game.systemName) is on this Apple TV yet.")
            return
        }

        if game.isDownloaded {
            store.prepareForPlay(game)
            playing = game
        } else if store.connection.isConnected {
            Task {
                await store.download(game)
                if let updated = store.state.games[game.id], updated.isDownloaded {
                    store.prepareForPlay(updated)
                    playing = updated
                }
            }
        } else {
            // The source is away. Hold the request rather than dropping it:
            // the game starts by itself once the phone is back.
            NSLog("[Cassowary] holding %@ until a source is back", game.title)
            waitingToPlay = game
            store.note("\(game.title) will start as soon as a source is back.")
        }
    }

    /// The test scripts ask for the first shared game without tapping. The
    /// library may already be loaded when this view appears, so both the
    /// on-appear and the on-change paths call this. In normal use the flag is
    /// not set.
    private func autoPlayIfAsked() {
        guard UserDefaults.standard.bool(forKey: "cassowary.autoPlayFirstGame"),
              playing == nil,
              let first = store.games.first else { return }
        play(first)
    }
}
