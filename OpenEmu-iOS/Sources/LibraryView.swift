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

    var body: some View {
        NavigationStack {
            Group {
                if library.games.isEmpty {
                    emptyState
                } else {
                    gameList
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

            // Used by Scripts/ios/run-ios.sh to boot a game without tapping.
            // Harmless in normal use: the flag is only set when passed on the
            // command line.
            if UserDefaults.standard.bool(forKey: "OEAutoPlayFirstGame"),
               playing == nil,
               let first = library.games.first {
                playing = first
            }
        }
    }

    private var gameList: some View {
        List {
            ForEach(library.games) { game in
                Button {
                    playing = game
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(game.title)
                                .font(.body)
                            if let system = game.systemName {
                                Text(system)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.tint)
                    }
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("Delete", role: .destructive) {
                        library.delete(game)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Games", systemImage: "gamecontroller")
        } description: {
            Text("Copy ROM files into OpenEmu using the Files app or Finder, then tap Refresh.")
        }
    }
}

/// Plays one game.
struct GameView: View {

    let game: Game
    let onClose: () -> Void

    @State private var session: GameSession?
    @State private var layout: ControllerLayout?
    @State private var errorMessage: String?
    @State private var isPaused = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let session, let layer = session.videoLayer, let layout {
                GameLayerView(layer: layer) { bounds in
                    session.updateDisplayBounds(bounds)
                }
                .ignoresSafeArea(edges: .horizontal)

                OnScreenControls(layout: layout, session: session)
                    .ignoresSafeArea(edges: .horizontal)
            }

            if let errorMessage {
                ContentUnavailableView {
                    Label("Could Not Start", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Close", action: onClose)
                }
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .overlay(alignment: .topLeading) {
            controlsOverlay
        }
        .task {
            startGame()
        }
        .onDisappear {
            session?.stop()
            session = nil
        }
    }

    private var controlsOverlay: some View {
        HStack(spacing: 16) {
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .padding(10)
                    .background(.ultraThinMaterial, in: .circle)
            }

            if let session {
                Button {
                    isPaused.toggle()
                    session.setPaused(isPaused)
                } label: {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .font(.body.weight(.semibold))
                        .padding(10)
                        .background(.ultraThinMaterial, in: .circle)
                }
            }
        }
        .padding()
    }

    private func startGame() {
        do {
            let session = try GameSession(romURL: game.url)
            let plugin = OESystemPlugin.allPlugins.first {
                $0.supportedTypeExtensions
                    .map { $0.lowercased() }
                    .contains(game.url.pathExtension.lowercased())
            }
            if let plugin {
                layout = ControllerLayout(systemPlugin: plugin)
            }
            self.session = session
            session.start {}
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
