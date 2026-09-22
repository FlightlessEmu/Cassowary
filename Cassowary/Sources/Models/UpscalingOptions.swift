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

/// The two picture-upscaling switches, each with an app-wide default and a
/// per-system override — the same shape as the video filter in `ShaderCatalog`.
///
/// "MetalFX" is the hardware upscaler; "Pixel Perfect" is whole-number
/// scaling. Both are off out of the box, and a system that follows the
/// app-wide choice stores nothing.
@MainActor
final class UpscalingOptions: ObservableObject {

    /// The two switches. The raw value is part of the stored keys, so it is
    /// stable once shipped.
    enum Option: String, CaseIterable {
        case metalFX = "metalFXUpscaling"
        case integerScaling = "integerScaling"

        /// The app-wide UserDefaults key.
        var globalKey: String { "cassowary." + rawValue }

        /// The name shown in the UI.
        var title: String {
            switch self {
            case .metalFX:        return "MetalFX"
            case .integerScaling: return "Pixel Perfect"
            }
        }
    }

    /// What one system should do, in addition to the app-wide choice.
    enum Choice: Hashable {
        /// Follow the app-wide choice. This is the out-of-the-box state.
        case automatic
        case off
        case on
    }

    static func systemKey(for option: Option, system: String) -> String {
        "cassowary." + option.rawValue + "." + system
    }

    // MARK: - The app-wide choices

    func isOn(_ option: Option) -> Bool {
        UserDefaults.standard.bool(forKey: option.globalKey)
    }

    func setOn(_ on: Bool, for option: Option) {
        UserDefaults.standard.set(on, forKey: option.globalKey)
        objectWillChange.send()
    }

    // MARK: - Per-system choices

    func choice(for option: Option, system: String) -> Choice {
        guard let raw = UserDefaults.standard.string(forKey: Self.systemKey(for: option, system: system)) else {
            return .automatic
        }
        return raw == "on" ? .on : .off
    }

    func setChoice(_ choice: Choice, for option: Option, system: String) {
        let key = Self.systemKey(for: option, system: system)
        switch choice {
        case .automatic:
            UserDefaults.standard.removeObject(forKey: key)
        case .off:
            UserDefaults.standard.set("off", forKey: key)
        case .on:
            UserDefaults.standard.set("on", forKey: key)
        }
        objectWillChange.send()
    }

    /// What a system actually gets: its own pick, else the app-wide one.
    func isEnabled(_ option: Option, forSystem system: String?) -> Bool {
        guard let system else { return isOn(option) }
        switch choice(for: option, system: system) {
        case .automatic: return isOn(option)
        case .off:       return false
        case .on:        return true
        }
    }

    /// One line explaining what a system will actually do.
    func summary(_ option: Option, forSystem system: String) -> String {
        let on = isEnabled(option, forSystem: system)
        switch choice(for: option, system: system) {
        case .automatic:
            return on ? "Following the app-wide setting: on." : "Following the app-wide setting: off."
        case .off:
            return "Off for this system."
        case .on:
            return "On for this system."
        }
    }
}
