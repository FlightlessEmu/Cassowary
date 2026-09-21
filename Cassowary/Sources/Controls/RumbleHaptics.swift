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

import UIKit

/// How hard an emulated rumble plays back as haptics.
///
/// Read when a rumble starts rather than cached, so a change in the in-game
/// menu takes effect the next time the game rumbles.
enum RumbleStrength: String, CaseIterable, Identifiable {

    case off
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:    return "Off"
        case .low:    return "Low"
        case .medium: return "Medium"
        case .high:   return "High"
        }
    }

    /// How hard one impact hits, 0...1.
    var intensity: CGFloat {
        switch self {
        case .off:    return 0
        case .low:    return 0.35
        case .medium: return 0.7
        case .high:   return 1
        }
    }
}

/// Plays the emulated Rumble Pak on the device.
///
/// A rumble is a motor held on, not a tap, so this repeats a soft impact for
/// as long as the game holds it. Core Haptics would be smoother, but the
/// impact generator is the one that works on every device the app runs on,
/// and it matches the button feedback in `ButtonHaptics`.
@MainActor
final class RumbleHaptics {

    static let strengthKey = "cassowary.rumbleStrength"

    static var strength: RumbleStrength {
        UserDefaults.standard.string(forKey: strengthKey)
            .flatMap(RumbleStrength.init(rawValue:)) ?? .medium
    }

    /// Which players are rumbling right now. A game can rumble more than one.
    private var rumbling: Set<UInt> = []

    private var timer: Timer?
    private var generator: UIImpactFeedbackGenerator?

    func setRumbling(_ on: Bool, forPlayer player: UInt) {
        if on {
            rumbling.insert(player)
        } else {
            rumbling.remove(player)
        }

        update()
    }

    /// Stop everything, for when the game does.
    func stop() {
        rumbling.removeAll()
        update()
    }

    private func update() {
        let wantsRumble = !rumbling.isEmpty && Self.strength != .off

        guard wantsRumble else {
            timer?.invalidate()
            timer = nil
            return
        }

        guard timer == nil else { return }

        let generator = self.generator ?? UIImpactFeedbackGenerator(style: .medium)
        self.generator = generator
        generator.prepare()

        // Fourteen a second reads as one steady buzz rather than a rattle.
        let timer = Timer(timeInterval: 0.07, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.rumbling.isEmpty else { return }

                let strength = Self.strength
                guard strength != .off else { return }

                self.generator?.impactOccurred(intensity: strength.intensity)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
