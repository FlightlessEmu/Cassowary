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

/// The Apple TV's home screen: the same shape as the phone's library — a
/// sidebar of systems, a grid of games — over the TV's own library.
///
/// The games come from a source (the phone, and later a network share), but
/// the library here is the TV's: what is downloaded stays and plays whether
/// the source is around or not.
struct TVLibraryView: View {

    /// What the sidebar has selected.
    private enum Selection: Hashable {
        case all
        case favorites
        case recent
        case system(String)
    }

    @ObservedObject private var store = TVStore.shared

    @State private var playing: TVStore.LocalGame?
    @State private var showSettings = false
    @State private var showConflict = false
    @State private var showConnect = false
    @State private var selection: Selection = .all

    var body: some View {
        Group {
            if let playing, let url = store.playableURL(for: playing) {
                TVPlayerView(title: playing.title,
                             url: url,
                             onFinished: { store.finishPlaying(playing) }) {
                    self.playing = nil
                }
            } else if showsLibrary && !showConnect {
                // Anything borrowed before stays visible and playable with no
                // phone around: the cache is the library here.
                library
            } else {
                TVConnectView(onClose: showsLibrary ? { showConnect = false } : nil)
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
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 60)
                .padding(.top, 24)
                .padding(.bottom, 12)

            HStack(spacing: 0) {
                sidebar
                    .frame(width: 380)

                Divider()

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onChange(of: store.conflicts.count) { _, count in
            if count > 0 { showConflict = true }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Cassowary")
                    .font(.system(size: 44, weight: .semibold))

                switch store.connection {
                case .connected(let host):
                    Text("Games from \(host.name)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .connecting(let name):
                    Text("Connecting to \(name)…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                default:
                    Text("Downloaded games · not connected")
                        .font(.callout)
                        .foregroundStyle(.orange)
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

            if store.connection.isConnected {
                Button {
                    Task { await store.syncNow() }
                } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            Button {
                showConnect = true
            } label: {
                Label("Sources", systemImage: "rectangle.2.swap")
            }

            Button {
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }

    /// The sidebar the phone's library has, in the shape tvOS allows: a
    /// column of focusable rows rather than a selectable List (tvOS has no
    /// selection binding for lists).
    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                sidebarSection("Library") {
                    sidebarRow("All Games", symbol: "square.grid.2x2",
                               count: store.games.count, value: .all)
                    sidebarRow("Continue", symbol: "clock",
                               count: recent.count, value: .recent)
                    sidebarRow("Favorites", symbol: "star",
                               count: favorites.count, value: .favorites)
                }

                if !systems.isEmpty {
                    sidebarSection("Systems") {
                        ForEach(systems, id: \.name) { system in
                            sidebarRow(system.name, symbol: "gamecontroller",
                                       count: system.count, value: .system(system.name))
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private func sidebarSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
            content()
        }
    }

    private func sidebarRow(_ title: String, symbol: String, count: Int, value: Selection) -> some View {
        Button {
            selection = value
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .frame(width: 28)
                Text(title)
                    .font(.body)
                Spacer(minLength: 12)
                Text("\(count)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(selection == value ? Color.white.opacity(0.16) : Color.clear,
                        in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(detailTitle)
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 40)
                .padding(.top, 28)
                .padding(.bottom, 8)

            if visibleGames.isEmpty {
                emptyState
            } else {
                grid
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 360), spacing: 36)], spacing: 44) {
                ForEach(visibleGames) { game in
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
            .padding(40)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text(emptyMessage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 700)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyMessage: String {
        if let summary = store.syncSummary {
            return summary
        }
        switch selection {
        case .favorites: return "Nothing is marked as a favorite yet. Long-press a game to add one."
        case .recent:    return "Nothing has been played on this Apple TV yet."
        case .system(let name): return "No \(name) games are in the library."
        default:         return "No games yet. Open Sources to connect to a phone."
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
            if !store.hasCore(for: game) {
                Label("No TV core", systemImage: "nosign")
                    .foregroundStyle(.orange)
            } else if game.isDownloaded {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if store.progress(for: game.id) != nil {
                Label("Downloading", systemImage: "arrow.down.circle")
                    .foregroundStyle(.blue)
            } else if store.isSourceAvailable(for: game) {
                Label("On \(game.sourceName ?? "the source")", systemImage: "arrow.down.circle")
                    .foregroundStyle(.secondary)
            } else {
                Label("\(game.sourceName ?? "Source") not connected", systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
    }

    // MARK: - Data

    private var systems: [(name: String, count: Int)] {
        Dictionary(grouping: store.games, by: \.systemName)
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var favorites: [TVStore.LocalGame] {
        store.games.filter(\.favorite)
    }

    private var recent: [TVStore.LocalGame] {
        store.games
            .filter { $0.lastPlayedAt != nil }
            .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
    }

    private var visibleGames: [TVStore.LocalGame] {
        switch selection {
        case .all:               return store.games
        case .favorites:         return favorites
        case .recent:            return recent
        case .system(let name):  return store.games.filter { $0.systemName == name }
        }
    }

    private var detailTitle: String {
        switch selection {
        case .all:              return "All Games"
        case .favorites:        return "Favorites"
        case .recent:           return "Continue"
        case .system(let name): return name
        }
    }

    // MARK: - Launching

    private func play(_ game: TVStore.LocalGame) {
        guard store.hasCore(for: game) else {
            store.note("No core for \(game.systemName) is on this Apple TV yet.")
            return
        }

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

    /// Whether the home screen should be the library. A game that came from a
    /// source means the library is worth showing even when that source is
    /// away; a TV that only has the bundled demo starts on Sources instead.
    private var showsLibrary: Bool {
        if store.connection.isConnected { return true }
        return store.games.contains { $0.sourceDeviceID != nil }
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
