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
    @State private var errorMessage: String?
    @State private var isPaused = false
    @State private var notice: String?

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
            }

            self.session = session
            session.start {}

            runTestHooks(session)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Automated test hooks, set on the command line by Scripts/ios/test-ios.sh.
    private func runTestHooks(_ session: GameSession) {
#if DEBUG
        if let button = UserDefaults.standard.string(forKey: "OETestHoldButton") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                session.pressButton(named: button)
            }
        }

        if UserDefaults.standard.bool(forKey: "OETestLoadState") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                session.loadState { result in
                    if case .failure(let error) = result {
                        NSLog("[OE] test load failed: %@", error.localizedDescription)
                    }
                }
            }
        }

        if UserDefaults.standard.bool(forKey: "OETestSaveState") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                session.saveState { result in
                    if case .failure(let error) = result {
                        NSLog("[OE] test save failed: %@", error.localizedDescription)
                    }
                }
            }
        }
#endif
    }
}
