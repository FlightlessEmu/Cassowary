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

/// Names for the HID usages the keyboard reports.
///
/// GameController identifies keys by HID usage and does not name them, and the
/// engine's binding events carry the same usage, so the settings list builds
/// its own table. Common keys get a readable name; anything out of the table —
/// a media key, an international key — falls back to its usage so a binding is
/// never invisible.
enum KeyboardKey {

    static func name(for keyCode: Int) -> String {
        names[keyCode] ?? String(format: "Key 0x%02X", keyCode)
    }

    private static let names: [Int: String] = {
        var names: [Int: String] = [:]
        func add(_ code: GCKeyCode, _ name: String) { names[code.rawValue] = name }

        let letters: [GCKeyCode] = [
            .keyA, .keyB, .keyC, .keyD, .keyE, .keyF, .keyG, .keyH, .keyI, .keyJ,
            .keyK, .keyL, .keyM, .keyN, .keyO, .keyP, .keyQ, .keyR, .keyS, .keyT,
            .keyU, .keyV, .keyW, .keyX, .keyY, .keyZ,
        ]
        for (index, code) in letters.enumerated() {
            add(code, String(UnicodeScalar(UInt8(65 + index))))
        }

        let digits: [GCKeyCode] = [.one, .two, .three, .four, .five, .six, .seven, .eight, .nine, .zero]
        for (index, code) in digits.enumerated() {
            add(code, index == 9 ? "0" : String(index + 1))
        }

        let functions: [GCKeyCode] = [
            .F1, .F2, .F3, .F4, .F5, .F6, .F7, .F8, .F9, .F10, .F11, .F12,
        ]
        for (index, code) in functions.enumerated() {
            add(code, "F\(index + 1)")
        }

        add(.returnOrEnter, "Return")
        add(.escape, "Escape")
        add(.deleteOrBackspace, "Delete")
        add(.tab, "Tab")
        add(.spacebar, "Space")
        add(.hyphen, "-")
        add(.equalSign, "=")
        add(.openBracket, "[")
        add(.closeBracket, "]")
        add(.backslash, "\\")
        add(.semicolon, ";")
        add(.quote, "'")
        add(.graveAccentAndTilde, "`")
        add(.comma, ",")
        add(.period, ".")
        add(.slash, "/")
        add(.capsLock, "Caps Lock")

        add(.rightArrow, "Right Arrow")
        add(.leftArrow, "Left Arrow")
        add(.downArrow, "Down Arrow")
        add(.upArrow, "Up Arrow")

        add(.leftControl, "Left Control")
        add(.leftShift, "Left Shift")
        add(.leftAlt, "Left Option")
        add(.leftGUI, "Left Command")
        add(.rightControl, "Right Control")
        add(.rightShift, "Right Shift")
        add(.rightAlt, "Right Option")
        add(.rightGUI, "Right Command")

        return names
    }()
}
