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

/// Watches the hardware keyboard while a bindings editor is on screen.
///
/// While a game runs, `KeyboardControlManager` owns the keyboard. In Settings
/// there is no game, so the editor reads the keyboard itself: `pressedKeys`
/// lights up the keys that are down, and `onKey` hands the next transition to
/// the capture sheet.
///
/// Keys arrive from two sources, the same two the game uses: GameController's
/// `GCKeyboard`, which can be absent at launch, and the first-responder view
/// the editor puts behind its list. A repeated press is ignored by the set.
@MainActor
final class KeyboardInputMonitor: ObservableObject {

    /// The HID usages that are currently down.
    @Published private(set) var pressedKeys: Set<Int> = []

    /// Every transition while it is set. The capture sheet uses this; the
    /// editor only reads `pressedKeys`.
    var onKey: ((Int, Bool) -> Void)?

    private var input: GCKeyboardInput?
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }

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
        onKey = nil
    }

    /// One transition, from GameController or the UIKit responder view.
    func handle(keyCode: Int, isDown: Bool) {
        if isDown {
            pressedKeys.insert(keyCode)
        } else {
            pressedKeys.remove(keyCode)
        }
        onKey?(keyCode, isDown)
    }

    private func attach() {
        guard input == nil, let keyboard = GCKeyboard.coalesced?.keyboardInput else { return }

        input = keyboard
        keyboard.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            onMain { self?.handle(keyCode: keyCode.rawValue, isDown: pressed) }
        }
    }

    private func detach() {
        input?.keyChangedHandler = nil
        input = nil
        // A keyboard can be unplugged mid-press; let go of everything.
        pressedKeys.removeAll()
    }
}

/// Watches one physical controller while a bindings editor is on screen.
///
/// The events are the engine's own: `OEDeviceManager` hands out the same
/// `OEHIDEvent`s the responder resolves, so a captured event can be assigned
/// to a binding directly. A control is "pressed" when the event would drive
/// its emulator button — a button that is on, a trigger or stick past the
/// deadzone, a hat switch off centre.
@MainActor
final class ControllerInputMonitor: ObservableObject {

    /// The controls that are currently deflected, by control identifier.
    @Published private(set) var pressedControls: Set<String> = []

    /// Every event while it is set. The capture sheet uses this.
    var onEvent: ((OEHIDEvent) -> Void)?

    private(set) var handler: OEDeviceHandler?

    /// The token `OEDeviceManager` returns. The manager holds its monitors
    /// weakly, so this is what keeps it alive.
    private var monitor: Any?

    var deviceName: String { handler?.product ?? "the controller" }

    func start(handler: OEDeviceHandler) {
        stop()

        self.handler = handler
        monitor = OEDeviceManager.shared.addEventMonitor(for: handler) { [weak self] _, event in
            onMain { self?.handle(event) }
        }
    }

    func stop() {
        if let monitor {
            OEDeviceManager.shared.removeMonitor(monitor)
        }
        monitor = nil
        handler = nil
        pressedControls.removeAll()
        onEvent = nil
    }

    /// Whether an event is a press worth recording, as opposed to a release
    /// or the stream of near-centre values an analog stick reports.
    static func isPress(_ event: OEHIDEvent) -> Bool {
        switch event.type {
        case .button:
            return event.state == .on
        case .trigger:
            return event.value > 0.5
        case .axis:
            return abs(event.value) > 0.5
        case .hatSwitch:
            return !event.hatDirection.isEmpty
        default:
            return false
        }
    }

    private func handle(_ event: OEHIDEvent) {
        guard let value = handler?.controllerDescription?.controlValueDescription(for: event),
              let control = value.controlDescription?.identifier
        else { return }

        if Self.isPress(event) {
            pressedControls.insert(control)
        } else {
            pressedControls.remove(control)
        }

        onEvent?(event)
    }
}

/// Run `work` on the main actor.
///
/// GameController calls its handlers on the main thread, but nothing in the
/// API promises it, so be explicit and cheap about it. Shared by the keyboard
/// monitors and the controller bindings screen.
func onMain(_ work: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { work() }
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }
}
