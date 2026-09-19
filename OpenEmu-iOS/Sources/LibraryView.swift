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
import OpenEmuSystem
import OpenEmuKit

/// The library: everything the app can play.
struct LibraryView: View {

    @StateObject private var library = GameLibrary()
    @State private var playing: Game?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 20)]

    var body: some View {
        NavigationStack {
            Group {
                if library.games.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .navigationTitle("OpenEmu")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        library.refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .fullScreenCover(item: $playing) { game in
            GameView(game: game) {
                playing = nil
            }
        }
        .onAppear {
            library.refresh()

            // Used by Scripts/ios/test-ios.sh to boot a game without tapping.
            // Harmless in normal use: the flag is only set when passed on the
            // command line.
            if UserDefaults.standard.bool(forKey: "OEAutoPlayFirstGame"),
               playing == nil,
               let first = library.games.first {
                playing = first
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(library.games) { game in
                    Button {
                        playing = game
                    } label: {
                        GameTile(game: game)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            library.delete(game)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Games", systemImage: "gamecontroller")
        } description: {
            Text("Copy ROM files into OpenEmu using the Files app or Finder, then tap Refresh.")
        }
    }
}

/// One game in the library grid.
private struct GameTile: View {

    let game: Game

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.quaternary)

                if let icon = game.system?.icon {
                    Image(uiImage: icon)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                } else {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(1, contentMode: .fit)

            VStack(spacing: 2) {
                Text(game.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)

                if let system = game.systemName {
                    Text(system)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
