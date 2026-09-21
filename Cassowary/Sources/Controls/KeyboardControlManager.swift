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

import Foundation
import GameController
import OpenEmuSystem

/// Runs the hardware keyboard while a game is running.
///
/// Keys resolve through `KeyboardBindings`, so a remap in Settings changes the
/// game with no other wiring, and the presses go to `GameSession` exactly like
/// the on-screen pad and a physical gamepad. On systems with a real analog
/// stick, a bound direction key reports full deflection while it is held and
/// centers on release, matching the thumbstick.
@MainActor
final class KeyboardControlManager {

    private let session: any ControlPressHandler
    private let bindings: KeyboardBindings

    /// The buttons each key drives, built once from the bindings.
    private let keyMap: [Int: [ControllerButton]]

    private var input: GCKeyboardInput?
    private var observers: [NSObjectProtocol] = []

    /// The keys currently down. Key repeats do not re-fire the handler, but a
    /// set makes each transition count exactly once regardless.
    private var pressedKeys: Set<Int> = []

    /// How many keys hold each button down, so a button shared by two keys
    /// releases only when the last one does.
    private var downCounts: [String: Int] = [:]
    private var downButtons: [String: ControllerButton] = [:]

    /// The analog buttons currently deflected, so they can be centered.
    private var deflectedButtons: [String: ControllerButton] = [:]

    /// Command, Control and Option. A key pressed while one of those is held
    /// belongs to an app shortcut (Cmd+S saves a state), so it is kept out of
    /// the game. Shift is a normal game key on several systems, so it is not
    /// one of these.
    private static let shortcutModifiers: Set<Int> = [
        GCKeyCode.leftGUI.rawValue, GCKeyCode.rightGUI.rawValue,
        GCKeyCode.leftControl.rawValue, GCKeyCode.rightControl.rawValue,
        GCKeyCode.leftAlt.rawValue, GCKeyCode.rightAlt.rawValue,
    ]

    private var heldShortcutModifiers: Set<Int> = []

    /// Keys that went down while a shortcut modifier was held. They were not
    /// sent to the game, so their release must not be either.
    private var ignoredKeys: Set<Int> = []

    init(session: any ControlPressHandler, bindings: KeyboardBindings) {
        self.session = session
        self.bindings = bindings
        self.keyMap = bindings.keyMap
    }

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in
            onMain { self?.attach() }
        })
        observers.append(center.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            onMain { self?.detach() }
        })

        attach()
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        detach()
    }

    // MARK: - Attaching

    private func attach() {
        guard input == nil, let keyboard = GCKeyboard.coalesced?.keyboardInput else { return }

        input = keyboard
        keyboard.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            onMain { self?.handle(keyCode: keyCode.rawValue, isDown: pressed) }
        }
        NSLog("[Cassowary] keyboard connected (%ld keys mapped)", keyMap.count)
    }

    private func detach() {
        // A keyboard can be unplugged mid-press. Let go of everything so the
        // game does not keep moving.
        releaseAll()
        input?.keyChangedHandler = nil
        input = nil
    }

    // MARK: - Translating input

    /// Handle one key transition.
    ///
    /// Called by the GameController keyboard handler and by the UIKit
    /// first-responder view, which overlap on purpose: GameController can miss
    /// events, and the duplicate is filtered here — a key already down is not
    /// pressed twice, and whichever source reports the release first is enough.
    func handle(keyCode: Int, isDown: Bool) {
        if Self.shortcutModifiers.contains(keyCode) {
            if isDown {
                heldShortcutModifiers.insert(keyCode)
            } else {
                heldShortcutModifiers.remove(keyCode)
            }
        }

        guard isDown else {
            // A key that was ignored on the way down: its release is not the
            // game's either.
            if ignoredKeys.remove(keyCode) != nil {
                pressedKeys.remove(keyCode)
                return
            }
            guard pressedKeys.remove(keyCode) != nil else { return }
            for button in keyMap[keyCode] ?? [] { release(button) }
            return
        }

        guard pressedKeys.insert(keyCode).inserted else { return }

        // Shortcut modifiers themselves are still bindable; it is the keys
        // pressed while one is held that belong to the app.
        if !Self.shortcutModifiers.contains(keyCode), !heldShortcutModifiers.isEmpty {
            ignoredKeys.insert(keyCode)
            return
        }

        for button in keyMap[keyCode] ?? [] { press(button) }
    }

    private func press(_ button: ControllerButton) {
        if button.isAnalog {
            guard deflectedButtons[button.id] == nil else { return }
            deflectedButtons[button.id] = button
            session.moveAnalog(button.systemKey, value: 1)
        } else {
            let count = downCounts[button.id] ?? 0
            downCounts[button.id] = count + 1
            downButtons[button.id] = button
            if count == 0 {
                session.press(button.systemKey)
            }
        }
    }

    private func release(_ button: ControllerButton) {
        if button.isAnalog {
            guard deflectedButtons.removeValue(forKey: button.id) != nil else { return }
            session.moveAnalog(button.systemKey, value: 0)
        } else {
            guard let count = downCounts[button.id], count > 0 else { return }
            if count == 1 {
                downCounts.removeValue(forKey: button.id)
                downButtons.removeValue(forKey: button.id)
                session.release(button.systemKey)
            } else {
                downCounts[button.id] = count - 1
            }
        }
    }

    /// Let go of everything currently held, on keyboard disconnect or when
    /// the game stops.
    private func releaseAll() {
        for button in deflectedButtons.values {
            session.moveAnalog(button.systemKey, value: 0)
        }
        for button in downButtons.values {
            session.release(button.systemKey)
        }
        deflectedButtons.removeAll()
        downCounts.removeAll()
        downButtons.removeAll()
        pressedKeys.removeAll()
        heldShortcutModifiers.removeAll()
        ignoredKeys.removeAll()
    }

#if DEBUG
    /// Press the key bound to a named button, for the automated test.
    ///
    /// The simulator does not deliver its hardware keyboard to GameController,
    /// so the test drives the same handler a real key press would.
    func pressBoundKey(forButtonID buttonID: String) {
        guard let button = bindings.layout.allButtons.first(where: { $0.id == buttonID }),
              let keyCode = bindings.keyCode(for: button)
        else {
            NSLog("[Cassowary] no key is bound to %@; bound: %@", buttonID, bindings.layout.allButtons.map(\.id).joined(separator: ","))
            return
        }

        NSLog("[Cassowary] test keyboard: %@ pressed by key %@", buttonID, KeyboardKey.name(for: keyCode))
        handle(keyCode: keyCode, isDown: true)
    }
#endif
}
