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

/// How the on-screen pad reads a button.
///
/// The system plugins name their controls — "Start", "Select", "A", "△" — and
/// those names are what the pad draws. This turns the names with a familiar
/// shape into a symbol, and says which controls are system controls rather
/// than something a game plays with. Nothing here is per-console: the plugins
/// already carry the names, so a console with different buttons needs no new
/// code.
enum ButtonGlyph {

    /// Whether a button is a system control: Start, Select, and their
    /// relatives like Mode, Lid, and Mic.
    ///
    /// These sit in the middle of the pad, where a real controller keeps them,
    /// and are drawn as symbols — the words are long, and the shape is what a
    /// player looks for.
    static func isSystem(_ button: ControllerButton) -> Bool {
        systemSymbols[normalized(button.label)] != nil
    }

    /// The symbol to draw for a button, or nil to draw its own label.
    static func symbol(for button: ControllerButton) -> String? {
        let label = normalized(button.label)
        return systemSymbols[label] ?? faceSymbols[label]
    }

    /// Start, Select, and the console-specific controls that go with them.
    private static let systemSymbols: [String: String] = [
        "start": "play.fill",
        // A small oval: the shape the Select button has on the pads that
        // have one, and not a copy/share glyph.
        "select": "oval",
        "mode": "slider.horizontal.3",
        "mode switch": "slider.horizontal.3",
        "analog mode": "l.joystick",
        "pause": "pause.fill",
        "menu": "line.3.horizontal",
        "home": "house.fill",
        "lid": "laptopcomputer",
        "mic": "waveform",
    ]

    /// Face buttons whose names are shapes or directions rather than letters.
    private static let faceSymbols: [String: String] = [
        // The PlayStation family names its buttons after shapes.
        "△": "triangle",
        "◯": "circle",
        "✕": "xmark",
        "×": "xmark",
        "▢": "square",
        "□": "square",
        // A second set of directions — the N64's C buttons, a Saturn 3D pad —
        // reads better as arrows than as four more words.
        "up": "chevron.up",
        "down": "chevron.down",
        "left": "chevron.left",
        "right": "chevron.right",
    ]

    /// Case and spacing do not matter in a plugin's label.
    private static func normalized(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
