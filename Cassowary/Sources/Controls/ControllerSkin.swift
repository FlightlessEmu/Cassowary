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

/// How a console's own controller is laid out, so the on-screen pad can look
/// like the real thing: a diamond for SNES, the slanted rows of a Genesis pad,
/// the big A and yellow C buttons of an N64, and shoulder buttons up top.
///
/// Buttons are matched by the label the system plugin gives them. A skin only
/// places the buttons it knows; anything else falls back to the plain blocks
/// below the cluster, so a missing or renamed button is never lost. A system
/// with no skin keeps the plain layout.
struct ControllerSkin {

    /// One face button: its centre and size in button-widths, and the colors
    /// the Console theme paints it.
    struct Spot {
        let label: String
        let x: CGFloat
        let y: CGFloat
        var size: CGFloat = 1
        /// Button color. Nil keeps the theme's dark fill.
        var fill: Color? = nil
        /// Symbol or letter color. Nil keeps white.
        var glyph: Color? = nil
    }

    let face: [Spot]
    /// Shoulder buttons above the d-pad, outer one first.
    var leftShoulder: [String] = []
    /// Shoulder buttons above the face buttons, inner one first.
    var rightShoulder: [String] = []
    /// Shorter text for buttons whose plugin label is too long to fit.
    var captions: [String: String] = [:]

    static func forSystem(_ identifier: String) -> ControllerSkin? {
        skins[identifier]
    }

    // MARK: - Shapes

    /// Two buttons on a slant, B low on the left and A high on the right,
    /// like a Game Boy.
    private static func slant(_ low: String, _ high: String, fill: Color? = nil) -> [Spot] {
        [
            Spot(label: low, x: 0, y: 0.55, fill: fill),
            Spot(label: high, x: 1.2, y: 0, fill: fill),
        ]
    }

    /// Buttons side by side, like an NES pad.
    private static func row(_ labels: [String], fill: Color? = nil) -> [Spot] {
        labels.enumerated().map { index, label in
            Spot(label: label, x: CGFloat(index) * 1.2, y: 0, fill: fill)
        }
    }

    /// Four buttons in a diamond: top, left, right, bottom.
    private static func diamond(
        _ top: String, _ left: String, _ right: String, _ bottom: String,
        fills: [Color?] = [nil, nil, nil, nil],
        glyphs: [Color?] = [nil, nil, nil, nil]
    ) -> [Spot] {
        [
            Spot(label: top, x: 1, y: 0, fill: fills[0], glyph: glyphs[0]),
            Spot(label: left, x: 0, y: 1, fill: fills[1], glyph: glyphs[1]),
            Spot(label: right, x: 2, y: 1, fill: fills[2], glyph: glyphs[2]),
            Spot(label: bottom, x: 1, y: 2, fill: fills[3], glyph: glyphs[3]),
        ]
    }

    /// Two rows of three that rise to the right, like a six-button Genesis
    /// or Saturn pad.
    private static func sixButton(top: [String], bottom: [String], fill: Color? = nil) -> [Spot] {
        func line(_ labels: [String], y: CGFloat) -> [Spot] {
            labels.enumerated().map { index, label in
                Spot(label: label, x: CGFloat(index) * 1.12, y: y - CGFloat(index) * 0.28, fill: fill)
            }
        }
        return line(top, y: 0.56) + line(bottom, y: 1.7)
    }

    // MARK: - Colors

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r, green: g, blue: b)
    }

    private static let nintendoRed = rgb(0.78, 0.12, 0.16)
    private static let gameBoyMagenta = rgb(0.62, 0.12, 0.40)
    private static let advanceLavender = rgb(0.46, 0.43, 0.62)
    private static let dsGray = rgb(0.40, 0.42, 0.46)
    private static let n64Blue = rgb(0.16, 0.30, 0.80)
    private static let n64Green = rgb(0.13, 0.55, 0.26)
    private static let n64Yellow = rgb(0.93, 0.74, 0.10)

    // MARK: - The consoles

    private static let snes = ControllerSkin(
        face: diamond("X", "Y", "A", "B",
                      fills: [rgb(0.22, 0.34, 0.85), rgb(0.15, 0.58, 0.30), rgb(0.84, 0.16, 0.20), rgb(0.95, 0.74, 0.10)]),
        leftShoulder: ["L"],
        rightShoulder: ["R"]
    )

    private static let nes = ControllerSkin(face: row(["B", "A"], fill: nintendoRed))

    private static let playStation = ControllerSkin(
        face: diamond("△", "▢", "◯", "✕",
                      glyphs: [rgb(0.25, 0.80, 0.62), rgb(0.92, 0.55, 0.80), rgb(0.95, 0.35, 0.40), rgb(0.50, 0.65, 0.98)]),
        leftShoulder: ["L2", "L1"],
        rightShoulder: ["R1", "R2"]
    )

    private static let genesis = ControllerSkin(face: sixButton(top: ["X", "Y", "Z"], bottom: ["A", "B", "C"]))

    private static let pcEngine = ControllerSkin(
        face: sixButton(top: ["4", "5", "6"], bottom: ["3", "2", "1"]),
        captions: ["1": "I", "2": "II", "3": "III", "4": "IV", "5": "V", "6": "VI"]
    )

    private static let skins: [String: ControllerSkin] = [
        "openemu.system.snes": snes,
        "openemu.system.nes": nes,
        "openemu.system.fds": nes,
        "openemu.system.gb": ControllerSkin(face: slant("B", "A", fill: gameBoyMagenta)),
        "openemu.system.gba": ControllerSkin(
            face: slant("B", "A", fill: advanceLavender),
            leftShoulder: ["L"],
            rightShoulder: ["R"]
        ),
        "openemu.system.nds": ControllerSkin(
            face: diamond("X", "Y", "A", "B", fills: [dsGray, dsGray, dsGray, dsGray]),
            leftShoulder: ["Left Trigger"],
            rightShoulder: ["Right Trigger"],
            captions: ["Left Trigger": "L", "Right Trigger": "R"]
        ),
        "openemu.system.vb": ControllerSkin(
            face: slant("B", "A", fill: nintendoRed),
            leftShoulder: ["L"],
            rightShoulder: ["R"]
        ),
        "openemu.system.n64": ControllerSkin(
            face: [
                Spot(label: "B", x: 0, y: 1.25, fill: n64Green),
                Spot(label: "A", x: 0.95, y: 2.05, size: 1.15, fill: n64Blue),
                // The C buttons: a small yellow diamond up and to the right.
                Spot(label: "Up", x: 2.2, y: 0, size: 0.72, fill: n64Yellow),
                Spot(label: "Left", x: 1.55, y: 0.62, size: 0.72, fill: n64Yellow),
                Spot(label: "Right", x: 2.85, y: 0.62, size: 0.72, fill: n64Yellow),
                Spot(label: "Down", x: 2.2, y: 1.24, size: 0.72, fill: n64Yellow),
            ],
            // Z sits under the left hand on a real pad.
            leftShoulder: ["L", "Z"],
            rightShoulder: ["R"]
        ),
        "openemu.system.psx": playStation,
        "openemu.system.ps2": playStation,
        "openemu.system.psp": ControllerSkin(
            face: playStation.face,
            leftShoulder: ["L1"],
            rightShoulder: ["R1"]
        ),
        "openemu.system.sg": genesis,
        "openemu.system.32x": genesis,
        "openemu.system.scd": genesis,
        "openemu.system.saturn": ControllerSkin(
            face: sixButton(top: ["X", "Y", "Z"], bottom: ["A", "B", "C"]),
            leftShoulder: ["L"],
            rightShoulder: ["R"]
        ),
        "openemu.system.sms": ControllerSkin(
            face: row(["Button 1/Start", "Button 2"]),
            captions: ["Button 1/Start": "1", "Button 2": "2"]
        ),
        "openemu.system.sg1000": ControllerSkin(
            face: row(["Button 1", "Button 2"]),
            captions: ["Button 1": "1", "Button 2": "2"]
        ),
        "openemu.system.gg": ControllerSkin(
            face: slant("Button 1", "Button 2"),
            captions: ["Button 1": "1", "Button 2": "2"]
        ),
        "openemu.system.pce": pcEngine,
        "openemu.system.pcecd": pcEngine,
        "openemu.system.pcfx": pcEngine,
        "openemu.system.3do": ControllerSkin(
            face: sixButton(top: [], bottom: ["A", "B", "C"]),
            leftShoulder: ["L"],
            rightShoulder: ["R"]
        ),
        "openemu.system.jaguar": ControllerSkin(face: sixButton(top: [], bottom: ["A", "B", "C"])),
        "openemu.system.lynx": ControllerSkin(face: slant("B", "A")),
        "openemu.system.ngp": ControllerSkin(face: slant("B", "A")),
        "openemu.system.ws": ControllerSkin(face: slant("B", "A")),
        "openemu.system.sv": ControllerSkin(face: slant("B", "A")),
        "openemu.system.pokemonmini": ControllerSkin(face: [
            Spot(label: "C", x: 0, y: 0),
            Spot(label: "B", x: 0.6, y: 1.1),
            Spot(label: "A", x: 1.8, y: 0.75),
        ]),
    ]
}
