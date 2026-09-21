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

/// The Apple TV's home screen.
///
/// There is no host connection yet, so this shows what the app can already
/// play on its own: the demo game in the bundle. A phone-hosted library is
/// the next phase.
struct TVLibraryView: View {

    @State private var games: [TVDemoGame] = []
    @State private var playing: TVDemoGame?

    var body: some View {
        ZStack {
            if let playing {
                TVPlayerView(game: playing) {
                    self.playing = nil
                }
            } else {
                library
            }
        }
        .onAppear {
            games = TVDemoLibrary.load()

            // Used by the run script to boot a game without pressing anything,
            // the same flag the phone app honors. Harmless in normal use: it is
            // only set from the command line.
            if UserDefaults.standard.bool(forKey: "cassowary.autoPlayFirstGame"),
               playing == nil,
               let first = games.first {
                playing = first
            }
        }
    }

    // MARK: - Library

    private var library: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 56) {
                VStack(spacing: 12) {
                    Text("Cassowary")
                        .font(.system(size: 76, weight: .semibold))

                    Text("The emulator now runs on Apple TV.\nGames from your iPhone are the next step.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if games.isEmpty {
                    Text("No demo game was found in this build.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 56) {
                        ForEach(games) { game in
                            Button {
                                playing = game
                            } label: {
                                tile(for: game)
                            }
                            .buttonStyle(.card)
                        }
                    }
                }
            }
            .padding(80)
        }
    }

    private func tile(for game: TVDemoGame) -> some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.quaternary)

                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 90))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 380, height: 380)

            VStack(spacing: 4) {
                Text(game.title)
                    .font(.title3.weight(.semibold))
                Text(game.systemName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
