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

    /// The save conflict on screen. Choosing a copy moves on to the next
    /// one; pressing Back leaves the rest for the Resolve button.
    @State private var presentedConflict: SaveConflict?
    @State private var resolvedOne = false
    /// Conflicts are offered only after the first layout pass: a sheet asked
    /// for during it is dropped.
    @State private var readyToOfferConflicts = false
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
        .sheet(item: $presentedConflict, onDismiss: {
            if resolvedOne {
                resolvedOne = false
                offerConflict()
            }
        }) { conflict in
            TVConflictView(conflict: conflict) { choice in
                store.resolve(conflict, choice: choice)
                resolvedOne = true
            }
        }
        .task {
            store.start()
            coreCatalog.refresh()
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            readyToOfferConflicts = true
            offerConflict()
        }
        .onChange(of: store.conflicts) { _, _ in
            if readyToOfferConflicts, presentedConflict == nil { offerConflict() }
        }
    }

    /// Asks about the first waiting conflict, if there is one.
    private func offerConflict() {
        #if DEBUG
        // A screenshot flag wants its own screen, not a real conflict.
        if TVScreenshotHooks.asksForScreen { return }
        #endif
        presentedConflict = store.conflicts.first
    }

    // MARK: - Status line

    /// Where the games are coming from, and saves waiting for a decision.
    private var status: some View {
        HStack(spacing: 14) {
            switch store.connection {
            case .connected(let host):
                statusPill(host.name, systemImage: "circle.fill", tint: .green)
            case .connecting(let name):
                statusPill("Connecting to \(name)…", systemImage: "circle.dotted", tint: .secondary)
            default:
                statusPill("Not connected · downloaded games only", systemImage: "wifi.slash", tint: .orange)
            }

            if store.libraryIsLoading {
                ProgressView()
                    .scaleEffect(0.7)
            }

            saveStatus

            if !store.conflicts.isEmpty {
                // The one pill that can be pressed: a conflict waits on a choice.
                Button {
                    presentedConflict = store.conflicts.first
                } label: {
                    statusPill("Resolve \(store.conflicts.count) Save Conflict\(store.conflicts.count == 1 ? "" : "s")",
                               systemImage: "exclamationmark.triangle.fill", tint: .orange)
                }
                .buttonStyle(.plain)
            }

            if let summary = store.syncSummary {
                statusPill(summary, systemImage: "arrow.triangle.2.circlepath", tint: .secondary)
                    .frame(maxWidth: 760, alignment: .leading)
            }

            Spacer()
        }
        // Lined up with the sidebar rows below.
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }

    /// How the saves stand with the connected source, in one pill: being
    /// synced, waiting to go, or when they last synced.
    @ViewBuilder
    private var saveStatus: some View {
        if store.isSyncing {
            statusPill("Syncing saves…", systemImage: "arrow.triangle.2.circlepath", tint: .secondary)
        } else if store.pendingUploads > 0 {
            statusPill("\(store.pendingUploads) save\(store.pendingUploads == 1 ? "" : "s") to send",
                       systemImage: "arrow.up.circle", tint: .secondary)
        } else if case .connected = store.connection, let date = store.lastSyncedAt {
            // Redrawn each minute so "2 minutes ago" stays true.
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                statusPill("Saves synced \(date.formatted(.relative(presentation: .named)))",
                           systemImage: "checkmark.circle", tint: .green)
            }
        }
    }

    /// One fact about the link, in a capsule, so several can sit on a line
    /// without running together.
    private func statusPill(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(tint)
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(.white.opacity(0.08), in: .capsule)
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
            HStack(spacing: 20) {
                Text(detailTitle)
                    .font(.title2.weight(.bold))

                Spacer()

                searchField

                Menu {
                    Picker("Sort by", selection: $sort) {
                        Text("Title").tag(SortOption.title)
                        Text("System").tag(SortOption.system)
                    }
                } label: {
                    Label(sort == .title ? "By Title" : "By System", systemImage: "arrow.up.arrow.down")
                        .font(.callout)
                }
            }
            .padding(.horizontal, 48)
            .padding(.top, 28)
            .padding(.bottom, 8)

            if visibleGames.isEmpty {
                emptyState
            } else {
                grid
            }
        }
    }

    /// The search box, drawn as one: on its own the TV draws a text field as
    /// bare grey words that do not look like something to press.
    private var searchField: some View {
        TextField(text: $searchText,
                  prompt: Text(Image(systemName: "magnifyingglass")) + Text("  Search Games")) {
            Text("Search Games")
        }
        .font(.callout)
        .frame(width: 440)
    }

    /// Whether All Games leads with the games played most recently.
    private var showsContinueShelf: Bool {
        selection == .all && searchText.isEmpty && !recent.isEmpty
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                if showsContinueShelf {
                    shelfHeading("Continue Playing")
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 40) {
                            ForEach(recent.prefix(10)) { game in
                                tile(game)
                                    .frame(width: 300)
                            }
                        }
                        .padding(.horizontal, 48)
                        .padding(.vertical, 20)
                    }
                    .scrollClipDisabled()
                    .scrollIndicators(.hidden)
                    // Down from the row reaches the grid, whichever column
                    // the focus is in.
                    .focusSection()

                    shelfHeading("\(visibleGames.count) Games")
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 340), spacing: 40)],
                          alignment: .leading,
                          spacing: 56) {
                    ForEach(visibleGames) { game in
                        tile(game)
                    }
                }
                .padding(.horizontal, 48)
            }
            .padding(.top, 24)
            .padding(.bottom, 60)
        }
        .scrollClipDisabled()
    }

    private func shelfHeading(_ title: String) -> some View {
        Text(title)
            .font(.headline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 48)
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

    /// A poster, with its title underneath. Only the art is the button, the
    /// way the TV's own apps do it: the focused poster lifts and tilts, and
    /// the titles stay on one line across the row instead of riding along.
    private func tile(_ game: TVStore.LocalGame) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            Button {
                onPlay(game)
            } label: {
                poster(game)
                    .aspectRatio(1, contentMode: .fit)
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

            VStack(alignment: .leading, spacing: 6) {
                Text(game.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                caption(for: game)
            }
            .padding(.horizontal, 6)
        }
    }

    private func poster(_ game: TVStore.LocalGame) -> some View {
        ZStack {
            TVGameArtwork(art: store.artwork[game.id],
                          system: coreCatalog.system(forIdentifier: game.systemIdentifier),
                          systemIdentifier: game.systemIdentifier)

            // Corners: what is not here yet on the left, a save state on the
            // right. A game that is here and ready carries no badge at all.
            VStack {
                HStack {
                    if !game.isDownloaded, store.progress(for: game.id) == nil {
                        cornerBadge(store.isSourceAvailable(for: game) ? "arrow.down" : "wifi.slash")
                    }
                    Spacer()
                    if store.hasLocalSaveState(for: game) {
                        cornerBadge("bookmark.fill")
                    }
                }
                Spacer()
                HStack {
                    if store.isFetchingArtwork(game.id) {
                        ProgressView()
                            .scaleEffect(0.6)
                            .padding(6)
                            .background(.black.opacity(0.5), in: .circle)
                    }
                    Spacer()
                }
            }
            .padding(14)

            if let progress = store.progress(for: game.id) {
                ZStack {
                    Color.black.opacity(0.6)
                    VStack(spacing: 12) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.white)
                            .frame(width: 170)
                        Text("\(Int(progress * 100))%")
                            .font(.headline.monospacedDigit())
                    }
                }
            }
        }
    }

    private func cornerBadge(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(.black.opacity(0.55), in: .circle)
    }

    /// The system, and a word on the game's state only when it needs one.
    private func caption(for game: TVStore.LocalGame) -> some View {
        HStack(spacing: 6) {
            if game.favorite {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
            }
            Text(game.systemName)
            if let note = note(for: game) {
                Text("·")
                Text(note.text)
                    .foregroundStyle(note.tint)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func note(for game: TVStore.LocalGame) -> (text: String, tint: Color)? {
        if !store.hasCore(for: game) {
            return ("No core on this TV", .orange)
        }
        if let progress = store.progress(for: game.id) {
            return ("Downloading \(Int(progress * 100))%", .blue)
        }
        if game.isDownloaded {
            return nil
        }
        if store.isSourceAvailable(for: game) {
            return ("Not downloaded", .secondary)
        }
        return ("\(game.sourceName ?? "Source") is away", .secondary)
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
