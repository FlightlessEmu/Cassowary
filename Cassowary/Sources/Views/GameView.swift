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

/// Plays one game.
///
/// The core is resolved before this view appears (see `LibraryView.play`),
/// so what you see in the title chip is what is running. A nil core means
/// "no explicit pick" and the session falls back to the first installed core
/// for the ROM's system — or reports which piece is missing.
struct GameView: View {

    let game: Game
    let core: OECorePlugin?
    /// The save-state slot to load once the game is running, if the game was
    /// launched from the resume sheet.
    let resumeSlot: String?
    let onClose: () -> Void

    @State private var session: GameSession?
    @State private var layout: ControllerLayout?
    @State private var keyboardInput: KeyboardControlManager?
    @State private var errorMessage: String?
    @State private var isPaused = false
    @State private var notice: String?
    @State private var raSignedIn = false
    @State private var showingAchievements = false
    /// The on-screen controls are being moved around.
    @State private var editingControls = false
    /// Whether editing the controls paused the game, so finishing resumes it.
    @State private var pausedForEditing = false
    /// The disc in the drive, numbered from 1. Every game starts on its first.
    @State private var currentDisc: UInt = 1

    /// The app's foreground/background state, so a game can be paused on the way
    /// out and picked back up on the way in.
    @Environment(\.scenePhase) private var scenePhase

    /// Whether the last pause was one this view made on its own — on the way to
    /// the background. Only then does coming back resume the game; a pause the
    /// player asked for stays put.
    @State private var pausedForBackground = false

    /// The save-state manager is open.
    @State private var showStates = false
    /// Guards the autosave-and-close path so a second tap cannot save twice
    /// or close twice.
    @State private var isClosing = false
    /// `onClose` has fired. Both the autosave and its timeout call it, so
    /// only the first one counts.
    @State private var didClose = false
    @StateObject private var shaderCatalog = ShaderCatalog()
    /// Whether the game is listening to the microphone, for the Blow button.
    @ObservedObject private var microphone = MicrophoneCapture.shared
    @State private var shaderName: String?
    @AppStorage(RumbleHaptics.strengthKey) private var rumbleStrength = RumbleStrength.medium.rawValue

    /// The two upscaling switches. Each has an app-wide default and can be
    /// overridden per system, the same as the video filter.
    @StateObject private var upscalingOptions = UpscalingOptions()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let session, let layer = session.videoLayer, let layout {
                GameLayerView(
                    layer: layer,
                    bufferSize: {
                        let size = session.videoBufferSize
                        return CGSize(width: CGFloat(size.width), height: CGFloat(size.height))
                    },
                    aspectRatio: { session.displayAspectRatio },
                    onTouch: { touch in
                        switch touch {
                        case .down(let point):
                            session.touchDown(at: GameView.bufferPoint(point))
                        case .moved(let point):
                            session.touchMoved(to: GameView.bufferPoint(point))
                        case .up:
                            session.touchUp()
                        }
                    },
                    onResize: { bounds in
                        session.updateDisplayBounds(bounds)
                    }
                )
                .ignoresSafeArea()

                // The controls respect the safe area on every edge: in
                // landscape that keeps them clear of the sensor housing, and
                // on a foldable it keeps them clear of the system bars.
                OnScreenControls(layout: layout, session: session, isEditing: $editingControls)

                if isPaused {
                    pausedOverlay(session: session)
                }
            }

            if let errorMessage {
                errorState(errorMessage)
            }
        }
        // The game controls use white labels over dark backgrounds. Keep their
        // contrast when the library follows the Mac's light appearance.
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .background {
            // The UIKit half of the keyboard: GameController does the main
            // work, but it can be absent, so the responder chain covers it.
            if let keyboardInput {
                KeyboardKeyCaptureView { keyCode, isDown in
                    keyboardInput.handle(keyCode: keyCode, isDown: isDown)
                }
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                topBar
                if let notice {
                    noticeBanner(notice)
                }
                if let session {
                    RAUnlockToast(state: session.raState)
                        .padding(.horizontal)
                    RAIndicatorsView(state: session.raState)
                        .padding(.horizontal)
                }
            }
        }
        .sheet(isPresented: $showingAchievements) {
            if let session {
                AchievementsSheet(state: session.raState)
            }
        }
        .task {
            startGame()

            // Opens the controls editor without tapping, for screenshots.
            // Only set from the command line.
            if UserDefaults.standard.bool(forKey: "cassowary.editControls") {
                editingControls = true
            }
        }
        .onChange(of: editingControls) { _, editing in
            handleControlEditing(editing)
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhase(phase)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            handleMemoryWarning()
        }
        .onDisappear {
            keyboardInput?.stop()
            keyboardInput = nil

            // Keep the session until the core has actually stopped: the helper
            // finishes the frame it is in on its own thread first, and a quick
            // reopen must not start a second core on top of the one that is
            // still winding down.
            guard let session else { return }
            session.stop {
                DiagnosticsStore.shared.noteSessionEnded()
                self.session = nil
            }
        }
        .sheet(isPresented: $showStates) {
            if let session {
                SaveStatesSheet(session: session,
                                romURL: game.url,
                                gameID: PlayHistory.gameID(for: game))
            }
        }
    }

    // MARK: - Top bar

    /// Translucent control cluster: close, title chip, pause, save, more.
    /// A dark backing keeps labels readable even over a bright game frame.
    private var topBar: some View {
        HStack(spacing: 8) {
            glassButton("xmark") { closeGame() }
                .accessibilityLabel("Close game")

            Spacer()

            if session != nil {
                // First claim on the room the buttons leave: the spacers
                // give way before the title does.
                titleChip
                    .layoutPriority(1)
            }

            Spacer()

            if let session {
                if raPanelAvailable {
                    glassButton("trophy.fill") {
                        showingAchievements = true
                    }
                    .accessibilityLabel("Achievements")
                }

                glassButton(isPaused ? "play.fill" : "pause.fill") {
                    togglePause(session: session)
                }
                .accessibilityLabel(isPaused ? "Resume" : "Pause")
                .keyboardShortcut("p", modifiers: .command)

                // Hardcore turns save states off; the engine refuses them
                // anyway, so don't offer buttons that can only fail.
                if !session.raHardcoreActive {
                    glassButton("square.and.arrow.down") {
                        session.saveState { result in
                            report(result, success: "Saved")
                        }
                    }
                    .accessibilityLabel("Save state")
                    .keyboardShortcut("s", modifiers: .command)
                }

                Menu {
                    // Only while a DS game is listening: blowing into a real
                    // microphone works too, but a phone held at arm's length,
                    // a refused permission or a Mac without one needs this.
                    // The pad's Mic button does the same; this is for when a
                    // controller has hidden the pad. Kept out of the top bar,
                    // which has no room for it on a narrow phone.
                    if microphone.isListening {
                        Button("Blow Into Microphone", systemImage: "wind") {
                            microphone.blow()
                            show(notice: "Blowing")
                        }
                        Divider()
                    }
                    // Hardcore turns save states off, so the manager has
                    // nothing it could do.
                    if !session.raHardcoreActive {
                        Button("Save States…") {
                            showStates = true
                        }
                    }
                    Button("Reset Game") {
                        session.resetEmulation()
                    }
                    // Multi-disc games (an .m3u playlist) ask for the next
                    // disc on screen; this is the lid and the swap.
                    if session.discCount > 1 {
                        Picker("Disc: \(currentDisc) of \(session.discCount)", selection: discBinding(for: session)) {
                            ForEach(1...Int(session.discCount), id: \.self) { disc in
                                Text("Disc \(disc)").tag(UInt(disc))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    Divider()
                    // A picker in a menu becomes a submenu with a checkmark
                    // drawn beside the current choice. The current pick also
                    // rides in the row's title, so the menu shows what is on
                    // without opening anything.
                    Picker("Video Filter: \(shaderName ?? "None")", selection: filterBinding) {
                        Text("None").tag(String?.none)
                        ForEach(shaderCatalog.names, id: \.self) { name in
                            Text(name).tag(String?.some(name))
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Upscaling: \(metalFXOn ? "MetalFX Spatial" : "Off")", selection: metalFXBinding) {
                        if game.system != nil {
                            Text("Use Default").tag(UpscalingOptions.Choice.automatic)
                        }
                        Text("Off").tag(UpscalingOptions.Choice.off)
                        Text(metalFXAvailable ? "MetalFX Spatial" : "MetalFX Spatial (Unavailable)").tag(UpscalingOptions.Choice.on)
                    }
                    .pickerStyle(.menu)

                    Picker("Scaling: \(integerScalingOn ? "Pixel Perfect" : "Fill")", selection: integerScalingBinding) {
                        if game.system != nil {
                            Text("Use Default").tag(UpscalingOptions.Choice.automatic)
                        }
                        Text("Fill").tag(UpscalingOptions.Choice.off)
                        Text("Pixel Perfect").tag(UpscalingOptions.Choice.on)
                    }
                    .pickerStyle(.menu)

                    Picker("Rumble: \(rumbleTitle)", selection: rumbleBinding) {
                        ForEach(RumbleStrength.allCases) { strength in
                            Text(strength.title).tag(strength)
                        }
                    }
                    .pickerStyle(.menu)

                    Button("Edit Controls Layout", systemImage: "arrow.up.and.down.and.arrow.left.and.right") {
                        editingControls = true
                    }

                    Divider()
                    Button("Close Game", role: .destructive) {
                        closeGame()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.72), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("More actions")
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    /// What is playing and what is running it.
    private var titleChip: some View {
        VStack(spacing: 1) {
            // A long title shrinks a little before it is cut short; a
            // small phone has room for about a dozen letters at full size.
            Text(game.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let subtitle = coreSubtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.black.opacity(0.72), in: .capsule)
    }

    private var coreSubtitle: String? {
        guard let session else { return game.systemName }
        if let system = game.systemName {
            return "\(system) · \(session.coreDisplayName)"
        }
        return session.coreDisplayName
    }

    // MARK: - RetroAchievements

    /// Whether the trophy button shows: signed in and the running core
    /// supports achievements for this system.
    private var raPanelAvailable: Bool {
        guard raSignedIn, let systemID = game.system?.identifier else { return false }
        guard let core else { return true }
        return core.supportsRetroAchievements(forSystemIdentifier: systemID)
    }

    /// Hold the game still while the controls are moved, since they cannot
    /// press anything meanwhile. Hardcore mode limits pausing, so there the
    /// game keeps running; a game the player already paused stays paused.
    private func handleControlEditing(_ editing: Bool) {
        guard let session else { return }
        if editing {
            if !isPaused, !session.raHardcoreActive {
                session.setPaused(true)
                pausedForEditing = true
            }
        } else if pausedForEditing {
            pausedForEditing = false
            if !isPaused {
                session.setPaused(false)
            }
        }
    }

    /// Pause through RetroAchievements when hardcore is on: the server can
    /// refuse a pause that comes too often. Resuming always works.
    private func togglePause(session: GameSession) {
        guard !isPaused else {
            isPaused = false
            session.setPaused(false)
            return
        }
        session.canPauseHardcore { allowed, secondsToWait in
            Task { @MainActor in
                if allowed {
                    isPaused = true
                    session.setPaused(true)
                } else if secondsToWait > 0 {
                    show(notice: "Hardcore mode allows pausing again in \(secondsToWait) s.")
                } else {
                    show(notice: "RetroAchievements is not allowing pause right now.")
                }
            }
        }
    }

    // MARK: - Video filter

    /// The filter picker's binding: choosing a row runs the same apply the
    /// menu buttons used to.
    private var filterBinding: Binding<String?> {
        Binding(
            get: { shaderName },
            set: { applyFilter(named: $0) }
        )
    }

    /// Switch the filter on the running game and remember the pick for this
    /// system, so the next launch uses it.
    private func applyFilter(named name: String?) {
        guard let session else { return }
        shaderName = name

        if let systemID = game.system?.identifier {
            shaderCatalog.setChoice(name.map { .shader($0) } ?? .none, forSystem: systemID)
        } else {
            shaderCatalog.globalShaderName = name
        }

        show(notice: name.map { "Applying \($0)…" } ?? "Filter off")
        session.setShader(shaderCatalog.shader(named: name)) { result in
            switch result {
            case .success:
                show(notice: name.map { "\($0) on" } ?? "Filter off")
            case .failure(let error):
                show(notice: error.localizedDescription)
            }
        }
    }

    // MARK: - Upscaling

    /// Whether this device can run MetalFX at all. The Simulator has no
    /// MetalFX, and some older GPUs cannot run the scaler.
    private var metalFXAvailable: Bool {
#if canImport(MetalFX)
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return MTLFXSpatialScalerDescriptor.supportsDevice(device)
#else
        return false
#endif
    }

    /// Whether MetalFX is on for this game's system, after the app-wide default.
    private var metalFXOn: Bool {
        upscalingOptions.isEnabled(.metalFX, forSystem: game.system?.identifier)
    }

    /// Whether pixel-perfect scaling is on for this game's system.
    private var integerScalingOn: Bool {
        upscalingOptions.isEnabled(.integerScaling, forSystem: game.system?.identifier)
    }

    /// Switch MetalFX spatial upscaling on the running game.
    ///
    /// The pick is remembered for this system, and the engine quietly keeps
    /// the plain picture where MetalFX cannot run. Picking it on hardware
    /// without MetalFX leaves the setting where it was and says so.
    private func applyMetalFXUpscaling(_ choice: UpscalingOptions.Choice) {
        guard choice != .on || metalFXAvailable else {
            show(notice: "MetalFX is not available on this device")
            return
        }

        store(choice, for: .metalFX)
        session?.setMetalFXUpscalingEnabled(upscalingOptions.isEnabled(.metalFX, forSystem: game.system?.identifier))
        show(notice: metalFXOn ? "MetalFX upscaling on" : "MetalFX upscaling off")
    }

    /// The MetalFX picker's binding.
    private var metalFXBinding: Binding<UpscalingOptions.Choice> {
        Binding(
            get: { upscalingChoice(for: .metalFX) },
            set: { applyMetalFXUpscaling($0) }
        )
    }

    /// Switch whole-number (pixel-perfect) scaling on the running game.
    ///
    /// The pick is remembered for this system. The engine keeps the picture
    /// filling the screen when it would not fit a whole number of times.
    private func applyIntegerScaling(_ choice: UpscalingOptions.Choice) {
        store(choice, for: .integerScaling)
        session?.setIntegerScalingEnabled(upscalingOptions.isEnabled(.integerScaling, forSystem: game.system?.identifier))
        show(notice: integerScalingOn ? "Pixel-perfect scaling on" : "Fill scaling on")
    }

    /// The scaling picker's binding.
    private var integerScalingBinding: Binding<UpscalingOptions.Choice> {
        Binding(
            get: { upscalingChoice(for: .integerScaling) },
            set: { applyIntegerScaling($0) }
        )
    }

    /// What this game's system is set to for an option. A game with no system
    /// has no per-system pick, so the app-wide choice reads back as on or off.
    private func upscalingChoice(for option: UpscalingOptions.Option) -> UpscalingOptions.Choice {
        if let systemID = game.system?.identifier {
            return upscalingOptions.choice(for: option, system: systemID)
        }
        return upscalingOptions.isOn(option) ? .on : .off
    }

    /// Remember an upscaling pick for this system, or app-wide when the game
    /// has no system — the same rule the video filter follows.
    private func store(_ choice: UpscalingOptions.Choice, for option: UpscalingOptions.Option) {
        if let systemID = game.system?.identifier {
            upscalingOptions.setChoice(choice, for: option, system: systemID)
        } else {
            upscalingOptions.setOn(choice == .on, for: option)
        }
    }

    // MARK: - Rumble

    /// The rumble picker's binding. The strength is read from defaults each
    /// time a rumble starts, so writing the pick is all it takes.
    private func discBinding(for session: GameSession) -> Binding<UInt> {
        Binding(
            get: { currentDisc },
            set: { disc in
                guard disc != currentDisc else { return }
                session.setDisc(disc)
                currentDisc = disc
            }
        )
    }

    private var rumbleBinding: Binding<RumbleStrength> {
        Binding(
            get: { RumbleStrength(rawValue: rumbleStrength) ?? .medium },
            set: { rumbleStrength = $0.rawValue }
        )
    }

    /// The current rumble strength, for the menu row.
    private var rumbleTitle: String {
        (RumbleStrength(rawValue: rumbleStrength) ?? .medium).title
    }

    private func glassButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.72), in: .circle)
        }
        .buttonStyle(.plain)
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

    // MARK: - Closing

    /// Closes the game, writing the autosave first so the next launch — here
    /// or on the TV — can pick up where this one stopped.
    private func closeGame() {
        guard !isClosing else { return }
        isClosing = true
        // Nothing ran, nothing to save: closing before the core started, or
        // from the error screen, goes straight out. Hardcore refuses save
        // states, so it goes straight out too.
        if let session, session.isRunning, !session.raHardcoreActive {
            session.saveState(in: SaveKind.autosave) { _ in
                finishClose()
            }
            // Never trap the player on a save that will not finish.
            Task {
                try? await Task.sleep(for: .seconds(5))
                finishClose()
            }
        } else {
            finishClose()
        }
    }

    private func finishClose() {
        guard !didClose else { return }
        didClose = true
        onClose()
    }

    /// Loads the slot the game was launched to resume, when it still holds a
    /// state. A missing file just starts fresh: a state can be deleted, or
    /// replaced by a sync, while the resume sheet is up.
    private func loadResumeSlot(on session: GameSession) {
        guard let resumeSlot, session.hasSaveState(in: resumeSlot) else { return }
        // The library does not offer slots in hardcore, but hardcore could
        // have been switched on while the resume sheet was up.
        guard !session.raHardcoreActive else {
            show(notice: "Hardcore mode is on, so the game starts fresh")
            return
        }
        session.loadState(from: resumeSlot) { result in
            switch result {
            case .success:
                show(notice: "Resumed \(SaveKind.displayName(for: resumeSlot))")
            case .failure(let error):
                show(notice: error.localizedDescription)
            }
        }
    }

    // MARK: - Overlays

    private func noticeBanner(_ message: String) -> some View {
        Text(message)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.72), in: .capsule)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func pausedOverlay(session: GameSession) -> some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.white)

                Text("Paused")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)

                if let subtitle = coreSubtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }

                Button("Resume") {
                    isPaused = false
                    session.setPaused(false)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.2))
                .keyboardShortcut(.cancelAction)
            }
        }
        .transition(.opacity)
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Could Not Start", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Close", action: onClose)
        }
        .background(.background)
    }

    // MARK: - Starting

    private func startGame() {
        guard session == nil else { return }

        do {
            let session = try GameSession(
                romURL: game.url,
                core: core,
                systemIdentifier: game.system?.identifier
            )

            if let plugin = game.system.flatMap({ system in
                OESystemPlugin.allPlugins.first { $0.systemIdentifier == system.identifier }
            }) {
                let layout = ControllerLayout(systemPlugin: plugin)
                self.layout = layout
                session.layout = layout

                // Physical gamepads reach the game through the engine's
                // bindings — the bridge starts them in GameSession — so they
                // drive the same buttons as the on-screen pad, and the
                // Controller Bindings screen can remap them.

                // A hardware keyboard drives them too, resolved through the
                // engine bindings the settings screen edits.
                let manager = KeyboardControlManager(session: session)
                manager.start()
                keyboardInput = manager
            }

            self.session = session
            self.raSignedIn = RetroAchievementsCredentialStore.load().isSignedIn

            // Leave a note that a game is running. It is cleared when the game
            // stops cleanly, so one that survives to the next launch marks the
            // app having been killed mid-game.
            DiagnosticsStore.shared.noteSessionStarted(
                title: game.title,
                core: session.coreDisplayName,
                system: game.system?.identifier
            )

            session.start {
                // The filter and upscaling switches remembered for this
                // system. Shared with the TV player: see `VideoSettings`.
                self.shaderName = self.shaderCatalog.resolvedShaderName(forSystem: self.game.system?.identifier)
                VideoSettings.applySaved(to: session,
                                         systemIdentifier: self.game.system?.identifier,
                                         shaderCatalog: self.shaderCatalog,
                                         upscaling: self.upscalingOptions)
                self.loadResumeSlot(on: session)
            }

            runTestHooks(session)
        } catch {
            // The engine wraps the core's reason as the underlying error
            // (missing BIOS, bad image, ...). Show it: the wrapper alone
            // ("could not load ROM") never says what to fix.
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            if let detail = underlying?.localizedDescription, !detail.isEmpty {
                errorMessage = "\(error.localizedDescription)\n\(detail)"
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Keeping the game alive

    /// Pause when the app leaves the foreground, and pick the game back up on
    /// the way in.
    ///
    /// iOS freezes the app in the background, but the core's frame thread keeps
    /// running until the freeze lands, and the display can take its drawables
    /// away. Pausing first stops the game on a frame of our choosing. Only a
    /// pause this method made is undone on the way back: a pause the player
    /// asked for stays put.
    private func handleScenePhase(_ phase: ScenePhase) {
        keyboardInput?.setActive(phase == .active)
        guard let session, session.isRunning else { return }

        switch phase {
        case .background:
            guard !isPaused else { return }
            pausedForBackground = true
            isPaused = true
            session.setPaused(true)
        case .active:
            guard pausedForBackground else { return }
            pausedForBackground = false
            isPaused = false
            session.setPaused(false)
        default:
            break
        }
    }

    /// iOS is short on memory. Pause so the core stops growing, and say so,
    /// rather than let the process be killed mid-game.
    private func handleMemoryWarning() {
        guard let session, session.isRunning, !isPaused else { return }
        isPaused = true
        session.setPaused(true)
        show(notice: "Paused to free memory")
    }

    /// A touch point, rounded into the core's buffer pixels.
    private static func bufferPoint(_ point: CGPoint) -> OEIntPoint {
        OEIntPoint(x: Int32(point.x.rounded(.down)), y: Int32(point.y.rounded(.down)))
    }

    /// Automated test hooks, set on the command line by Scripts/cassowary/test-cassowary.sh.
    private func runTestHooks(_ session: GameSession) {
#if DEBUG
        if let button = UserDefaults.standard.string(forKey: "cassowary.testHoldButton") {
            // Three seconds suits a cartridge. A disc game's menu only takes a
            // fresh press once it is up, so a test can wait longer with
            // -cassowary.testHoldDelay <seconds>.
            let delay = UserDefaults.standard.double(forKey: "cassowary.testHoldDelay")
            Task {
                try? await Task.sleep(for: .seconds(delay > 0 ? delay : 3))
                session.pressButton(named: button)
            }
        }

        // Press the key a button is bound to, exercising the keyboard
        // binding path without the Simulator's hardware keyboard.
        if let button = UserDefaults.standard.string(forKey: "cassowary.testKeyboardButton") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                session.pressBoundKey(forButtonID: button)
            }
        }

        // Hold a gamepad control, exercising the controller binding path
        // without a hardware controller. Usage 0 is not a real control, so it
        // doubles as "not set".
        let gamepadUsage = UserDefaults.standard.integer(forKey: "cassowary.testGamepadUsage")
        if gamepadUsage > 0 {
            Task {
                try? await Task.sleep(for: .seconds(3))
                session.holdGamepadControl(usage: UInt32(gamepadUsage))
            }
        }

        if let spec = UserDefaults.standard.string(forKey: "cassowary.testKeyboardRemap") {
            let parts = spec.split(separator: ":")
            if parts.count == 2, let keyCode = Int(parts[1]) {
                session.remapForTesting(buttonID: String(parts[0]), keyCode: keyCode)
            }
        }

        if let button = UserDefaults.standard.string(forKey: "cassowary.testHoldAnalog") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                session.moveAnalogButton(named: button)
            }
        }

        if let button = UserDefaults.standard.string(forKey: "cassowary.testTapButton") {
            let delay = UserDefaults.standard.double(forKey: "cassowary.testTapDelay")
            Task {
                try? await Task.sleep(for: .seconds(delay > 0 ? delay : 3))
                session.pressButton(named: button)
                try? await Task.sleep(for: .milliseconds(150))
                session.releaseButton(named: button)
            }
        }

        // Tap the emulated touch screen at a point in buffer pixels, written
        // as "x,y". Used to check the touch path without a finger, and to
        // knock on Nintendogs' door in the end-to-end test.
        if let spec = UserDefaults.standard.string(forKey: "cassowary.testTouch") {
            let parts = spec.split(separator: ",").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2 {
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    session.touchDown(at: OEIntPoint(x: parts[0], y: parts[1]))
                    try? await Task.sleep(for: .milliseconds(150))
                    session.touchUp()
                }
            }
        }

        if UserDefaults.standard.bool(forKey: "cassowary.testLoadState") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                session.loadState { result in
                    if case .failure(let error) = result {
                        NSLog("[Cassowary] test load failed: %@", error.localizedDescription)
                    }
                }
            }
        }

        if UserDefaults.standard.bool(forKey: "cassowary.testSaveState") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                session.saveState { result in
                    if case .failure(let error) = result {
                        NSLog("[Cassowary] test save failed: %@", error.localizedDescription)
                    }
                }
            }
        }

        // Apply a filter, then take it off again, to prove the pipeline both
        // ways without a tap. Used by Scripts/cassowary/test-cassowary.sh.
        if let shader = UserDefaults.standard.string(forKey: "cassowary.testShader") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                session.setShader(shaderCatalog.shader(named: shader)) { result in
                    switch result {
                    case .success:
                        NSLog("[Cassowary] test shader applied: %@", shader)
                    case .failure(let error):
                        NSLog("[Cassowary] test shader failed: %@", error.localizedDescription)
                    }
                }

                try? await Task.sleep(for: .seconds(2))
                session.setShader(nil) { result in
                    switch result {
                    case .success:
                        NSLog("[Cassowary] test shader cleared")
                    case .failure(let error):
                        NSLog("[Cassowary] test shader clear failed: %@", error.localizedDescription)
                    }
                }
            }
        }

        // Turn MetalFX spatial upscaling on, then off again, to prove the
        // setting reaches the renderer without a tap.
        if UserDefaults.standard.bool(forKey: "cassowary.testMetalFXUpscaling") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                session.setMetalFXUpscalingEnabled(true)
                NSLog("[Cassowary] test MetalFX upscaling on")

                try? await Task.sleep(for: .seconds(3))
                session.setMetalFXUpscalingEnabled(false)
                NSLog("[Cassowary] test MetalFX upscaling off")
            }
        }

        // Turn whole-number scaling on, then off again, the same way.
        if UserDefaults.standard.bool(forKey: "cassowary.testIntegerScaling") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                session.setIntegerScalingEnabled(true)
                NSLog("[Cassowary] test integer scaling on")

                try? await Task.sleep(for: .seconds(3))
                session.setIntegerScalingEnabled(false)
                NSLog("[Cassowary] test integer scaling off")
            }
        }

        // Close the game after a while, so the return-to-library path — the one
        // that stops the core and tears the session down — can be checked
        // without a tap. Used by the run script.
        if let seconds = Self.testCloseDelay {
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                NSLog("[Cassowary] test close after %gs", seconds)
                onClose()
            }
        }
#endif
    }

#if DEBUG
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
#endif
}
