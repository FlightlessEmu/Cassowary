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

/// A request to pick a core before playing. The phone asks the same way when
/// a system has more than one installed core and no default.
private struct TVCorePickerRequest: Identifiable {
    let id = UUID()
    let game: TVStore.LocalGame
    let system: SystemEntry
}

/// The Apple TV app's root: the library, the sources, and settings, with the
/// game on top when one is running.
///
/// The tabs are the platform's own navigation on purpose. A hand-rolled header
/// of buttons looked right but the focus engine could not always reach it,
/// and on a TV reachable is the whole game. The tab bar is always one swipe
/// up from anywhere.
struct TVHomeView: View {

    @ObservedObject private var store = TVStore.shared
    @StateObject private var coreCatalog = CoreCatalog()

    @State private var playing: TVStore.LocalGame?
    @State private var playingCore: OECorePlugin?
    @State private var pickerRequest: TVCorePickerRequest?

    /// A game picked before the source was reachable, waiting for the link.
    @State private var waitingToPlay: TVStore.LocalGame?

    /// The automatic start has already happened, so it will not happen again.
    ///
    /// Kept in memory rather than in UserDefaults on purpose. The flag arrives
    /// as a launch argument, and a launch argument outranks anything written to
    /// UserDefaults — so clearing it there never stuck, and closing the game
    /// started the same game again straight away.
    @State private var didAutoPlay = false
    /// The game the test scripts' auto-play picked, while it is copied down.
    @State private var autoPlayTargetID: String?

    private enum Tab: String {
        case library, sources, settings
    }

    /// The open tab. Normal launches start on the library.
    @State private var tab: Tab = Self.launchTab

    #if DEBUG
    /// The screenshot sample from `TVScreenshotHooks`, never a real conflict.
    @State private var sampleConflict: SaveConflict?
    @State private var didOpenScreenshotScreen = false
    #endif

    var body: some View {
        ZStack {
            if let playing, let url = store.playableURL(for: playing) {
                TVPlayerView(game: playing,
                             url: url,
                             core: playingCore,
                             onFinished: { store.finishPlaying(playing) }) {
                    self.playing = nil
                    self.playingCore = nil
                }
            } else {
                TabView(selection: $tab) {
                    TVLibraryView { game in
                        play(game)
                    }
                    .tabItem {
                        Label("Library", systemImage: "square.grid.2x2")
                    }
                    .tag(Tab.library)

                    TVSourcesView()
                        .tabItem {
                            Label("Sources", systemImage: "rectangle.2.swap")
                        }
                        .tag(Tab.sources)

                    TVSettingsView()
                        .tabItem {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .tag(Tab.settings)
                }
            }
        }
        .sheet(item: $pickerRequest) { request in
            TVCorePickerView(catalog: coreCatalog, game: request.game, system: request.system) { plugin in
                pickerRequest = nil
                #if DEBUG
                // The screenshot stand-in has no file to play.
                if request.game.id == Self.standInGameID { return }
                #endif
                launch(request.game, core: plugin)
            }
        }
        #if DEBUG
        .sheet(item: $sampleConflict) { conflict in
            TVConflictView(conflict: conflict) { _ in }
        }
        #endif
        .onAppear {
            store.start()
            coreCatalog.refresh()
            autoPlayIfAsked()
        }
        #if DEBUG
        .task {
            // A sheet asked for during the first layout pass is dropped, so
            // give the window a moment before presenting one.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            openScreenshotScreenIfAsked()
        }
        #endif
        .onChange(of: playing?.id) { _, id in
            // No game in front means the controller is tvOS's again. While a
            // game is running it is the game's, until its own controls come up.
            ControllerCapture.setInterfaceActive(id == nil)
        }
        .onChange(of: store.games) { _, _ in
            autoPlayIfAsked()
        }
        .onChange(of: store.libraryIsLoading) { _, _ in
            // A reload can leave the games as they were, so the change above
            // does not fire; auto-play waits for the reload to end.
            autoPlayIfAsked()
        }
        .onChange(of: store.connectedHosts) { _, _ in
            // A game picked while its source was away starts as soon as one
            // that has it is back, so a tap is never wasted.
            if let waiting = waitingToPlay, store.isSourceAvailable(for: waiting) {
                waitingToPlay = nil
                play(waiting)
            }
            autoPlayIfAsked()
        }
    }

    private static var launchTab: Tab {
        #if DEBUG
        if TVScreenshotHooks.systemToOpen != nil || TVScreenshotHooks.bindingsToOpen != nil { return .settings }
        if let name = TVScreenshotHooks.tab, let tab = Tab(rawValue: name) { return tab }
        #endif
        return .library
    }

    #if DEBUG
    private static let standInGameID = "screenshot-stand-in"

    /// Opens the screen a `TVScreenshotHooks` flag asks for. The system
    /// settings flag is handled by the Settings tab itself.
    private func openScreenshotScreenIfAsked() {
        guard !didOpenScreenshotScreen else { return }
        didOpenScreenshotScreen = true

        if let id = TVScreenshotHooks.corePickerSystem, let system = coreCatalog.system(forIdentifier: id) {
            let game = store.games.first { $0.systemIdentifier == id }
                ?? TVStore.LocalGame(id: Self.standInGameID, title: "Sample Game", fileName: "",
                                     systemIdentifier: id, systemName: system.name, size: 0,
                                     hasArtwork: false, playCount: 0, favorite: false)
            pickerRequest = TVCorePickerRequest(game: game, system: system)
        }

        if TVScreenshotHooks.showsSampleConflict {
            let now = Date()
            let gameID = store.games.first?.id ?? Self.standInGameID
            let kind = SaveKind.stateSlot(1)
            let local = TransferProtocol.SaveBlobMeta(gameID: gameID, kind: kind, version: 2,
                                                      deviceID: "sample-tv", hash: "sample-local",
                                                      size: 65536, modifiedAt: now)
            var remote = local
            remote.deviceID = "sample-phone"
            remote.hash = "sample-remote"
            remote.modifiedAt = now.addingTimeInterval(-3600)
            sampleConflict = SaveConflict(gameID: gameID, kind: kind, local: local, remote: remote,
                                          heldFile: "", detectedAt: now)
        }

        if TVScreenshotHooks.opensVideo,
           let game = store.games.first(where: { $0.isDownloaded && store.hasCore(for: $0) }) {
            launch(game, core: coreCatalog.preferredCore(forSystemIdentifier: game.systemIdentifier)?.plugin)
        }
    }
    #endif

    /// Play a game, asking which core when there is a real choice. The same
    /// rule as the phone's library: one core or a remembered default launches
    /// straight away, several cores without a default ask first.
    private func play(_ game: TVStore.LocalGame) {
        guard let system = coreCatalog.system(forIdentifier: game.systemIdentifier) else {
            // Unknown system: let the session resolve it and report the error.
            launch(game, core: nil)
            return
        }
        if system.cores.isEmpty {
            store.note("No core for \(system.name) is on this Apple TV yet.")
            return
        }
        if system.cores.count == 1 {
            launch(game, core: system.cores[0].plugin)
        } else if let id = coreCatalog.defaultCoreID(forSystemIdentifier: system.id),
                  let core = system.cores.first(where: { $0.id == id }) {
            launch(game, core: core.plugin)
        } else {
            pickerRequest = TVCorePickerRequest(game: game, system: system)
        }
    }

    private func launch(_ game: TVStore.LocalGame, core: OECorePlugin?) {
        if game.isDownloaded {
            store.prepareForPlay(game)
            playing = game
            playingCore = core
        } else if store.isSourceAvailable(for: game) {
            // Copy it down and stay in the library. Picking several games in
            // a row is a normal thing to do, and starting the first one would
            // get in the way; a second tap plays it once it is here.
            Task {
                await store.download(game)
            }
        } else {
            // The source is away. Hold the request rather than dropping it:
            // the game is copied down by itself once the phone is back.
            NSLog("[Cassowary] holding %@ until a source is back", game.title)
            waitingToPlay = game
            store.note("\(game.title) will be copied down as soon as a source is back.")
        }
    }

    /// The test scripts ask for the first shared game without tapping. The
    /// library may already be loaded when this view appears, so both the
    /// on-appear and the on-change paths call this. In normal use the flag is
    /// not set.
    ///
    /// Only a game from a source counts: the bundled demo is in the library
    /// from the first launch, and playing it would skip the copy-down the
    /// scripts are there to check. Until the source's games arrive there is
    /// nothing to pick, and the next library change asks again.
    private func autoPlayIfAsked() {
        guard !didAutoPlay,
              UserDefaults.standard.bool(forKey: "cassowary.autoPlayFirstGame"),
              playing == nil else { return }

        // Picking a game that is not here yet copies it down and stays in the
        // library, the way a first tap does. So pick once, then play it on
        // the library change that shows the copy has finished.
        guard let targetID = autoPlayTargetID else {
            // Only once the source has answered: until then the library is
            // the one saved last time, which can list games the source has
            // since dropped. The connection change asks again.
            guard store.connection.isConnected, !store.libraryIsLoading else { return }
            // A game still to copy down comes first: that is the path the
            // scripts check, and a shared simulator may already hold others.
            // Only games the connected source lists now: copies kept from
            // other sources, or of games this one has dropped, have nowhere
            // to sync their saves, and the scripts check that saves arrive.
            let sourced = store.games.filter {
                $0.sourceDeviceID != nil && store.isSourceAvailable(for: $0)
            }
            guard let first = sourced.first(where: { !$0.isDownloaded }) ?? sourced.first else { return }
            NSLog("[Cassowary] auto-play picked %@ (%@)", first.title, first.isDownloaded ? "here" : "to copy down")
            autoPlayTargetID = first.id
            didAutoPlay = first.isDownloaded
            play(first)
            return
        }
        guard let target = store.games.first(where: { $0.id == targetID }), target.isDownloaded else { return }
        didAutoPlay = true
        play(target)
    }
}
