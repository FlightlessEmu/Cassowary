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

#if os(tvOS)

import Combine
import OpenEmuSystem
import GameController
import Foundation

/// The controllers while a game plays: the Siri Remote as a simple gamepad,
/// and the buttons that bring up the game menu.
///
/// A gamepad reaches the game through the engine's own bridge; this only
/// watches its Menu and Home buttons. The remote is not an engine device at
/// all. It presses the game's buttons directly, the way the phone's on-screen
/// controls do, so it and a gamepad are both player one.
///
/// The rule it keeps: Back on the remote always opens the menu and never
/// reaches the game. A gamepad opens it by holding Menu (a short press is the
/// game's Start) or with Home, when tvOS delivers it.
///
/// GameController calls the handlers on the main queue, which is where all
/// of this state lives, so they act at once rather than hopping over later.
@MainActor
final class TVControllerInput: NSObject, ObservableObject {

    /// Whether a gamepad is connected, for the start-of-game hint.
    @Published private(set) var hasGamepad = false

    /// How long Menu has to be held on a gamepad to open the menu.
    private static let menuHold: Duration = .milliseconds(700)

    /// One connected controller and what is attached to it.
    private struct Attached {
        let controller: GCController
        /// The pending hold of a gamepad's Menu button.
        var menuHold: Task<Void, Never>?
        /// The remote's controls that are driving the game, and the game
        /// buttons they hold down right now.
        var gameInputs: [GCControllerButtonInput] = []
        var held: Set<OESystemKey> = []

        var isRemote: Bool { controller.extendedGamepad == nil }
    }

    private var attached: [ObjectIdentifier: Attached] = [:]
    private weak var session: GameSession?
    private var openMenu: (() -> Void)?
    /// True while the game has the controllers: the menu is closed.
    private var gameplayActive = false
    /// See `shouldIgnoreExit`.
    private var ignoreExitUntil: ContinuousClock.Instant?

    // MARK: - Starting and stopping

    func start(session: GameSession, openMenu: @escaping () -> Void) {
        stop()
        self.session = session
        self.openMenu = openMenu
        gameplayActive = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(didConnect(_:)), name: .GCControllerDidConnect, object: nil)
        center.addObserver(self, selector: #selector(didDisconnect(_:)), name: .GCControllerDidDisconnect, object: nil)
        GCController.controllers().forEach(attach)
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        setGameplayActive(false)
        attached.values.map(\.controller).forEach(detach)
        openMenu = nil
        session = nil
        ignoreExitUntil = nil
    }

    /// The menu closing gives the game the controllers; opening it takes
    /// them back, and lets go of anything the remote was holding.
    func setGameplayActive(_ active: Bool) {
        gameplayActive = active
        for id in attached.keys {
            attached[id]?.menuHold?.cancel()
            attached[id]?.menuHold = nil
            guard attached[id]?.isRemote == true else { continue }
            if active { startRemoteGameplay(id) } else { stopRemoteGameplay(id) }
        }
    }

    // MARK: - Opening the menu

    func menuDidOpen() {
        ignoreExitUntil = .now + .milliseconds(350)
        setGameplayActive(false)
    }

    /// Back on the remote can arrive twice as the menu opens: once here and
    /// once through SwiftUI's exit command. The second would close the menu
    /// again straight away, so it is ignored for a moment.
    var shouldIgnoreExit: Bool {
        guard let ignoreExitUntil else { return false }
        return .now < ignoreExitUntil
    }

    private func requestMenu() {
        guard gameplayActive else { return }
        openMenu?()
    }

    // MARK: - Controllers coming and going

    @objc private func didConnect(_ notification: Notification) {
        guard let controller = notification.object as? GCController, openMenu != nil else { return }
        attach(controller)
    }

    @objc private func didDisconnect(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        detach(controller)
    }

    private func attach(_ controller: GCController) {
        let id = ObjectIdentifier(controller)
        guard attached[id] == nil else { return }

        if let pad = controller.extendedGamepad {
            pad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
                MainActor.assumeIsolated { self?.gamepadMenuChanged(id, pressed: pressed) }
            }
            pad.buttonHome?.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                MainActor.assumeIsolated { self?.requestMenu() }
            }
        } else if let remote = controller.microGamepad {
            remote.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                MainActor.assumeIsolated { self?.requestMenu() }
            }
        } else {
            return
        }

        attached[id] = Attached(controller: controller)
        if gameplayActive, controller.extendedGamepad == nil { startRemoteGameplay(id) }
        updateGamepadPresence()
    }

    private func detach(_ controller: GCController) {
        let id = ObjectIdentifier(controller)
        guard let entry = attached[id] else { return }
        entry.menuHold?.cancel()
        stopRemoteGameplay(id)
        if let pad = controller.extendedGamepad {
            pad.buttonMenu.pressedChangedHandler = nil
            pad.buttonHome?.pressedChangedHandler = nil
        } else {
            controller.microGamepad?.buttonMenu.pressedChangedHandler = nil
        }
        attached[id] = nil
        updateGamepadPresence()
    }

    private func updateGamepadPresence() {
        hasGamepad = attached.values.contains { !$0.isRemote }
    }

    /// A short press stays the game's Start; holding opens the menu.
    private func gamepadMenuChanged(_ id: ObjectIdentifier, pressed: Bool) {
        attached[id]?.menuHold?.cancel()
        attached[id]?.menuHold = nil
        guard pressed, gameplayActive else { return }
        attached[id]?.menuHold = Task { [weak self] in
            try? await Task.sleep(for: Self.menuHold)
            guard !Task.isCancelled else { return }
            self?.requestMenu()
        }
    }

    // MARK: - The remote as a gamepad

    /// Swipes and clicks on the touch surface are the d-pad, clicking it is
    /// the button a gamepad's A presses, and Play/Pause is B's. It works held
    /// sideways too.
    private func startRemoteGameplay(_ id: ObjectIdentifier) {
        guard let entry = attached[id], entry.gameInputs.isEmpty,
              let remote = entry.controller.microGamepad,
              let layout = session?.layout
        else { return }

        remote.reportsAbsoluteDpadValues = false
        remote.allowsRotation = true

        let controls: [(GamepadControl, GCControllerButtonInput)] = [
            (.dpadUp, remote.dpad.up), (.dpadDown, remote.dpad.down),
            (.dpadLeft, remote.dpad.left), (.dpadRight, remote.dpad.right),
            (.buttonA, remote.buttonA), (.buttonB, remote.buttonX),
        ]
        var inputs: [GCControllerButtonInput] = []
        for (control, input) in controls {
            // A system without this control simply does not get it.
            guard let key = layout.gamepadControls[control]?.systemKey else { continue }
            input.pressedChangedHandler = { [weak self] _, _, pressed in
                MainActor.assumeIsolated { self?.remoteChanged(id, key: key, pressed: pressed) }
            }
            inputs.append(input)
        }
        attached[id]?.gameInputs = inputs
    }

    private func stopRemoteGameplay(_ id: ObjectIdentifier) {
        guard let entry = attached[id] else { return }
        entry.gameInputs.forEach { $0.pressedChangedHandler = nil }
        entry.held.forEach { session?.release($0) }
        attached[id]?.gameInputs = []
        attached[id]?.held = []
    }

    private func remoteChanged(_ id: ObjectIdentifier, key: OESystemKey, pressed: Bool) {
        guard gameplayActive, attached[id] != nil else { return }
        if pressed {
            guard attached[id]?.held.insert(key).inserted == true else { return }
            session?.press(key)
        } else if attached[id]?.held.remove(key) != nil {
            session?.release(key)
        }
    }
}

#endif
