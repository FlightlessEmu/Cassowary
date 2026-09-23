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

    let title: String
    let url: URL
    /// Called once the game has stopped, before the view goes away, so the
    /// caller can file the save state and tell the phone about the session.
    var onFinished: (() -> Void)?

    let onClose: () -> Void

    @State private var session: GameSession?
    @State private var errorMessage: String?
    @State private var notice: String?
    /// The game's menu is open. Back opens it and closes it again.
    @State private var isMenuOpen = false

    /// Which of the menu's buttons is chosen.
    ///
    /// The menu opens with Resume selected, so there is a highlight to see and
    /// something for the remote to act on from the first press.
    @FocusState private var menuFocus: MenuFocus?

    private enum MenuFocus: Hashable {
        case resume, saveState, loadState, reset, close
    }

    /// A line telling the player how to reach the menu, shown once at the
    /// start and then out of the way. Nothing to focus, so it cannot get in
    /// the way of the game either.
    @State private var showsHint = true
    @State private var hideHint: Task<Void, Never>?

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
        .overlay(alignment: .bottom) { noticeBanner }
        .task { startGame() }
        .onDisappear {
            hideHint?.cancel()
            stopGame()
        }
        .onExitCommand {
            // Back opens the game's menu and closes it again. Closing the game
            // is a button on the menu, so a stray press can never throw a
            // session away — which is what made the old control row dangerous.
            if isMenuOpen {
                closeMenu()
            } else {
                openMenu()
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
            Color.black.opacity(0.75).ignoresSafeArea()

            VStack(spacing: 34) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)

                HStack(spacing: 24) {
                    Button("Resume") { closeMenu() }
                        .focused($menuFocus, equals: .resume)

                    if let session {
                        Button("Save State") {
                            session.saveState { result in
                                report(result, success: "Saved")
                            }
                        }
                        .focused($menuFocus, equals: .saveState)

                        if session.hasSaveState {
                            Button("Load State") {
                                session.loadState { result in
                                    report(result, success: "Loaded")
                                }
                            }
                            .focused($menuFocus, equals: .loadState)
                        }

                        Button("Reset") {
                            session.resetEmulation()
                            show(notice: "Reset")
                        }
                        .focused($menuFocus, equals: .reset)
                    }

                    Button("Close") { close() }
                        .focused($menuFocus, equals: .close)
                }
            }
            .padding(60)
        }
        .defaultFocus($menuFocus, .resume)
    }

    /// Tells the player how to reach the menu, then gets out of the way.
    private var hintBanner: some View {
        Group {
            if showsHint, !isMenuOpen, errorMessage == nil {
                Text("Press Back for options")
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
            let session = try GameSession(romURL: url)

            if let plugin = TVDemoLibrary.systemPlugin(forExtension: url.pathExtension) {
                session.layout = ControllerLayout(systemPlugin: plugin)
            }

            self.session = session
            session.start { }

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

    private func stopGame() {
        session?.stop()
        session = nil
    }

    /// Opens the game's menu.
    ///
    /// The game pauses and the controller goes back to tvOS. Both are needed:
    /// with the game still holding the controller nothing on screen could be
    /// chosen, which is what made the old control row look selected but do
    /// nothing.
    private func openMenu() {
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
        withAnimation(.easeInOut(duration: 0.2)) { isMenuOpen = false }
        session?.setPaused(false)
        ControllerCapture.setInterfaceActive(false)
    }

    private func close() {
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
