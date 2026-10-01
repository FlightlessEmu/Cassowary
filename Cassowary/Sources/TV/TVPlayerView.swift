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
import Metal
import OpenEmuBase
import OpenEmuSystem
import OpenEmuKit
#if canImport(MetalFX)
import MetalFX
#endif

/// Plays one game on the Apple TV.
///
/// The picture comes from the same Metal layer host the phone uses. The
/// difference is input: there is no touch pad on a TV, so a game controller
/// reaches the emulator through the engine's GameController bridge, which
/// `GameSession` starts when the game does.
struct TVPlayerView: View {

    let game: TVStore.LocalGame
    let url: URL
    /// The picked core, when the library resolved one. Nil means the session
    /// falls back to the first installed core for the game's system.
    let core: OECorePlugin?
    /// Called once the game has stopped, before the view goes away, so the
    /// caller can file the save state and tell the phone about the session.
    var onFinished: (() -> Void)?

    let onClose: () -> Void

    @State private var session: GameSession?
    @StateObject private var controllerInput = TVControllerInput()
    @State private var buttonTap: Task<Void, Never>?
    @State private var tappedButton: String?
    @State private var menuButtonHorizontalPadding: CGFloat = 0
    @State private var leftActive = false
    @State private var errorMessage: String?
    @State private var notice: String?
    /// The game's menu is open. Back opens it and closes it again.
    @State private var isMenuOpen = false
    /// What the menu is showing instead of its buttons. Back returns to the
    /// buttons, so each list is one level, not a maze.
    @State private var showingFilters = false
    @State private var showingVideo = false
    @State private var showingStates = false
    /// The filled save-state slots, newest first, read when the list opens
    /// and again after each save.
    @State private var slots: [SaveSlotInfo] = []

    /// The installed filters and the remembered picks, shared with the
    /// phone: the same presets, the same per-system memory.
    @StateObject private var shaderCatalog = ShaderCatalog()
    /// The filter on the running game, if any.
    @State private var shaderName: String?

    /// The two upscaling switches, shared with the phone: the same app-wide
    /// defaults and per-system overrides.
    @StateObject private var upscalingOptions = UpscalingOptions()
    @AppStorage(RumbleHaptics.strengthKey) private var rumbleStrength = RumbleStrength.medium.rawValue

    /// Which of the menu's buttons is chosen.
    ///
    /// The menu opens with Resume selected, so there is a highlight to see and
    /// something for the remote to act on from the first press.
    @FocusState private var menuFocus: MenuFocus?

    /// Which filter row is chosen. None is a row of its own, so it needs a
    /// case instead of sharing the optional's absence with "nothing".
    @FocusState private var filterFocus: FilterFocus?

    /// Which video row is chosen.
    @FocusState private var videoFocus: VideoFocus?

    /// Which button in the save-state list is chosen.
    @FocusState private var stateFocus: StateFocus?

    private enum MenuFocus: Hashable {
        case resume, start, select, saveState, states, reset, filter, video, close
    }

    private enum FilterFocus: Hashable {
        case none
        case shader(String)
    }

    /// A slot's Load, Save Here or Delete button, by slot kind.
    private enum StateFocus: Hashable {
        case load(String)
        case save(String)
        case delete(String)
    }

    private enum VideoFocus: Hashable {
        case metalFX(UpscalingOptions.Choice)
        case scaling(UpscalingOptions.Choice)
        case rumble(RumbleStrength)
    }

    /// A line telling the player how to reach the menu, shown once at the
    /// start and then out of the way. Nothing to focus, so it cannot get in
    /// the way of the game either.
    @State private var showsHint = true
    @State private var hideHint: Task<Void, Never>?
    /// `close` has been asked for. The save, its timeout, and the test hook
    /// below all go through it, and only the first one counts.
    @State private var didClose = false
    /// The close callbacks have fired.
    @State private var finishedClosing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let session, let layer = session.videoLayer {
                GameLayerView(
                    layer: layer,
                    bufferSize: {
                        let size = session.videoBufferSize
                        return CGSize(width: CGFloat(size.width), height: CGFloat(size.height))
                    },
                    aspectRatio: { session.displayAspectRatio },
                    // No touch screen on a TV: the remote and a controller
                    // reach the emulator through the engine's bridge.
                    onTouch: { _ in },
                    onResize: { bounds in
                        session.updateDisplayBounds(bounds)
                    }
                )
                .ignoresSafeArea()
            }

            if let errorMessage {
                errorState(errorMessage)
            }
        }
        // The game area holds focus while the menu is closed, which is what
        // lets Back be seen at all: an exit command only reaches a view in the
        // focus chain. No focus effect, so the picture does not glow at the
        // edges just because it can be focused.
        //
        // Both are applied *before* the menu is overlaid on purpose. They set
        // environment values, so putting them on the outside would reach into
        // the menu as well and take away its focus highlight — leaving a menu
        // that can be opened but gives no sign of what is about to be chosen.
        .focusable(!isMenuOpen)
        .focusEffectDisabled()
        .overlay { if isMenuOpen { gameMenu } }
        .overlay(alignment: .bottom) { hintBanner }
        .overlay {
            if let session, !isMenuOpen {
                TVAchievementOverlay(state: session.raState)
            }
        }
        .overlay(alignment: .bottom) { noticeBanner }
        .task { startGame() }
        // UIKit hosts this view, so its notifications tell us when the app leaves.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            saveBeforeLeaving()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            guard leftActive else { return }
            leftActive = false
            openMenu()
        }
        .onDisappear {
            hideHint?.cancel()
            stopGame()
        }
        .onExitCommand {
            guard !controllerInput.shouldIgnoreExit else { return }
            // Back walks one level at a time: out of the filter or video list
            // to the menu, out of the menu to the game. Closing the game stays
            // a button on the menu, so a stray press can never throw a
            // session away — which is what made the old control row dangerous.
            if showingFilters {
                closeFilters()
            } else if showingStates {
                closeStates()
            } else if showingVideo {
                closeVideo()
            } else if isMenuOpen {
                closeMenu()
            } else {
                requestMenu()
            }
        }
    }

    // MARK: - The game's menu

    /// The game's menu, over the picture. The game is paused while it is up
    /// and the controller belongs to tvOS, so its buttons can be chosen —
    /// which is the whole reason it is a menu and not a row of buttons over
    /// the picture.
    private var gameMenu: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()

            // One panel over the picture, whatever it shows: the buttons, or
            // the filter, video or save-state list in their place.
            VStack(spacing: 30) {
                VStack(spacing: 6) {
                    Text(game.title)
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                    if !game.systemName.isEmpty {
                        Text(game.systemName)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if showingFilters {
                    filterList
                } else if showingStates {
                    stateList
                } else if showingVideo {
                    videoList
                } else {
                    menuButtons
                }
            }
            .padding(.horizontal, 56)
            .padding(.vertical, 48)
            .background(.regularMaterial, in: .rect(cornerRadius: 44, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
        }
        .defaultFocus($menuFocus, .resume)
    }

    /// The menu's buttons, one above the other. A column fits the remote's
    /// up and down; Start and Select appear only when the system has them.
    private var menuButtons: some View {
        VStack(spacing: 14) {
            menuButton("Resume", systemImage: "play.fill") { closeMenu() }
                .focused($menuFocus, equals: .resume)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    max(0, geometry.size.width - 520)
                } action: { menuButtonHorizontalPadding = $0 }

            if menuButtonID(containing: "Start") != nil || menuButtonID(containing: "Select") != nil {
                // Account for each button's tvOS padding so this row matches Resume.
                HStack(spacing: 14) {
                    if let button = menuButtonID(containing: "Start") {
                        menuButton("Press Start", systemImage: nil, width: (520 - menuButtonHorizontalPadding - 14) / 2) {
                            tapButton(named: button)
                        }
                        .focused($menuFocus, equals: .start)
                    }
                    if let button = menuButtonID(containing: "Select") {
                        menuButton("Press Select", systemImage: nil, width: (520 - menuButtonHorizontalPadding - 14) / 2) {
                            tapButton(named: button)
                        }
                        .focused($menuFocus, equals: .select)
                    }
                }
                .frame(width: 520 + menuButtonHorizontalPadding, alignment: .leading)
            }

            if let session {
                // Hardcore turns save states off. The TV has no sign-in
                // screen, so this only matters if it ever gains one.
                if !session.raHardcoreActive {
                    menuButton("Save State", systemImage: "square.and.arrow.down") {
                        session.saveState { result in
                            report(result, success: "Saved")
                        }
                    }
                    .focused($menuFocus, equals: .saveState)

                    menuButton("Save States…", systemImage: "square.stack") {
                        openStates()
                    }
                    .focused($menuFocus, equals: .states)
                }

                menuButton("Reset", systemImage: "arrow.counterclockwise") {
                    session.resetEmulation()
                    show(notice: "Reset")
                }
                .focused($menuFocus, equals: .reset)

                menuButton("Filter", detail: shaderName ?? "None", systemImage: "camera.filters") {
                    openFilters()
                }
                .focused($menuFocus, equals: .filter)

                menuButton("Video…", systemImage: "tv") {
                    openVideo()
                }
                .focused($menuFocus, equals: .video)
            }

            menuButton("Close Game", systemImage: "xmark", tint: .red) { close() }
                .focused($menuFocus, equals: .close)
        }
    }

    private func menuButton(_ title: String,
                            detail: String? = nil,
                            systemImage: String?,
                            tint: Color? = nil,
                            width: CGFloat = 520,
                            action: @escaping () -> Void) -> some View {
        // Red text rather than a destructive role: tvOS fills a destructive
        // button red and draws its title red too, which cannot be read.
        Button(action: action) {
            HStack(spacing: 18) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 26, weight: .semibold))
                        .frame(width: 36)
                }
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 20)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(tint ?? .primary)
            .frame(width: width, alignment: .leading)
            .padding(.vertical, 6)
        }
    }

    /// The filter list, in place of the buttons. The current filter carries
    /// a checkmark and starts selected, so the remote acts on something
    /// from the first press — the same rule as the menu itself.
    private var filterList: some View {
        VStack(spacing: 24) {
            Text("Video Filter")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)

            ScrollView(.vertical) {
                // A plain stack, not a lazy one, on purpose: the current
                // filter starts selected, and a lazy row that does not exist
                // yet cannot take focus — the request would silently drop
                // and the remote would act on nothing.
                VStack(spacing: 12) {
                    filterRow(name: nil)
                    ForEach(shaderCatalog.names, id: \.self) { name in
                        filterRow(name: name)
                    }
                }
                .padding(.horizontal, 40)
            }
            .frame(maxHeight: 560)
        }
    }

    private func filterRow(name: String?) -> some View {
        let focus: FilterFocus = name.map(FilterFocus.shader) ?? .none
        return Button {
            applyFilter(named: name)
        } label: {
            HStack {
                Text(name ?? "None")
                    .font(.headline)
                Spacer()
                if shaderName == name {
                    Image(systemName: "checkmark")
                }
            }
            .frame(width: 560)
            .padding(.vertical, 14)
            .padding(.horizontal, 24)
        }
        .focused($filterFocus, equals: focus)
    }

    /// Every save-state slot, in place of the buttons: the same slots as the
    /// phone's Save States sheet. A filled slot can be loaded or deleted; any
    /// slot but the autosave can be saved over.
    private var stateList: some View {
        VStack(spacing: 24) {
            Text("Save States")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)

            ScrollView(.vertical) {
                // A plain stack for the same reason as the filter list: the
                // first button starts selected and has to exist to take focus.
                VStack(spacing: 16) {
                    ForEach(SaveKind.allStateKinds, id: \.self) { kind in
                        stateRow(kind: kind, slot: slots.first(where: { $0.kind == kind }))
                    }
                }
                .padding(.horizontal, 40)
            }
            .frame(maxHeight: 560)
        }
    }

    private func stateRow(kind: String, slot: SaveSlotInfo?) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(SaveKind.displayName(for: kind))
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(slotDetail(kind: kind, slot: slot))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(width: 440, alignment: .leading)

            // Fixed columns, so every Save Here lines up whether or not the
            // slot beside it has something to load.
            Group {
                if slot != nil {
                    Button("Load") { loadSlot(kind) }
                        .focused($stateFocus, equals: .load(kind))
                } else {
                    Color.clear
                }
            }
            .frame(width: 190)
            Group {
                if kind != SaveKind.autosave {
                    Button("Save Here") { saveSlot(kind) }
                        .focused($stateFocus, equals: .save(kind))
                } else {
                    Color.clear
                }
            }
            .frame(width: 250)
            Group {
                if slot != nil {
                    // Red text, not a destructive role: tvOS draws that red on red.
                    Button { deleteSlot(kind) } label: {
                        Text("Delete").foregroundStyle(.red)
                    }
                    .focused($stateFocus, equals: .delete(kind))
                } else {
                    Color.clear
                }
            }
            .frame(width: 190)
        }
        .frame(width: 1110, height: 96, alignment: .leading)
    }

    private func slotDetail(kind: String, slot: SaveSlotInfo?) -> String {
        guard let slot else {
            return kind == SaveKind.autosave ? "Written when the game closes" : "Empty"
        }
        let when = slot.modifiedAt.formatted(date: .abbreviated, time: .shortened)
        guard let device = slot.deviceID, device != DeviceIdentity.current.id else { return when }
        return "\(when) · another device"
    }

    /// Loads a slot and goes straight back to the game, which is what a load
    /// is for. A failure stays on the list so another slot can be tried.
    private func loadSlot(_ kind: String) {
        guard let session else { return }
        session.loadState(from: kind) { result in
            report(result, success: "Loaded \(SaveKind.displayName(for: kind))")
            if case .success = result {
                closeMenu()
            }
        }
    }

    /// Deletes a slot on this TV and, at the next sync, on the phone.
    private func deleteSlot(_ kind: String) {
        TVStore.shared.deleteState(game, kind: kind)
        slots = session?.filledSlots ?? []
        show(notice: "Deleted \(SaveKind.displayName(for: kind))")
        // The Delete button just went away with the slot; land on its Save Here.
        Task { @MainActor in
            stateFocus = kind == SaveKind.autosave ? slots.first.map { .load($0.kind) } : .save(kind)
        }
    }

    private func saveSlot(_ kind: String) {
        guard let session else { return }
        session.saveState(in: kind) { result in
            report(result, success: "Saved to \(SaveKind.displayName(for: kind))")
            slots = session.filledSlots
        }
    }

    /// Upscaling and rumble, in place of the buttons. The same app-wide
    /// defaults and per-system overrides as the phone: "Use Default" follows
    /// what Settings says, and a pick here is remembered for this system.
    private var videoList: some View {
        VStack(spacing: 24) {
            Text("Video")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)

            ScrollView(.vertical) {
                VStack(spacing: 12) {
                    videoSectionLabel("Upscaling: \(upscalingSummary(.metalFX))")
                    ForEach(upscalingChoices, id: \.self) { choice in
                        videoRow(title: metalFXTitle(choice),
                                 selected: metalFXChoice == choice) {
                            applyMetalFXUpscaling(choice)
                        }
                        .focused($videoFocus, equals: .metalFX(choice))
                    }

                    videoSectionLabel("Scaling: \(upscalingSummary(.integerScaling))")
                    ForEach(upscalingChoices, id: \.self) { choice in
                        videoRow(title: scalingTitle(choice),
                                 selected: scalingChoice == choice) {
                            applyIntegerScaling(choice)
                        }
                        .focused($videoFocus, equals: .scaling(choice))
                    }

                    videoSectionLabel("Rumble: \(rumbleTitle)")
                    ForEach(RumbleStrength.allCases) { strength in
                        videoRow(title: strength.title,
                                 selected: rumbleStrength == strength.rawValue) {
                            rumbleStrength = strength.rawValue
                            show(notice: "Rumble \(strength.title.lowercased())")
                        }
                        .focused($videoFocus, equals: .rumble(strength))
                    }
                }
                .padding(.horizontal, 40)
            }
            .frame(maxHeight: 560)
        }
    }

    private func videoSectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 560, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 12)
    }

    private var upscalingChoices: [UpscalingOptions.Choice] {
        [.automatic, .off, .on]
    }

    private func videoRow(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                }
            }
            .frame(width: 560)
            .padding(.vertical, 14)
            .padding(.horizontal, 24)
        }
    }

    /// Tells the player how to reach the menu, then gets out of the way.
    private var hintBanner: some View {
        Group {
            if showsHint, !isMenuOpen, errorMessage == nil {
                Text(controllerInput.hasGamepad
                     ? "Hold Menu or press Back on the remote for options"
                     : "Click to press A · Play/Pause is B · Back for the menu")
                    .font(.callout)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: .capsule)
                    .padding(.bottom, 44)
                    .transition(.opacity)
            }
        }
    }

    private var noticeBanner: some View {
        Group {
            if let notice {
                Text(notice)
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: .capsule)
                    .padding(.bottom, 40)
            }
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.yellow)

            Text("Could Not Start")
                .font(.title2.weight(.semibold))

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)

            Button("Close", action: close)
        }
        .padding(60)
    }

    // MARK: - Running

    private func startGame() {
        guard session == nil else { return }

        do {
            // The library resolved the system and core when the game was
            // picked; the extension guess is only the fallback for games
            // added before systems were tracked.
            let systemID = game.systemIdentifier.isEmpty ? nil : game.systemIdentifier
            let session = try GameSession(romURL: url, core: core, systemIdentifier: systemID)

            if let plugin = OESystemPlugin.allPlugins.first(where: { $0.systemIdentifier == session.systemIdentifier })
                ?? TVDemoLibrary.systemPlugin(forExtension: url.pathExtension) {
                session.layout = ControllerLayout(systemPlugin: plugin)
            }

            self.session = session
            session.start {
                // Pick up where the game was left, on either device. The menu
                // can still load any slot by hand. Hardcore refuses to load
                // states, so it starts fresh.
                if !session.raHardcoreActive, let newest = session.filledSlots.first {
                    session.loadState(from: newest.kind) { result in
                        switch result {
                        case .success:
                            self.show(notice: "Resumed \(newest.displayName)")
                        case .failure(let error):
                            self.show(notice: error.localizedDescription)
                        }
                    }
                }
            }
            controllerInput.start(session: session) { requestMenu() }
            // The filter and upscaling switches remembered for this system.
            // Shared with the phone player: see `VideoSettings`.
            shaderName = shaderCatalog.resolvedShaderName(forSystem: systemID)
            VideoSettings.applySaved(to: session,
                                     systemIdentifier: systemID,
                                     shaderCatalog: shaderCatalog,
                                     upscaling: upscalingOptions)

            // A word about the menu, then out of the way. Nothing focusable,
            // so it cannot hold the game's controller.
            hideHint = Task {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.4)) { showsHint = false }
            }

            // Used by the run script to check the game's menu without a
            // remote: opens it a few seconds in. Only set from the command
            // line, so normal play never sees it.
            if UserDefaults.standard.bool(forKey: "cassowary.testOpenMenu") {
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    openMenu()
                }
            }

            // Used by the run script to check the filter list without a
            // remote: opens the menu, then the filters. Only set from the
            // command line, so normal play never sees it.
            if UserDefaults.standard.bool(forKey: "cassowary.testOpenFilters") {
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    openMenu()
                    try? await Task.sleep(for: .seconds(2))
                    openFilters()
                }
            }

            #if DEBUG
            if TVScreenshotHooks.opensVideo {
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    openMenu()
                    try? await Task.sleep(for: .seconds(2))
                    openVideo()
                }
            }
            #endif

            // Used to check the save-state list without a remote: saves into
            // Slot 1 so there is a filled slot to show, then opens the menu
            // and the list. Only set from the command line.
            // Used by test-sharing.sh to check a deletion reaches the phone:
            // saves into Slot 1, sends it, then deletes it. Only set from
            // the command line.
            if UserDefaults.standard.bool(forKey: "cassowary.testDeleteSlot") {
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    saveSlot(SaveKind.stateSlot(1))
                    try? await Task.sleep(for: .seconds(1))
                    TVStore.shared.fileSessionSaves(game)
                    await TVStore.shared.syncNow()
                    try? await Task.sleep(for: .seconds(2))
                    deleteSlot(SaveKind.stateSlot(1))
                }
            }

            if UserDefaults.standard.bool(forKey: "cassowary.testOpenStates") {
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    saveSlot(SaveKind.stateSlot(1))
                    try? await Task.sleep(for: .seconds(1))
                    openMenu()
                    try? await Task.sleep(for: .seconds(2))
                    openStates()
                }
            }

            // Used by the run script to prove input reaches the emulator with
            // no controller attached: hold the named buttons for a few seconds
            // once the game is running. It starts late and stops, so a test
            // can tell a moving picture from a frozen one. A comma-separated
            // list is allowed because the two test ROMs answer different
            // buttons (the demo steers with the d-pad, the input test flips
            // with A). Only set from the command line.
            if let buttons = UserDefaults.standard.string(forKey: "cassowary.testHoldButton") {
                let names = buttons.split(separator: ",").map(String.init)
                Task {
                    try? await Task.sleep(for: .seconds(6))
                    for name in names { session.pressButton(named: name) }
                    try? await Task.sleep(for: .seconds(3))
                    for name in names { session.releaseButton(named: name) }
                }
            }

            // Used by the run script to close the game after a while, so the
            // return-to-library path can be checked without a remote. Only
            // set from the command line.
            if let seconds = Self.testCloseDelay {
                Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    close()
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// `cassowary.testCloseAfter` as a number, from either a launch argument
    /// (a string) or a stored value.
    private static var testCloseDelay: Double? {
        let defaults = UserDefaults.standard
        if let number = defaults.object(forKey: "cassowary.testCloseAfter") as? Int {
            return Double(number)
        }
        if let text = defaults.string(forKey: "cassowary.testCloseAfter"), let value = Double(text) {
            return value
        }
        return nil
    }

    /// Stop the game.
    ///
    /// Like the phone's game view, the session is kept until the core has
    /// finished stopping, so nothing can start a second core on top of the one
    /// that is still winding down.
    private func stopGame() {
        controllerInput.stop()
        cancelButtonTap()
        guard let session else { return }
        session.stop {
            self.session = nil
        }
    }

    /// Opens the game's menu.
    ///
    /// The game pauses and the controller goes back to tvOS. Both are needed:
    /// with the game still holding the controller nothing on screen could be
    /// chosen, which is what made the old control row look selected but do
    /// nothing.
    /// The player asked for the menu, with Back or a gamepad's Menu. In
    /// hardcore RetroAchievements has a say first: pausing over and over is a
    /// way to slow a game down, so the server can refuse for a few seconds,
    /// the same rule the phone follows. Leaving the app always pauses.
    private func requestMenu() {
        guard let session, session.raHardcoreActive else {
            openMenu()
            return
        }
        session.canPauseHardcore { allowed, secondsToWait in
            Task { @MainActor in
                if allowed {
                    openMenu()
                } else if secondsToWait > 0 {
                    show(notice: "Hardcore mode allows pausing again in \(secondsToWait) s")
                } else {
                    show(notice: "RetroAchievements is not allowing a pause right now")
                }
            }
        }
    }

    private func openMenu() {
        guard !isMenuOpen, !didClose, session != nil else { return }
        controllerInput.menuDidOpen()
        cancelButtonTap()
        hideHint?.cancel()
        showsHint = false
        session?.setPaused(true)

        // The menu goes up first, then the controller is handed back. The
        // hand-back is what asks tvOS for a focus update, and asking before
        // the buttons exist leaves focus where it was — on the game area that
        // has just stopped being focusable — so nothing can be walked.
        withAnimation(.easeInOut(duration: 0.2)) { isMenuOpen = true }
        ControllerCapture.setInterfaceActive(true)

        // The buttons are not in the hierarchy during this turn, so asking for
        // focus has to come after it.
        Task { @MainActor in
            menuFocus = .resume
        }
    }

    /// Closes the menu and hands the controller back to the game.
    private func closeMenu() {
        menuFocus = nil
        showingFilters = false
        showingVideo = false
        showingStates = false
        filterFocus = nil
        videoFocus = nil
        stateFocus = nil
        withAnimation(.easeInOut(duration: 0.2)) { isMenuOpen = false }
        session?.setPaused(false)
        ControllerCapture.setInterfaceActive(false)
        controllerInput.setGameplayActive(true)
    }

    private func menuButtonID(containing name: String) -> String? {
        session?.layout?.allButtons.first { $0.id.contains(name) }?.id
    }

    private func tapButton(named name: String) {
        guard let session else { return }
        cancelButtonTap()
        closeMenu()
        tappedButton = name
        session.pressButton(named: name)
        buttonTap = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            session.releaseButton(named: name)
            tappedButton = nil
            buttonTap = nil
        }
    }

    private func cancelButtonTap() {
        buttonTap?.cancel()
        buttonTap = nil
        if let tappedButton { session?.releaseButton(named: tappedButton) }
        tappedButton = nil
    }

    /// Shows the filter list in place of the menu's buttons. The current
    /// filter starts selected. The rows are not in the hierarchy during
    /// this turn, so asking for focus comes after it.
    private func openFilters() {
        menuFocus = nil
        withAnimation(.easeInOut(duration: 0.2)) { showingFilters = true }
        Task { @MainActor in
            filterFocus = shaderName.map(FilterFocus.shader) ?? FilterFocus.none
        }
    }

    /// Returns from the filter list to the menu's buttons, landing back on
    /// the Filter button the list came from.
    private func closeFilters() {
        filterFocus = nil
        withAnimation(.easeInOut(duration: 0.2)) { showingFilters = false }
        Task { @MainActor in
            menuFocus = .filter
        }
    }

    /// Shows the save-state list in place of the menu's buttons, starting on
    /// the newest slot's Load, or the main slot's Save Here when none is
    /// filled yet. The rows are not in the hierarchy during this turn, so
    /// asking for focus comes after it.
    private func openStates() {
        menuFocus = nil
        slots = session?.filledSlots ?? []
        withAnimation(.easeInOut(duration: 0.2)) { showingStates = true }
        Task { @MainActor in
            stateFocus = slots.first.map { StateFocus.load($0.kind) } ?? StateFocus.save(SaveKind.state)
        }
    }

    /// Returns from the save-state list to the menu's buttons, landing back
    /// on the Save States button the list came from.
    private func closeStates() {
        stateFocus = nil
        withAnimation(.easeInOut(duration: 0.2)) { showingStates = false }
        Task { @MainActor in
            menuFocus = .states
        }
    }

    /// Shows the video list in place of the menu's buttons. The rows are not
    /// in the hierarchy during this turn, so asking for focus comes after it.
    private func openVideo() {
        menuFocus = nil
        withAnimation(.easeInOut(duration: 0.2)) { showingVideo = true }
        Task { @MainActor in
            videoFocus = .metalFX(metalFXChoice)
        }
    }

    /// Returns from the video list to the menu's buttons, landing back on
    /// the Video button the list came from.
    private func closeVideo() {
        videoFocus = nil
        withAnimation(.easeInOut(duration: 0.2)) { showingVideo = false }
        Task { @MainActor in
            menuFocus = .video
        }
    }

    // MARK: - Upscaling and rumble

    /// Whether this device can run MetalFX at all.
    private var metalFXAvailable: Bool {
#if canImport(MetalFX)
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return MTLFXSpatialScalerDescriptor.supportsDevice(device)
#else
        return false
#endif
    }

    private var systemID: String? {
        game.systemIdentifier.isEmpty ? nil : game.systemIdentifier
    }

    private var metalFXChoice: UpscalingOptions.Choice {
        guard let systemID else { return upscalingOptions.isOn(.metalFX) ? .on : .off }
        return upscalingOptions.choice(for: .metalFX, system: systemID)
    }

    private var scalingChoice: UpscalingOptions.Choice {
        guard let systemID else { return upscalingOptions.isOn(.integerScaling) ? .on : .off }
        return upscalingOptions.choice(for: .integerScaling, system: systemID)
    }

    private func upscalingSummary(_ option: UpscalingOptions.Option) -> String {
        guard let systemID else { return upscalingOptions.isOn(option) ? "On" : "Off" }
        return upscalingOptions.summary(option, forSystem: systemID)
    }

    private func metalFXTitle(_ choice: UpscalingOptions.Choice) -> String {
        switch choice {
        case .automatic: return "Use Default"
        case .off:       return "Off"
        case .on:        return metalFXAvailable ? "MetalFX Spatial" : "MetalFX Spatial (Unavailable)"
        }
    }

    private func scalingTitle(_ choice: UpscalingOptions.Choice) -> String {
        switch choice {
        case .automatic: return "Use Default"
        case .off:       return "Fill"
        case .on:        return "Pixel Perfect"
        }
    }

    /// The current rumble strength, for the video list.
    private var rumbleTitle: String {
        (RumbleStrength(rawValue: rumbleStrength) ?? .medium).title
    }

    /// Switch MetalFX spatial upscaling on the running game.
    ///
    /// The pick is remembered for this system, and the engine quietly keeps
    /// the plain picture where MetalFX cannot run. The same rule as the phone.
    private func applyMetalFXUpscaling(_ choice: UpscalingOptions.Choice) {
        guard choice != .on || metalFXAvailable else {
            show(notice: "MetalFX is not available on this device")
            return
        }

        storeUpscaling(choice, for: .metalFX)
        session?.setMetalFXUpscalingEnabled(upscalingOptions.isEnabled(.metalFX, forSystem: systemID))
        show(notice: upscalingOptions.isEnabled(.metalFX, forSystem: systemID) ? "MetalFX upscaling on" : "MetalFX upscaling off")
    }

    /// Switch whole-number (pixel-perfect) scaling on the running game.
    ///
    /// The pick is remembered for this system. The engine keeps the picture
    /// filling the screen when it would not fit a whole number of times.
    private func applyIntegerScaling(_ choice: UpscalingOptions.Choice) {
        storeUpscaling(choice, for: .integerScaling)
        session?.setIntegerScalingEnabled(upscalingOptions.isEnabled(.integerScaling, forSystem: systemID))
        show(notice: upscalingOptions.isEnabled(.integerScaling, forSystem: systemID) ? "Pixel-perfect scaling on" : "Fill scaling on")
    }

    /// Remember an upscaling pick for this system, or app-wide when the game
    /// has no system — the same rule the video filter follows.
    private func storeUpscaling(_ choice: UpscalingOptions.Choice, for option: UpscalingOptions.Option) {
        if let systemID {
            upscalingOptions.setChoice(choice, for: option, system: systemID)
        } else {
            upscalingOptions.setOn(choice == .on, for: option)
        }
    }

    // MARK: - Video filter

    /// Switch the filter on the running game and remember the pick for this
    /// system, so the next launch uses it. The list closes and the menu
    /// returns, so the result is visible straight away.
    private func applyFilter(named name: String?) {
        guard let session else { return }
        shaderName = name
        shaderCatalog.setChoice(name.map { .shader($0) } ?? .none, forSystem: session.systemIdentifier)

        show(notice: name.map { "Applying \($0)…" } ?? "Filter off")
        session.setShader(shaderCatalog.shader(named: name)) { result in
            switch result {
            case .success:
                show(notice: name.map { "\($0) on" } ?? "Filter off")
            case .failure(let error):
                show(notice: error.localizedDescription)
            }
        }
        closeFilters()
    }

    private func saveBeforeLeaving() {
        guard !didClose, let session, session.isRunning else { return }
        leftActive = true
        controllerInput.setGameplayActive(false)
        session.setPaused(true)
        if session.raHardcoreActive {
            fileSavesAndRecordPlay()
        } else {
            session.saveState(in: SaveKind.autosave) { _ in
                self.fileSavesAndRecordPlay()
            }
        }
    }

    private func fileSavesAndRecordPlay() {
        let store = TVStore.shared
        store.fileSessionSaves(game)
        store.recordPlay(game)
        Task { await store.syncNow() }
    }

    private func close() {
        // Write the autosave first so the phone can pick up where the TV
        // stopped. Each of the save, its timeout, and the no-session path
        // finishes the close, and only the first one counts.
        guard !didClose else { return }
        didClose = true
        controllerInput.stop()
        cancelButtonTap()
        // Nothing ran, nothing to save: closing before the core started goes
        // straight out. Hardcore refuses save states, so it does too.
        if let session, session.isRunning, !session.raHardcoreActive {
            session.saveState(in: SaveKind.autosave) { _ in
                self.finishClose()
            }
            Task {
                try? await Task.sleep(for: .seconds(5))
                self.finishClose()
            }
        } else {
            finishClose()
        }
    }

    private func finishClose() {
        guard !finishedClosing else { return }
        finishedClosing = true
        onFinished?()
        onClose()
    }

    private func report(_ result: Result<Void, Error>, success: String) {
        switch result {
        case .success:
            show(notice: success)
        case .failure(let error):
            show(notice: error.localizedDescription)
        }
    }

    private func show(notice message: String) {
        withAnimation {
            notice = message
        }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation {
                notice = nil
            }
        }
    }
}
