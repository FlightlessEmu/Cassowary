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
import UIKit

/// The library: the same shape as the phone's — a sidebar of systems next to
/// a grid of games — over the TV's own library.
///
/// The games come from a source (the phone, and later a network share), but
/// the library here is the TV's: what is downloaded stays and plays whether
/// the source is around or not.
struct TVLibraryView: View {

    /// Called when a game should start. The root view owns the player so the
    /// tab bar is not in the way.
    var onPlay: (TVStore.LocalGame) -> Void

    /// What the sidebar has selected. Systems are keyed by identifier: names
    /// are display only, and two systems never share an identifier.
    private enum Selection: Hashable {
        case all
        case favorites
        case recent
        case system(String)
    }

    /// How the grid is ordered. The phone sorts the same two ways.
    private enum SortOption: String, CaseIterable, Identifiable {
        case title
        case system

        var id: String { rawValue }
    }

    @ObservedObject private var store = TVStore.shared
    @StateObject private var coreCatalog = CoreCatalog()

    @State private var showConflict = false
    @State private var selection: Selection = .all
    @State private var searchText = ""
    @State private var sort: SortOption = .title
    /// Which sidebar row has the focus, so the highlight can be drawn here
    /// rather than by the TV's focus effect.
    @FocusState private var focusedRow: Selection?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                status

                HStack(spacing: 0) {
                    sidebar
                        .frame(width: 360)

                    Divider()

                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .sheet(isPresented: $showConflict) {
            if let conflict = store.conflicts.first {
                TVConflictView(conflict: conflict)
            }
        }
        .onAppear {
            store.start()
            coreCatalog.refresh()
        }
        .onChange(of: store.conflicts.count) { _, count in
            if count > 0 { showConflict = true }
        }
    }

    // MARK: - Status line

    /// Where the games are coming from, and what is waiting. The buttons that
    /// used to live here are tabs now, because the focus engine could not be
    /// trusted to reach them.
    private var status: some View {
        HStack(spacing: 16) {
            switch store.connection {
            case .connected(let host):
                Label("Games from \(host.name)", systemImage: "wifi")
                    .foregroundStyle(.secondary)
            case .connecting(let name):
                Label("Connecting to \(name)…", systemImage: "wifi")
                    .foregroundStyle(.secondary)
            default:
                Label("Downloaded games · not connected", systemImage: "wifi.slash")
                    .foregroundStyle(.orange)
            }

            if store.libraryIsLoading {
                ProgressView()
            }

            if store.pendingUploads > 0 {
                Label("\(store.pendingUploads) save\(store.pendingUploads == 1 ? "" : "s") to send",
                      systemImage: "arrow.up.circle")
                    .foregroundStyle(.secondary)
            }

            if let summary = store.syncSummary {
                Text(summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 60)
        .padding(.top, 20)
    }

    // MARK: - Sidebar

    /// The sidebar the phone's library has, in the shape tvOS allows: a
    /// column of focusable rows rather than a selectable List (tvOS has no
    /// selection binding for lists).
    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
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
                        ForEach(systems, id: \.id) { system in
                            sidebarRow(system.name,
                                       symbol: nil,
                                       icon: coreCatalog.system(forIdentifier: system.id)?.icon,
                                       count: system.count,
                                       value: .system(system.id))
                        }
                    }
                }
            }
            // More room on the right than the left: a focused row grows a
            // little under the TV's focus effect, and without room to grow the
            // glow is cut off by the divider.
            .padding(.leading, 24)
            .padding(.trailing, 44)
            .padding(.vertical, 24)
        }
        .scrollIndicators(.hidden)
        // The sidebar behaves as one block, so pressing Right from any row
        // reaches the games: without a section the engine only looks for a
        // tile whose frame overlaps the focused row, and the first row sits
        // above the first tile.
        .focusSection()
    }

    @ViewBuilder
    private func sidebarSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        // The spacing is generous on purpose: a focused row grows a little
        // under the TV's focus effect, and with a tight gap that highlight
        // would cover the section heading above it.
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
            content()
        }
    }

    private func sidebarRow(_ title: String, symbol: String, count: Int, value: Selection) -> some View {
        sidebarRow(title, symbol: symbol, icon: nil, count: count, value: value)
    }

    private func sidebarRow(_ title: String, symbol: String?, icon: UIImage?, count: Int, value: Selection) -> some View {
        Button {
            selection = value
        } label: {
            HStack(spacing: 14) {
                if let icon {
                    Image(uiImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: symbol ?? "gamecontroller")
                        .font(.system(size: 20))
                        .frame(width: 28)
                }
                Text(title)
                    .font(.body)
                Spacer(minLength: 12)
                Text("\(count)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(rowBackground(value), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        // The TV's focus effect grows the row and draws its own outline, which
        // reached outside the sidebar and over the heading above. The highlight
        // is drawn here instead, so it stays exactly on the row.
        .focusEffectDisabled()
        .focused($focusedRow, equals: value)
    }

    private func rowBackground(_ value: Selection) -> Color {
        if focusedRow == value { return Color.white.opacity(0.30) }
        if selection == value { return Color.white.opacity(0.14) }
        return .clear
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Text(detailTitle)
                    .font(.title2.weight(.semibold))

                Spacer()

                TextField("Search", text: $searchText)
                    .frame(maxWidth: 320)

                Menu {
                    Picker("Sort by", selection: $sort) {
                        Text("Title").tag(SortOption.title)
                        Text("System").tag(SortOption.system)
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
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
                        onPlay(game)
                    } label: {
                        tile(game)
                    }
                    .buttonStyle(.card)
                    .contextMenu {
                        if game.isDownloaded, game.sourceDeviceID != nil {
                            Button("Remove Download", role: .destructive) {
                                store.removeDownload(game)
                            }
                        } else if !game.isDownloaded {
                            Button("Download") {
                                Task { await store.download(game) }
                            }
                        }
                        if store.artwork[game.id] == nil {
                            Button("Retry Cover Art") {
                                store.retryArtwork(for: game)
                            }
                        }
                        Button(game.favorite ? "Remove from Favorites" : "Add to Favorites") {
                            store.toggleFavorite(game)
                        }
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 16)
            .padding(.bottom, 40)
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
        switch selection {
        case .favorites: return "Nothing is marked as a favorite yet. Long-press a game to add one."
        case .recent:    return "Nothing has been played on this Apple TV yet."
        case .system(let id): return "No \(systemName(for: id)) games are in the library."
        default:         return "No games yet. Open Sources to connect to a phone."
        }
    }

    private func tile(_ game: TVStore.LocalGame) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.quaternary)

                // Art, or the system's icon when there is none: box art comes
                // in every shape, and cropping it to the square keeps the grid
                // even. The same rule as the phone's tiles.
                if let image = store.artwork[game.id] {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if let icon = coreCatalog.system(forIdentifier: game.systemIdentifier)?.icon {
                    Image(uiImage: icon)
                        .resizable()
                        .scaledToFit()
                        .padding(24)
                } else {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.secondary)
                }

                if store.hasLocalSaveState(for: game) || store.isFetchingArtwork(game.id) {
                    VStack {
                        HStack {
                            Spacer()
                            if store.hasLocalSaveState(for: game) {
                                Image(systemName: "bookmark.fill")
                                    .font(.caption)
                                    .foregroundStyle(.white)
                                    .padding(7)
                                    .background(.black.opacity(0.45), in: .circle)
                            }
                        }
                        Spacer()
                        HStack {
                            if store.isFetchingArtwork(game.id) {
                                ProgressView()
                                    .tint(.white)
                                    .padding(6)
                                    .background(.black.opacity(0.45), in: .circle)
                            }
                            Spacer()
                        }
                    }
                    .padding(8)
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
            .clipShape(.rect(cornerRadius: 18))

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

    private struct SystemGroup: Hashable {
        var id: String
        var name: String
        var count: Int
    }

    private var systems: [SystemGroup] {
        Dictionary(grouping: store.games, by: \.systemIdentifier)
            .map { id, games in
                SystemGroup(id: id,
                            name: games.first?.systemName ?? "Unknown System",
                            count: games.count)
            }
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
        var games: [TVStore.LocalGame]
        switch selection {
        case .all:               games = store.games
        case .favorites:         games = favorites
        case .recent:            games = recent
        case .system(let id):    games = store.games.filter { $0.systemIdentifier == id }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            games = games.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }

        switch sort {
        case .title:
            games.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .system:
            games.sort {
                if $0.systemName != $1.systemName {
                    return $0.systemName.localizedStandardCompare($1.systemName) == .orderedAscending
                }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }

        return games
    }

    private var detailTitle: String {
        switch selection {
        case .all:              return "All Games"
        case .favorites:        return "Favorites"
        case .recent:           return "Continue"
        case .system(let id):   return systemName(for: id)
        }
    }

    private func systemName(for identifier: String) -> String {
        store.games.first { $0.systemIdentifier == identifier }?.systemName ?? "Games"
    }
}
