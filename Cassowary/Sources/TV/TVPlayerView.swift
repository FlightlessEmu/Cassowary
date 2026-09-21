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

/// Plays one game on the Apple TV.
///
/// The picture comes from the same Metal layer host the phone uses. The
/// difference is input: there is no touch pad on a TV, so a game controller
/// reaches the emulator through the engine's GameController bridge, which
/// `GameSession` starts when the game does.
struct TVPlayerView: View {

    let game: TVDemoGame
    let onClose: () -> Void

    @State private var session: GameSession?
    @State private var errorMessage: String?
    @State private var isPaused = false
    @State private var notice: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let session, let layer = session.videoLayer {
                GameLayerView(layer: layer) { bounds in
                    session.updateDisplayBounds(bounds)
                }
                .ignoresSafeArea()

                if isPaused {
                    pausedOverlay(session: session)
                }
            }

            if let errorMessage {
                errorState(errorMessage)
            }
        }
        .overlay(alignment: .top) { controls }
        .overlay(alignment: .bottom) { noticeBanner }
        .task { startGame() }
        .onDisappear { stopGame() }
        .onExitCommand { onClose() }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 20) {
            Button("Close") { onClose() }

            if let session {
                Button(isPaused ? "Resume" : "Pause") {
                    isPaused.toggle()
                    session.setPaused(isPaused)
                }

                Button("Save State") {
                    session.saveState { result in
                        report(result, success: "Saved")
                    }
                }

                if session.hasSaveState {
                    Button("Load State") {
                        session.loadState { result in
                            report(result, success: "Loaded")
                        }
                    }
                }

                Button("Reset") {
                    session.resetEmulation()
                    show(notice: "Reset")
                }
            }
        }
        .padding(.top, 28)
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

    private func pausedOverlay(session: GameSession) -> some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 64))
                Text("Paused")
                    .font(.title2.weight(.semibold))
            }
            .foregroundStyle(.white)
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

            Button("Close", action: onClose)
        }
        .padding(60)
    }

    // MARK: - Running

    private func startGame() {
        guard session == nil else { return }

        do {
            let session = try GameSession(romURL: game.url)

            // The layout describes the system's controls. The session needs it
            // before the game starts, so the bindings and anything that presses
            // a button by name have something to resolve against.
            if let plugin = TVDemoLibrary.systemPlugin(forExtension: game.url.pathExtension) {
                session.layout = ControllerLayout(systemPlugin: plugin)
            }

            self.session = session
            session.start { }

            // Used by the run script to prove input reaches the emulator with
            // no controller attached: hold the named button once the game is
            // running. Only set from the command line.
            if let button = UserDefaults.standard.string(forKey: "cassowary.testHoldButton") {
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    session.pressButton(named: button)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopGame() {
        session?.stop()
        session = nil
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
