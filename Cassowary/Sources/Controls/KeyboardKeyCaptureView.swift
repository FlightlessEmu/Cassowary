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
import UIKit

/// Delivers hardware key presses through the responder chain.
///
/// GameController is the primary keyboard source — it matches how gamepads are
/// read and needs no first-responder management — but it has known gaps:
/// `GCKeyboard.coalesced` can be nil at launch, and Full Keyboard Access can
/// swallow its events. UIKit delivers the same presses to a first responder,
/// so this view sits behind the game and both sources feed the one manager,
/// which ignores the duplicate.
struct KeyboardKeyCaptureView: UIViewRepresentable {

    /// Receives one transition: the HID usage and whether the key went down.
    let onKey: (Int, Bool) -> Void

    func makeUIView(context: Context) -> KeyCaptureUIView {
        let view = KeyCaptureUIView()
        view.onKey = onKey
        return view
    }

    func updateUIView(_ uiView: KeyCaptureUIView, context: Context) {
        uiView.onKey = onKey
    }

    /// The invisible first responder itself.
    final class KeyCaptureUIView: UIView {

        var onKey: ((Int, Bool) -> Void)?

        /// The keys this view has reported as down, so losing first responder
        /// can let go of exactly them and nothing else.
        private var deliveredKeys: Set<Int> = []

        override var canBecomeFirstResponder: Bool { true }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else {
                releaseDeliveredKeys()
                return
            }

            // The window is not key yet while the view is being inserted.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, !self.isFirstResponder else { return }
                self.becomeFirstResponder()
            }
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { releaseDeliveredKeys() }
            return resigned
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if !deliver(presses, isDown: true) {
                super.pressesBegan(presses, with: event)
            }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if !deliver(presses, isDown: false) {
                super.pressesEnded(presses, with: event)
            }
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if !deliver(presses, isDown: false) {
                super.pressesCancelled(presses, with: event)
            }
        }

        /// Hand a press set on. Returns whether anything was taken: app
        /// shortcuts (Command, Control and Option) are left to the responder
        /// chain so Save and Pause keep working.
        private func deliver(_ presses: Set<UIPress>, isDown: Bool) -> Bool {
            var handled = false

            for press in presses {
                guard let key = press.key else { continue }
                guard key.modifierFlags.intersection(UIKeyModifierFlags([.command, .control, .alternate])).isEmpty else {
                    continue
                }

                let keyCode = Int(key.keyCode.rawValue)
                if isDown {
                    deliveredKeys.insert(keyCode)
                } else {
                    deliveredKeys.remove(keyCode)
                }
                onKey?(keyCode, isDown)
                handled = true
            }

            return handled
        }

        private func releaseDeliveredKeys() {
            guard !deliveredKeys.isEmpty else { return }
            for keyCode in deliveredKeys {
                onKey?(keyCode, false)
            }
            deliveredKeys.removeAll()
        }
    }
}
