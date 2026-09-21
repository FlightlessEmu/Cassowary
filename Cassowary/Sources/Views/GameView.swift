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

/// Plays one game.
///
/// The core is resolved before this view appears (see `LibraryView.play`),
/// so what you see in the title chip is what is running. A nil core means
/// "no explicit pick" and the session falls back to the first installed core
/// for the ROM's system — or reports which piece is missing.
struct GameView: View {

    let game: Game
    let core: OECorePlugin?
    let onClose: () -> Void

    @State private var session: GameSession?
    @State private var layout: ControllerLayout?
    @State private var padControllers: PhysicalControllerManager?
    @State private var keyboardInput: KeyboardControlManager?
    @State private var errorMessage: String?
    @State private var isPaused = false
    @State private var notice: String?
    @StateObject private var shaderCatalog = ShaderCatalog()
    @State private var shaderName: String?
    @AppStorage(RumbleHaptics.strengthKey) private var rumbleStrength = RumbleStrength.medium.rawValue

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let session, let layer = session.videoLayer, let layout {
                GameLayerView(layer: layer) { bounds in
                    session.updateDisplayBounds(bounds)
                }
                .ignoresSafeArea()

                OnScreenControls(layout: layout, session: session)
                    .ignoresSafeArea(edges: .horizontal)

                if isPaused {
                    pausedOverlay(session: session)
                }
            }

            if let errorMessage {
                errorState(errorMessage)
            }
        }
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
            }
        }
        .task {
            startGame()
        }
        .onDisappear {
            padControllers?.stop()
            padControllers = nil
            keyboardInput?.stop()
            keyboardInput = nil
            session?.stop()
            session = nil
        }
    }

    // MARK: - Top bar

    /// Translucent control cluster: close, title chip, pause, save, more.
    /// Glass materials keep it readable over any game, in both idioms.
    private var topBar: some View {
        HStack(spacing: 10) {
            glassButton("xmark") { onClose() }
                .accessibilityLabel("Close game")

            Spacer()

            if session != nil {
                titleChip
            }

            Spacer()

            if let session {
                glassButton(isPaused ? "play.fill" : "pause.fill") {
                    isPaused.toggle()
                    session.setPaused(isPaused)
                }
                .accessibilityLabel(isPaused ? "Resume" : "Pause")
                .keyboardShortcut("p", modifiers: .command)

                glassButton("square.and.arrow.down") {
                    session.saveState { result in
                        report(result, success: "Saved")
                    }
                }
                .accessibilityLabel("Save state")
                .keyboardShortcut("s", modifiers: .command)

                Menu {
                    if session.hasSaveState {
                        Button("Load State") {
                            session.loadState { result in
                                report(result, success: "Loaded")
                            }
                        }
                    }
                    Button("Reset Game") {
                        session.resetEmulation()
                    }
                    Divider()
                    Menu {
                        Button {
                            applyFilter(named: nil)
                        } label: {
                            filterMenuLabel("None", selected: shaderName == nil)
                        }

                        Divider()

                        ForEach(shaderCatalog.names, id: \.self) { name in
                            Button {
                                applyFilter(named: name)
                            } label: {
                                filterMenuLabel(name, selected: shaderName == name)
                            }
                        }
                    } label: {
                        Label("Video Filter", systemImage: "camera.filters")
                    }
                    Divider()
                    Menu {
                        ForEach(RumbleStrength.allCases) { strength in
                            Button {
                                rumbleStrength = strength.rawValue
                            } label: {
                                filterMenuLabel(strength.title, selected: rumbleStrength == strength.rawValue)
                            }
                        }
                    } label: {
                        Label("Rumble", systemImage: "waveform")
                    }
                    Divider()
                    Button("Close Game", role: .destructive) {
                        onClose()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: .circle)
                }
                .accessibilityLabel("More actions")
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    /// What is playing and what is running it.
    private var titleChip: some View {
        VStack(spacing: 1) {
            Text(game.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if let subtitle = coreSubtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: .capsule)
    }

    private var coreSubtitle: String? {
        guard let session else { return game.systemName }
        if let system = game.systemName {
            return "\(system) · \(session.coreDisplayName)"
        }
        return session.coreDisplayName
    }

    // MARK: - Video filter

    /// A filter row that shows a checkmark when it is the current filter.
    @ViewBuilder
    private func filterMenuLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    /// Apply the filter already chosen for this system, if any.
    ///
    /// The game starts unfiltered and the shader is compiled once it is
    /// running, so a slow first compile never delays the launch.
    private func applySavedFilter(on session: GameSession) {
        shaderName = shaderCatalog.resolvedShaderName(forSystem: game.system?.identifier)
        if let shader = shaderCatalog.shader(named: shaderName) {
            session.setShader(shader)
        }
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

    private func glassButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: .circle)
        }
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

    // MARK: - Overlays

    private func noticeBanner(_ message: String) -> some View {
        Text(message)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: .capsule)
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
            let session = try GameSession(romURL: game.url, core: core)

            if let plugin = game.system.flatMap({ system in
                OESystemPlugin.allPlugins.first { $0.systemIdentifier == system.identifier }
            }) {
                let layout = ControllerLayout(systemPlugin: plugin)
                self.layout = layout
                session.layout = layout

                // Physical gamepads drive the same buttons, through the same
                // session, as the on-screen pad. On iOS the engine's bridge
                // does this instead, through the bindings (see GameSession).
#if targetEnvironment(macCatalyst)
                let controllers = PhysicalControllerManager(session: session, layout: layout)
                controllers.start()
                padControllers = controllers
#endif

                // A hardware keyboard drives them too, resolved through the
                // engine bindings the settings screen edits.
                let manager = KeyboardControlManager(session: session)
                manager.start()
                keyboardInput = manager
            }

            self.session = session
            session.start {
                self.applySavedFilter(on: session)
            }

            runTestHooks(session)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Automated test hooks, set on the command line by Scripts/cassowary/test-cassowary.sh.
    private func runTestHooks(_ session: GameSession) {
#if DEBUG
        if let button = UserDefaults.standard.string(forKey: "cassowary.testHoldButton") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                session.pressButton(named: button)
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
#endif
    }
}
