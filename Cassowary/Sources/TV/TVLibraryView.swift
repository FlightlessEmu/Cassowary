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

/// The Apple TV's home screen: the games the phone is sharing.
///
/// A game is downloaded before it can be played, and the badge on each tile
/// says whether it is ready. What is downloaded lives in the cache and can be
/// taken away at any time, so nothing here is ever the only copy.
struct TVLibraryView: View {

    @ObservedObject private var store = TVStore.shared

    @State private var playing: TVStore.LocalGame?
    @State private var showSettings = false
    @State private var showConflict = false

    var body: some View {
        Group {
            if let playing, let url = store.playableURL(for: playing) {
                TVPlayerView(title: playing.title,
                             url: url,
                             onFinished: { store.finishPlaying(playing) }) {
                    self.playing = nil
                }
            } else if store.connection.isConnected {
                library
            } else {
                TVConnectView()
            }
        }
        .sheet(isPresented: $showSettings) {
            TVSettingsView()
        }
        .sheet(isPresented: $showConflict) {
            if let conflict = store.conflicts.first {
                TVConflictView(conflict: conflict)
            }
        }
        .onAppear {
            store.start()
            autoPlayIfAsked()
        }
        .onChange(of: store.games) { _, _ in
            autoPlayIfAsked()
        }
    }

    // MARK: - Library

    private var library: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                header

                if let banner = store.syncSummary {
                    Text(banner)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !store.conflicts.isEmpty {
                    conflictBanner
                }

                if !recent.isEmpty {
                    section("Continue", games: recent)
                }

                section("All Games", games: store.games)
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 40)
        }
        .background(Color.black.ignoresSafeArea())
        .onChange(of: store.conflicts.count) { _, count in
            if count > 0 { showConflict = true }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Cassowary")
                    .font(.system(size: 52, weight: .semibold))
                if case .connected(let host) = store.connection {
                    Text("Games from \(host.name)")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if store.libraryIsLoading {
                ProgressView()
            }

            if store.pendingUploads > 0 {
                Label("\(store.pendingUploads) save\(store.pendingUploads == 1 ? "" : "s") to send",
                      systemImage: "arrow.up.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await store.syncNow() }
            } label: {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }

            Button {
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }

    private var conflictBanner: some View {
        Button {
            showConflict = true
        } label: {
            Label("A save needs your choice", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.orange.opacity(0.25), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private func section(_ title: String, games: [TVStore.LocalGame]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title)
                .font(.title2.weight(.semibold))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 380), spacing: 36)], spacing: 44) {
                ForEach(games) { game in
                    Button {
                        play(game)
                    } label: {
                        tile(game)
                    }
                    .buttonStyle(.card)
                    .contextMenu {
                        if game.isDownloaded {
                            Button("Remove Download", role: .destructive) {
                                store.removeDownload(game)
                            }
                        } else {
                            Button("Download") {
                                Task { await store.download(game) }
                            }
                        }
                        Button(game.favorite ? "Remove from Favorites" : "Add to Favorites") {
                            store.toggleFavorite(game)
                        }
                    }
                }
            }
        }
    }

    private func tile(_ game: TVStore.LocalGame) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.quaternary)

                if let image = store.artwork[game.id] {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.secondary)
                }

                if let progress = store.progress(for: game.id) {
                    ZStack {
                        Color.black.opacity(0.6)
                        VStack(spacing: 10) {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .frame(width: 160)
                            Text("\(Int(progress * 100))%")
                                .font(.headline)
                        }
                    }
                    .clipShape(.rect(cornerRadius: 18))
                }
            }
            .aspectRatio(1, contentMode: .fit)

            VStack(alignment: .leading, spacing: 4) {
                Text(game.title)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(game.systemName)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    badge(for: game)

                    if game.favorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
            }
        }
    }

    private func badge(for game: TVStore.LocalGame) -> some View {
        Group {
            if game.isDownloaded {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if store.progress(for: game.id) != nil {
                Label("Downloading", systemImage: "arrow.down.circle")
                    .foregroundStyle(.blue)
            } else {
                Label("On \(store.state.lastHostName ?? "the phone")", systemImage: "arrow.down.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
    }

    private var recent: [TVStore.LocalGame] {
        store.games
            .filter { $0.lastPlayedAt != nil }
            .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
            .prefix(5)
            .map { $0 }
    }

    private func play(_ game: TVStore.LocalGame) {
        if game.isDownloaded {
            store.prepareForPlay(game)
            playing = game
        } else {
            Task {
                await store.download(game)
                if let updated = store.state.games[game.id], updated.isDownloaded {
                    store.prepareForPlay(updated)
                    playing = updated
                }
            }
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
