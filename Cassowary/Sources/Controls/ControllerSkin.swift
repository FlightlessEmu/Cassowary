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

    /// The controller shell drawn behind the pad by the Console theme.
    struct Body {
        /// The shell's color at the top and at the bottom.
        let top: Color
        let bottom: Color
        /// Fill for buttons the skin does not paint: shoulders, Start, Select.
        var button: Color = Color(white: 0.24)
        /// Text and symbols on those buttons.
        var label: Color = .white
        /// The recessed area under the d-pad and the face buttons.
        var well: Color? = nil
        /// A thin colored line along the top of the shell.
        var stripe: Color? = nil
        /// Small colored dots in the middle of the shell, like the four on a
        /// Super Famicom pad.
        var dots: [Color] = []
    }

    let face: [Spot]
    var body: Body? = nil
    /// Shoulder buttons above the d-pad, outer one first.
    var leftShoulder: [String] = []
    /// Shoulder buttons above the face buttons, inner one first.
    var rightShoulder: [String] = []
    /// Buttons that sit with Start and Select, on the left and right of them:
    /// a PlayStation pad's stick clicks, which have no place of their own.
    var leftMiddle: [String] = []
    var rightMiddle: [String] = []
    /// Shorter text for buttons whose plugin label is too long to fit.
    var captions: [String: String] = [:]

    static func forSystem(_ identifier: String) -> ControllerSkin? {
        skins[identifier]
    }

    /// The shell for a system: its own, or a plain dark one.
    static func body(forSystem identifier: String) -> Body {
        skins[identifier]?.body ?? plainBody
    }

    private static let plainBody = Body(top: Color(white: 0.17), bottom: Color(white: 0.10), well: Color(white: 0.07))

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

    // MARK: - Shells

    private static let snesBody = Body(
        top: rgb(0.82, 0.82, 0.86), bottom: rgb(0.70, 0.70, 0.76),
        button: rgb(0.58, 0.58, 0.64), label: rgb(0.22, 0.22, 0.26),
        well: rgb(0.62, 0.60, 0.72),
        dots: [rgb(0.84, 0.16, 0.20), rgb(0.95, 0.74, 0.10), rgb(0.22, 0.34, 0.85), rgb(0.15, 0.58, 0.30)]
    )
    private static let nesBody = Body(
        top: rgb(0.80, 0.80, 0.78), bottom: rgb(0.68, 0.68, 0.66),
        button: rgb(0.16, 0.16, 0.16), well: rgb(0.10, 0.10, 0.10), stripe: nintendoRed
    )
    private static let gameBoyBody = Body(
        top: rgb(0.86, 0.85, 0.80), bottom: rgb(0.76, 0.75, 0.70),
        button: rgb(0.46, 0.46, 0.50), label: rgb(0.92, 0.92, 0.92),
        well: rgb(0.80, 0.79, 0.74)
    )
    private static let advanceBody = Body(
        top: rgb(0.34, 0.30, 0.64), bottom: rgb(0.24, 0.21, 0.52),
        button: rgb(0.50, 0.50, 0.58), well: rgb(0.20, 0.18, 0.44)
    )
    private static let dsBody = Body(
        top: rgb(0.34, 0.35, 0.38), bottom: rgb(0.22, 0.23, 0.25),
        button: rgb(0.44, 0.45, 0.48), well: rgb(0.18, 0.19, 0.21)
    )
    private static let virtualBoyBody = Body(
        top: rgb(0.16, 0.16, 0.17), bottom: rgb(0.08, 0.08, 0.09),
        button: rgb(0.22, 0.22, 0.24), well: rgb(0.05, 0.05, 0.06), stripe: nintendoRed
    )
    private static let n64Body = Body(
        top: rgb(0.30, 0.30, 0.32), bottom: rgb(0.17, 0.17, 0.19),
        button: rgb(0.36, 0.36, 0.38), well: rgb(0.14, 0.14, 0.16),
        dots: [rgb(0.84, 0.16, 0.20), n64Green, n64Blue, n64Yellow]
    )
    private static let playStationBody = Body(
        top: rgb(0.78, 0.78, 0.79), bottom: rgb(0.64, 0.64, 0.66),
        button: rgb(0.30, 0.30, 0.32), well: rgb(0.56, 0.56, 0.58),
        dots: [rgb(0.25, 0.80, 0.62), rgb(0.95, 0.35, 0.40), rgb(0.50, 0.65, 0.98), rgb(0.92, 0.55, 0.80)]
    )
    private static let segaBody = Body(
        top: rgb(0.15, 0.15, 0.16), bottom: rgb(0.07, 0.07, 0.08),
        button: rgb(0.20, 0.20, 0.22), label: rgb(0.78, 0.78, 0.80),
        well: rgb(0.04, 0.04, 0.05), stripe: rgb(0.78, 0.10, 0.12)
    )
    private static let saturnBody = Body(
        top: rgb(0.24, 0.24, 0.27), bottom: rgb(0.13, 0.13, 0.15),
        button: rgb(0.30, 0.30, 0.34), well: rgb(0.10, 0.10, 0.12),
        dots: [rgb(0.22, 0.34, 0.85), rgb(0.15, 0.58, 0.30), rgb(0.95, 0.74, 0.10), rgb(0.84, 0.16, 0.20)]
    )
    private static let pcEngineBody = Body(
        top: rgb(0.90, 0.90, 0.90), bottom: rgb(0.78, 0.78, 0.80),
        button: rgb(0.20, 0.20, 0.22), well: rgb(0.26, 0.26, 0.28)
    )

    // MARK: - The consoles

    private static let snes = ControllerSkin(
        face: diamond("X", "Y", "A", "B",
                      fills: [rgb(0.22, 0.34, 0.85), rgb(0.15, 0.58, 0.30), rgb(0.84, 0.16, 0.20), rgb(0.95, 0.74, 0.10)]),
        body: snesBody,
        leftShoulder: ["L"],
        rightShoulder: ["R"]
    )

    private static let nes = ControllerSkin(face: row(["B", "A"], fill: nintendoRed), body: nesBody)

    private static let playStation = ControllerSkin(
        face: diamond("△", "▢", "◯", "✕",
                      fills: [rgb(0.24, 0.24, 0.26), rgb(0.24, 0.24, 0.26), rgb(0.24, 0.24, 0.26), rgb(0.24, 0.24, 0.26)],
                      glyphs: [rgb(0.25, 0.80, 0.62), rgb(0.92, 0.55, 0.80), rgb(0.95, 0.35, 0.40), rgb(0.50, 0.65, 0.98)]),
        body: playStationBody,
        leftShoulder: ["L2", "L1"],
        rightShoulder: ["R1", "R2"],
        leftMiddle: ["L3"],
        rightMiddle: ["R3"]
    )

    private static let genesis = ControllerSkin(face: sixButton(top: ["X", "Y", "Z"], bottom: ["A", "B", "C"]), body: segaBody)

    private static let pcEngine = ControllerSkin(
        face: sixButton(top: ["4", "5", "6"], bottom: ["3", "2", "1"]),
        body: pcEngineBody,
        captions: ["1": "I", "2": "II", "3": "III", "4": "IV", "5": "V", "6": "VI"]
    )

    private static let skins: [String: ControllerSkin] = [
        "openemu.system.snes": snes,
        "openemu.system.nes": nes,
        "openemu.system.fds": nes,
        "openemu.system.gb": ControllerSkin(face: slant("B", "A", fill: gameBoyMagenta), body: gameBoyBody),
        "openemu.system.gba": ControllerSkin(
            face: slant("B", "A", fill: advanceLavender),
            body: advanceBody,
            leftShoulder: ["L"],
            rightShoulder: ["R"]
        ),
        "openemu.system.nds": ControllerSkin(
            face: diamond("X", "Y", "A", "B", fills: [dsGray, dsGray, dsGray, dsGray]),
            body: dsBody,
            leftShoulder: ["Left Trigger"],
            rightShoulder: ["Right Trigger"],
            captions: ["Left Trigger": "L", "Right Trigger": "R"]
        ),
        "openemu.system.vb": ControllerSkin(
            face: slant("B", "A", fill: nintendoRed),
            body: virtualBoyBody,
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
            body: n64Body,
            // Z sits under the left hand on a real pad.
            leftShoulder: ["L", "Z"],
            rightShoulder: ["R"]
        ),
        "openemu.system.psx": playStation,
        "openemu.system.ps2": playStation,
        "openemu.system.psp": ControllerSkin(
            face: playStation.face,
            body: playStationBody,
            leftShoulder: ["L1"],
            rightShoulder: ["R1"]
        ),
        "openemu.system.sg": genesis,
        "openemu.system.32x": genesis,
        "openemu.system.scd": genesis,
        "openemu.system.saturn": ControllerSkin(
            face: sixButton(top: ["X", "Y", "Z"], bottom: ["A", "B", "C"]),
            body: saturnBody,
            // The 3D pad's analog triggers sit with the shoulders, not in the
            // face cluster.
            leftShoulder: ["Trigger L", "L"],
            rightShoulder: ["R", "Trigger R"],
            captions: ["Trigger L": "L2", "Trigger R": "R2"]
        ),
        "openemu.system.sms": ControllerSkin(
            face: row(["Button 1/Start", "Button 2"]),
            body: segaBody,
            captions: ["Button 1/Start": "1", "Button 2": "2"]
        ),
        "openemu.system.sg1000": ControllerSkin(
            face: row(["Button 1", "Button 2"]),
            captions: ["Button 1": "1", "Button 2": "2"]
        ),
        "openemu.system.gg": ControllerSkin(
            face: slant("Button 1", "Button 2"),
            body: segaBody,
            captions: ["Button 1": "1", "Button 2": "2"]
        ),
        "openemu.system.pce": pcEngine,
        "openemu.system.pcecd": pcEngine,
        "openemu.system.pcfx": pcEngine,
        "openemu.system.3do": ControllerSkin(
            face: sixButton(top: [], bottom: ["A", "B", "C"]),
            body: segaBody,
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
