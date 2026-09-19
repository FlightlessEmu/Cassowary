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
struct GameView: View {

    let game: Game
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
        .overlay(alignment: .topLeading) {
            toolbar
        }
        .overlay(alignment: .top) {
            if let notice {
                noticeBanner(notice)
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

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            circleButton("xmark") {
                onClose()
            }

            if let session {
                circleButton(isPaused ? "play.fill" : "pause.fill") {
                    isPaused.toggle()
                    session.setPaused(isPaused)
                }

                circleButton("square.and.arrow.down") {
                    session.saveState { result in
                        report(result, success: "Saved")
                    }
                }

                if session.hasSaveState {
                    circleButton("square.and.arrow.up") {
                        session.loadState { result in
                            report(result, success: "Loaded")
                        }
                    }
                }
            }
        }
        .padding()
    }

    private func circleButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.4), in: .circle)
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.15))
                }
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
            .background(.black.opacity(0.65), in: .capsule)
            .padding(.top, 8)
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

                Button("Resume") {
                    isPaused = false
                    session.setPaused(false)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.2))
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
    }

    // MARK: - Starting

    private func startGame() {
        guard session == nil else { return }

        do {
            let session = try GameSession(romURL: game.url)

            if let plugin = game.system.flatMap({ system in
                OESystemPlugin.allPlugins.first { $0.systemIdentifier == system.identifier }
            }) {
                let layout = ControllerLayout(systemPlugin: plugin)
                self.layout = layout
                session.layout = layout
            }

            self.session = session
            session.start {}

            // Automated test hooks. Both are only set on the command line, by
            // Scripts/ios/test-ios.sh.
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
