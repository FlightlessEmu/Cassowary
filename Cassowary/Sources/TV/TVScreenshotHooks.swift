// Copyright (c) 2026, Cassowary contributors
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the Cassowary contributors nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY Cassowary contributors ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL Cassowary contributors BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#if DEBUG

import Foundation

/// Launch flags that open a TV screen by themselves, for screenshots and
/// checks in the Simulator, where there is no remote to press. Debug builds
/// only, and only set from the command line:
///
///     xcrun simctl launch <tv> org.cassowary.CassowaryTV -cassowary.tvTab settings
///
/// The game-menu flags (`testOpenMenu`, `testOpenFilters`, `testOpenStates`,
/// `tvOpenVideo`) are read by the player, since they need a running game.
enum TVScreenshotHooks {

    private static var defaults: UserDefaults { .standard }

    /// `cassowary.tvTab`: library, sources or settings.
    static var tab: String? { defaults.string(forKey: "cassowary.tvTab") }

    /// `cassowary.tvOpenSystem <systemIdentifier>`: that system's settings.
    static var systemToOpen: String? { defaults.string(forKey: "cassowary.tvOpenSystem") }

    /// `cassowary.tvOpenBindings <systemIdentifier>`: that system's
    /// Controller Buttons screen.
    static var bindingsToOpen: String? { defaults.string(forKey: "cassowary.tvOpenBindings") }

    /// `cassowary.tvOpenCorePicker <systemIdentifier>`: the core picker, for
    /// that system's first game or a stand-in when it has none.
    static var corePickerSystem: String? { defaults.string(forKey: "cassowary.tvOpenCorePicker") }

    /// `cassowary.tvSampleConflict YES`: a made-up save conflict, never
    /// written anywhere; its buttons only close it.
    static var showsSampleConflict: Bool { defaults.bool(forKey: "cassowary.tvSampleConflict") }

    /// `cassowary.tvOpenVideo YES`: starts the first game and opens its
    /// Video list.
    static var opensVideo: Bool { defaults.bool(forKey: "cassowary.tvOpenVideo") }

    /// True when a flag above asks for a screen, so real prompts such as a
    /// waiting save conflict stay out of the way of the screenshot.
    static var asksForScreen: Bool {
        systemToOpen != nil || bindingsToOpen != nil || corePickerSystem != nil || showsSampleConflict || opensVideo
    }
}

#endif
