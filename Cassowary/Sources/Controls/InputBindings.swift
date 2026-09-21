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
import OpenEmuSystem
import OpenEmuKit

/// The engine's control-mapping stack, as the app uses it.
///
/// `OEBindingsController` owns one `OESystemBindings` per system: the keys
/// and controller buttons each system button answers to, created from the
/// plugin's `Keyboard-Mappings.plist` and `Controller-Mappings.plist` defaults
/// and persisted in `Default.oebindings` under Application Support. The
/// responder turns the events those bindings describe into emulator keys, and
/// this is the single place the app asks for them.
enum InputBindings {

    /// The bindings for a system, created with the plugin's defaults the first
    /// time they are asked for.
    static func systemBindings(for plugin: OESystemPlugin) -> OESystemBindings? {
        guard let controller = plugin.controller else { return nil }
        return OEBindingsController.default.systemBindings(for: controller)
    }

    /// One keyboard transition, ready to hand to the responder.
    ///
    /// The key code is a HID usage, the same value `GCKeyCode` and `UIKey`
    /// report — and the same value the plugin's keyboard mappings use.
    static func keyEvent(keyCode: Int, isDown: Bool) -> OEHIDEvent? {
        OEHIDEvent.keyEvent(
            withTimestamp: ProcessInfo.processInfo.systemUptime,
            keyCode: UInt(keyCode),
            state: isDown ? .on : .off
        )
    }

    /// Write binding changes out to `Default.oebindings`.
    ///
    /// The bindings controller also synchronizes when the app goes to the
    /// background or terminates, but an explicit save after each edit means a
    /// remap is safe even if the app is killed outright.
    static func save() {
        _ = OEBindingsController.default.synchronize()
    }
}

/// Forwards binding changes to one running game's responder.
///
/// The responder builds its event-to-key map from these callbacks, so every
/// change the settings screen makes reaches the game the moment it is made.
/// The macOS app forwarded the same two calls across XPC; here the responder
/// is in the same process. `OESystemBindings` keeps observers for as long as
/// they are registered, so `GameSession` removes this one when it stops.
@MainActor
final class SystemBindingsForwarder: NSObject, OESystemBindingsObserver {

    private weak var responder: OESystemResponder?

    init(responder: OESystemResponder) {
        self.responder = responder
        super.init()
    }

    func systemBindings(_ sender: OESystemBindings, didSetEvent event: OEHIDEvent, forBinding bindingDescription: OEBindingDescription, playerNumber: UInt) {
        responder?.systemBindingsDidSetEvent(event, forBinding: bindingDescription, playerNumber: playerNumber)
    }

    func systemBindings(_ sender: OESystemBindings, didUnsetEvent event: OEHIDEvent, forBinding bindingDescription: OEBindingDescription, playerNumber: UInt) {
        responder?.systemBindingsDidUnsetEvent(event, forBinding: bindingDescription, playerNumber: playerNumber)
    }
}
