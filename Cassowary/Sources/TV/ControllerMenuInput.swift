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
import GameController
import Foundation

/// Handles remote gameplay and watches menu buttons alongside the engine's gamepad input.
@MainActor
final class ControllerMenuInput: NSObject, ObservableObject {
    @Published private(set) var hasGamepad = false

    private var controllers: [ObjectIdentifier: GCController] = [:]
    private var holds: [ObjectIdentifier: Task<Void, Never>] = [:]
    private weak var session: GameSession?
    private var remoteButtons: [ObjectIdentifier: [GamepadControl: GCControllerButtonInput]] = [:]
    private var remoteBindings: [ObjectIdentifier: UUID] = [:]
    private var remoteHeld: [ObjectIdentifier: [GamepadControl: ControllerButton]] = [:]
    private var openMenu: (() -> Void)?
    private var gameplayActive = false
    private var ignoreExitUntil: TimeInterval = 0

    func start(session: GameSession, openMenu: @escaping () -> Void) {
        stop()
        self.session = session
        self.openMenu = openMenu
        gameplayActive = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(didConnect(_:)), name: .GCControllerDidConnect, object: nil)
        center.addObserver(self, selector: #selector(didDisconnect(_:)), name: .GCControllerDidDisconnect, object: nil)
        for controller in GCController.controllers() { attach(controller) }
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        setGameplayActive(false)
        for controller in Array(controllers.values) { detach(controller) }
        openMenu = nil
        session = nil
        gameplayActive = false
        ignoreExitUntil = 0
    }

    func setGameplayActive(_ active: Bool) {
        gameplayActive = active
        for hold in holds.values { hold.cancel() }
        holds.removeAll()
        for controller in controllers.values where controller.extendedGamepad == nil {
            if active {
                attachRemoteGameplay(controller)
            } else {
                detachRemoteGameplay(controller)
            }
        }
    }

    // Back can arrive through both GameController and SwiftUI during hand-back.
    func menuDidOpen() {
        ignoreExitUntil = ProcessInfo.processInfo.systemUptime + 0.35
        setGameplayActive(false)
    }

    var shouldIgnoreExit: Bool {
        ProcessInfo.processInfo.systemUptime < ignoreExitUntil
    }

    @objc private func didConnect(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        Task { @MainActor [weak self] in
            guard let self, self.openMenu != nil else { return }
            self.attach(controller)
        }
    }

    @objc private func didDisconnect(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        Task { @MainActor [weak self] in self?.detach(controller) }
    }

    private func attach(_ controller: GCController) {
        let id = ObjectIdentifier(controller)
        guard controllers[id] == nil else { return }
        if let pad = controller.extendedGamepad {
            pad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
                Task { @MainActor in self?.menuChanged(controller, pressed: pressed) }
            }
            pad.buttonHome?.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in self?.requestMenu(controller) }
            }
        } else if let remote = controller.microGamepad {
            remote.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in self?.requestMenu(controller) }
            }
        } else {
            return
        }
        controllers[id] = controller
        if gameplayActive, controller.extendedGamepad == nil { attachRemoteGameplay(controller) }
        updateGamepadPresence()
    }

    private func detach(_ controller: GCController) {
        let id = ObjectIdentifier(controller)
        guard controllers.removeValue(forKey: id) != nil else { return }
        holds.removeValue(forKey: id)?.cancel()
        if let pad = controller.extendedGamepad {
            pad.buttonMenu.pressedChangedHandler = nil
            pad.buttonHome?.pressedChangedHandler = nil
        } else {
            detachRemoteGameplay(controller)
            controller.microGamepad?.buttonMenu.pressedChangedHandler = nil
        }
        updateGamepadPresence()
    }

    private func attachRemoteGameplay(_ controller: GCController) {
        let id = ObjectIdentifier(controller)
        guard remoteBindings[id] == nil, let remote = controller.microGamepad else { return }
        remote.reportsAbsoluteDpadValues = false
        remote.allowsRotation = true
        let binding = UUID()
        remoteBindings[id] = binding
        let buttons: [(GamepadControl, GCControllerButtonInput)] = [
            (.dpadUp, remote.dpad.up), (.dpadDown, remote.dpad.down),
            (.dpadLeft, remote.dpad.left), (.dpadRight, remote.dpad.right),
            (.buttonA, remote.buttonA), (.buttonB, remote.buttonX)
        ]
        for (control, input) in buttons {
            guard let button = session?.layout?.gamepadControls[control] else { continue }
            remoteButtons[id, default: [:]][control] = input
            input.pressedChangedHandler = { [weak self] _, _, pressed in
                Task { @MainActor in
                    guard let self, self.gameplayActive, self.remoteBindings[id] == binding else { return }
                    self.remoteButtonChanged(id, control: control, button: button, pressed: pressed)
                }
            }
        }
    }

    private func remoteButtonChanged(_ id: ObjectIdentifier, control: GamepadControl,
                                     button: ControllerButton, pressed: Bool) {
        if pressed {
            guard remoteHeld[id]?[control] == nil else { return }
            remoteHeld[id, default: [:]][control] = button
            session?.press(button.systemKey)
        } else if let held = remoteHeld[id]?.removeValue(forKey: control) {
            session?.release(held.systemKey)
        }
    }

    private func detachRemoteGameplay(_ controller: GCController) {
        let id = ObjectIdentifier(controller)
        // Discard queued presses from this binding before releasing its held keys.
        remoteBindings.removeValue(forKey: id)
        for input in remoteButtons.removeValue(forKey: id)?.values ?? [:].values {
            input.pressedChangedHandler = nil
        }
        for button in remoteHeld.removeValue(forKey: id)?.values ?? [:].values {
            session?.release(button.systemKey)
        }
    }

    private func updateGamepadPresence() {
        hasGamepad = controllers.values.contains { $0.extendedGamepad != nil }
    }

    private func menuChanged(_ controller: GCController, pressed: Bool) {
        let id = ObjectIdentifier(controller)
        holds.removeValue(forKey: id)?.cancel()
        guard pressed, gameplayActive, controllers[id] != nil else { return }
        holds[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.requestMenu(controller)
        }
    }

    private func requestMenu(_ controller: GCController) {
        guard gameplayActive, controllers[ObjectIdentifier(controller)] != nil else { return }
        openMenu?()
    }
}

#endif
