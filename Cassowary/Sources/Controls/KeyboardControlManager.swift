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
/// Keys become `OEHIDEvent`s handed to the game's responder, which resolves
/// them through the system's bindings — the same map Settings edits. A remap
/// therefore reaches the game with no other wiring, and the engine decides
/// whether a bound key is digital or analog.
///
/// Events come from two sources on purpose: GameController's `GCKeyboard`,
/// which matches how gamepads are read but can be absent at launch, and a
/// first-responder view in the game (see `KeyboardKeyCaptureView`). The
/// responder deduplicates a repeated press, and whichever source reports the
/// release first is enough.
@MainActor
final class KeyboardControlManager {

    private let session: GameSession

    private var input: GCKeyboardInput?
    private var observers: [NSObjectProtocol] = []

    /// The keys currently down, so a source that repeats does not re-send.
    private var pressedKeys: Set<Int> = []

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

    init(session: GameSession) {
        self.session = session
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
        NSLog("[Cassowary] keyboard connected")
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
            session.handleKeyEvent(keyCode: keyCode, isDown: false)
            return
        }

        guard pressedKeys.insert(keyCode).inserted else { return }

        // Shortcut modifiers themselves are still bindable; it is the keys
        // pressed while one is held that belong to the app.
        if !Self.shortcutModifiers.contains(keyCode), !heldShortcutModifiers.isEmpty {
            ignoredKeys.insert(keyCode)
            return
        }

        session.handleKeyEvent(keyCode: keyCode, isDown: true)
    }

    /// Let go of every key still down, on keyboard disconnect or game stop.
    private func releaseAll() {
        for keyCode in pressedKeys where !ignoredKeys.contains(keyCode) {
            session.handleKeyEvent(keyCode: keyCode, isDown: false)
        }
        pressedKeys.removeAll()
        heldShortcutModifiers.removeAll()
        ignoredKeys.removeAll()
    }
}
