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
import OpenEmuKit

/// Which games the library shows.
private enum LibrarySelection: Hashable {
    case all
    case system(String)
}

/// A game being played, with the core it launched with.
private struct ActiveGame: Identifiable {
    let id = UUID()
    let game: Game
    let core: OECorePlugin?
}

/// A request to pick a core before playing.
private struct CorePickerRequest: Identifiable {
    let id = UUID()
    let game: Game
    let system: SystemEntry
}

private enum SortOption: String, CaseIterable, Identifiable {
    case title
    case system

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: return "Title"
        case .system: return "System"
        }
    }
}

/// The library: everything the app can play.
///
/// A split view so it feels native in both idioms: a sidebar of systems on
/// iPad and Catalyst, collapsing to a navigation stack on iPhone. Tapping a
/// game plays it with the system's default core; long-pressing offers
/// Play With… when more than one core is installed.
struct LibraryView: View {

    @StateObject private var library = GameLibrary()
    @StateObject private var catalog = CoreCatalog()

    @State private var selection: LibrarySelection? = .all
    @State private var path = NavigationPath()
    @State private var searchText = ""
    @State private var sort: SortOption = .title
    @State private var playing: ActiveGame?
    @State private var pickerRequest: CorePickerRequest?
    @State private var showSettings = false

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .compact {
                // iPhone: an explicit stack with links, so every tap pushes.
                // A collapsed split view drives pushes off selection state,
                // which means tapping the already-selected row is a no-op
                // and the library appears to not open.
                NavigationStack {
                    compactSidebar
                        .navigationDestination(for: LibrarySelection.self) { target in
                            detail(for: target)
                                .onAppear { selection = target }
                        }
                }
            } else {
                NavigationSplitView {
                    sidebar
                } detail: {
                    detail(for: selection ?? .all)
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .fullScreenCover(item: $playing) { active in
            GameView(game: active.game, core: active.core) {
                playing = nil
            }
        }
        .sheet(item: $pickerRequest) { request in
            CorePickerSheet(catalog: catalog, game: request.game, system: request.system) { plugin in
                pickerRequest = nil
                playing = ActiveGame(game: request.game, core: plugin)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onAppear {
            refreshAll()

            // Used by Scripts/cassowary/test-cassowary.sh to boot a game without tapping.
            // Harmless in normal use: the flag is only set when passed on the
            // command line.
            if UserDefaults.standard.bool(forKey: "cassowary.autoPlayFirstGame"),
               playing == nil,
               let first = library.games.first {
                play(first)
            }

            // Opens Settings without tapping, for screenshots and UI checks.
            // Same deal: only set from the command line.
            if UserDefaults.standard.bool(forKey: "cassowary.showSettings") {
                showSettings = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshLibrary)) { _ in
            refreshAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in
            showSettings = true
        }
    }

    // MARK: - Sidebar

    /// iPhone sidebar: links that push the detail every time they are tapped.
    private var compactSidebar: some View {
        List {
            NavigationLink(value: LibrarySelection.all) {
                Label {
                    Text("All Games")
                } icon: {
                    Image(systemName: "gamecontroller.fill")
                }
                .badge(library.games.count)
            }

            Section("Systems") {
                ForEach(catalog.systems) { system in
                    NavigationLink(value: LibrarySelection.system(system.id)) {
                        Label {
                            Text(system.name)
                        } icon: {
                            if let icon = system.icon {
                                Image(uiImage: icon)
                            } else {
                                Image(systemName: "gamecontroller")
                            }
                        }
                        .badge(gameCount(for: system.id))
                    }
                }
            }

            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cores")
                        Text(coreStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "cpu")
                }
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gear")
                }
            }
        }
    }

    /// iPad and Catalyst sidebar.
    ///
    /// Each row is a value-based `NavigationLink` rather than a plain `Label`
    /// with a `.tag`. On the Mac (Catalyst) a tagged row in this list never
    /// becomes selected when clicked, so tapping a system left the detail pane
    /// stuck on All Games. A `NavigationLink` ties the tap to the list's
    /// selection, which then drives the detail.
    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                NavigationLink(value: LibrarySelection.all) {
                    Label {
                        Text("All Games")
                    } icon: {
                        Image(systemName: "gamecontroller.fill")
                    }
                }
                .badge(library.games.count)
            }

            Section("Systems") {
                ForEach(catalog.systems) { system in
                    NavigationLink(value: LibrarySelection.system(system.id)) {
                        Label {
                            Text(system.name)
                        } icon: {
                            if let icon = system.icon {
                                Image(uiImage: icon)
                            } else {
                                Image(systemName: "gamecontroller")
                            }
                        }
                    }
                    .badge(gameCount(for: system.id))
                }
            }

            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cores")
                        Text(coreStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "cpu")
                }
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gear")
                }
            }
        }
    }

    // MARK: - Detail

    private var detail: some View {
        detail(for: selection ?? .all)
    }

    private func detail(for target: LibrarySelection) -> some View {
        Group {
            if visibleGames(for: target).isEmpty {
                emptyState(for: target)
            } else {
                grid(for: target)
            }
        }
        .navigationTitle(detailTitle(for: target))
        .searchable(text: $searchText, prompt: "Search games")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort by", selection: $sort) {
                        ForEach(SortOption.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    refreshAll()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }

    private func grid(for target: LibrarySelection) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: columnWidth, maximum: 220), spacing: 20)], spacing: 20) {
                ForEach(visibleGames(for: target)) { game in
                    Button {
                        play(game)
                    } label: {
                        GameTile(game: game, system: catalog.system(forIdentifier: game.system?.identifier ?? ""))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Play") { play(game) }
                        if let system = catalog.system(forIdentifier: game.system?.identifier ?? ""),
                           system.cores.count > 1 {
                            Menu("Play With") {
                                ForEach(system.cores) { core in
                                    Button(core.displayName) {
                                        play(game, core: core.plugin)
                                    }
                                }
                            }
                        }
                        Button("Delete", role: .destructive) {
                            library.delete(game)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    /// Wider tiles on regular width (iPad, Catalyst), compact on iPhone.
    private var columnWidth: CGFloat {
        sizeClass == .compact ? 140 : 160
    }

    private func emptyState(for target: LibrarySelection) -> some View {
        ContentUnavailableView {
            switch target {
            case .system(let id) where catalog.system(forIdentifier: id) != nil:
                Label(catalog.system(forIdentifier: id)?.name ?? "Games", systemImage: "gamecontroller")
            case .system:
                Label("No Systems", systemImage: "exclamationmark.triangle")
            default:
                Label("No Games", systemImage: "gamecontroller")
            }
        } description: {
            if catalog.systems.isEmpty {
                Text("No system plugins were found. Reinstall the app to restore them.")
            } else if case .system(let id) = target,
                      let system = catalog.system(forIdentifier: id),
                      !system.hasCore {
                Text("There is no core installed for \(system.name) yet, so these games cannot be played.")
            } else {
                Text("Copy ROM files into Cassowary using the Files app or Finder, then tap Refresh.")
            }
        } actions: {
            if !isSystemWithoutCore(target) {
                Button("Refresh") { refreshAll() }
            }
        }
    }

    private func isSystemWithoutCore(_ selection: LibrarySelection) -> Bool {
        if case .system(let id) = selection,
           let system = catalog.system(forIdentifier: id) {
            return !system.hasCore
        }
        return false
    }

    // MARK: - Data

    private func refreshAll() {
        library.refresh()
        catalog.refresh()
    }

    private func gameCount(for systemID: String) -> Int {
        library.games.filter { $0.system?.identifier == systemID }.count
    }

    private func detailTitle(for target: LibrarySelection) -> String {
        switch target {
        case .system(let id):
            return catalog.system(forIdentifier: id)?.name ?? "Games"
        default:
            return "Games"
        }
    }

    private var coreStatus: String {
        if catalog.systems.isEmpty {
            return "No systems found"
        }
        let missing = catalog.systems.filter { !$0.hasCore }.count
        if missing == 0 {
            return "\(catalog.coreCount) cores · \(catalog.systems.count) systems"
        }
        return "\(missing) system\(missing == 1 ? "" : "s") without a core"
    }

    private func visibleGames(for target: LibrarySelection) -> [Game] {
        var games = library.games

        switch target {
        case .system(let id):
            games = games.filter { $0.system?.identifier == id }
        default:
            break
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
                let lhs = $0.systemName ?? ""
                let rhs = $1.systemName ?? ""
                if lhs != rhs {
                    return lhs.localizedStandardCompare(rhs) == .orderedAscending
                }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }

        return games
    }

    // MARK: - Launch

    /// Play a game, asking which core when there is a real choice.
    private func play(_ game: Game, core: OECorePlugin? = nil) {
        if let core {
            playing = ActiveGame(game: game, core: core)
            return
        }
        guard let systemID = game.system?.identifier,
              let system = catalog.system(forIdentifier: systemID) else {
            // Unknown system: let the session resolve it and report the error.
            playing = ActiveGame(game: game, core: nil)
            return
        }
        if system.cores.isEmpty {
            // No core: the session throws missingCorePlugin and GameView
            // shows it, which is clearer than silence here.
            playing = ActiveGame(game: game, core: nil)
        } else if system.cores.count == 1 {
            playing = ActiveGame(game: game, core: system.cores[0].plugin)
        } else if let id = catalog.defaultCoreID(forSystemIdentifier: system.id),
                  let core = system.cores.first(where: { $0.id == id }) {
            playing = ActiveGame(game: game, core: core.plugin)
        } else {
            pickerRequest = CorePickerRequest(game: game, system: system)
        }
    }
}

/// One game in the library grid.
private struct GameTile: View {

    let game: Game
    let system: SystemEntry?

    /// Whether a save state sits next to the ROM.
    private var hasSaveState: Bool {
        let url = game.url.deletingPathExtension().appendingPathExtension("oesavestate")
        return FileManager.default.fileExists(atPath: url.path)
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.quaternary)

                if let icon = system?.icon {
                    Image(uiImage: icon)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                } else if let icon = game.system?.icon {
                    Image(uiImage: icon)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                } else {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                }

                if hasSaveState {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "bookmark.fill")
                                .font(.caption)
                                .foregroundStyle(.white)
                                .padding(7)
                                .background(.black.opacity(0.45), in: .circle)
                        }
                        Spacer()
                    }
                    .padding(8)
                }
            }
            .aspectRatio(1, contentMode: .fit)

            VStack(spacing: 2) {
                Text(game.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)

                if let system {
                    Text(system.hasCore ? system.name : "\(system.name) · No core")
                        .font(.caption)
                        .foregroundStyle(system.hasCore ? Color.secondary : Color.orange)
                } else if let systemName = game.systemName {
                    Text(systemName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityLabel("\(game.title), \(system?.name ?? game.systemName ?? "unknown system")")
    }
}
