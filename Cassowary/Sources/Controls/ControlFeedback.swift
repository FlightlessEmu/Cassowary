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
import UIKit
import OpenEmuSystem

/// The Settings → Controls haptics choice.
///
/// Read at press time rather than cached, so flipping the toggle takes effect
/// on the very next press.
enum ButtonHaptics {

    static let enabledKey = "cassowary.hapticsEnabled"
    static let styleKey = "cassowary.hapticStyle"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static var style: UIImpactFeedbackGenerator.FeedbackStyle {
        switch UserDefaults.standard.string(forKey: styleKey) {
        case "medium": return .medium
        case "heavy": return .heavy
        default: return .light
        }
    }

    /// One generator per strength, kept around so the first tap of a game is
    /// as sharp as the rest.
    private static var generators: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [:]

    @MainActor
    static func impact() {
        guard isEnabled else { return }

        let style = style
        let generator: UIImpactFeedbackGenerator
        if let existing = generators[style] {
            generator = existing
        } else {
            generator = UIImpactFeedbackGenerator(style: style)
            generators[style] = generator
        }
        generator.impactOccurred()
    }
}

/// Plays the button haptic, then forwards to the real handler.
///
/// The on-screen pads get one of these instead of the session itself, so a
/// touch buzzes while a physical controller or keyboard does not.
@MainActor
struct HapticPressHandler: ControlPressHandler {

    let target: any ControlPressHandler

    func press(_ button: OESystemKey) {
        ButtonHaptics.impact()
        target.press(button)
    }

    func release(_ button: OESystemKey) {
        target.release(button)
    }

    func moveAnalog(_ button: OESystemKey, value: CGFloat) {
        target.moveAnalog(button, value: value)
    }
}

/// Keeps a touch press down long enough for the emulator to see it.
///
/// A quick tap can begin and end between two frames, so the core never samples
/// the button as down and the tap is lost. Gestures report their press through
/// here, and the release is held back for a few frames. A fresh press while a
/// release is pending simply keeps the button down, which is what rapid
/// tapping wants anyway.
final class TapPressTiming {

    /// Several 60 Hz frames, but short enough that a tap still feels instant.
    static let minimumPress: TimeInterval = 0.08

    private var started: [UInt: Date] = [:]
    private var pending: [UInt: Task<Void, Never>] = [:]

    @MainActor
    func isDown(_ key: UInt) -> Bool {
        started[key] != nil
    }

    @MainActor
    func press(_ button: OESystemKey, handler: any ControlPressHandler) {
        pending[button.key]?.cancel()
        pending[button.key] = nil

        guard started[button.key] == nil else { return }
        started[button.key] = Date()
        handler.press(button)
    }

    /// A tap that began and ended inside one gesture update — report the press
    /// the gesture never sent on the way down, then let it release on time.
    @MainActor
    func endTap(_ button: OESystemKey, handler: any ControlPressHandler) {
        if !isDown(button.key) {
            press(button, handler: handler)
        }
        release(button, handler: handler)
    }

    @MainActor
    func release(_ button: OESystemKey, handler: any ControlPressHandler) {
        guard let start = started[button.key] else { return }

        let remaining = Self.minimumPress - Date().timeIntervalSince(start)
        guard remaining > 0 else {
            finish(button, handler: handler)
            return
        }

        pending[button.key] = Task { @MainActor in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            self.finish(button, handler: handler)
        }
    }

    /// Press what is newly wanted and release what is not, with the same
    /// reporting rules as `syncDirections`.
    @MainActor
    @discardableResult
    func sync(_ want: Set<String>, held: Set<String>, buttons: [String: ControllerButton], handler: any ControlPressHandler) -> Set<String> {
        for id in held.subtracting(want) {
            if let button = buttons[id] {
                release(button.systemKey, handler: handler)
            }
        }
        for id in want.subtracting(held) {
            if let button = buttons[id] {
                press(button.systemKey, handler: handler)
            }
        }
        return want
    }

    @MainActor
    private func finish(_ button: OESystemKey, handler: any ControlPressHandler) {
        pending[button.key] = nil
        started[button.key] = nil
        handler.release(button)
    }
}
