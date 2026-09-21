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
import OpenEmuSystem
import OpenEmuKit

/// The keys bound to one system's buttons, and the rules for changing them.
///
/// Every system plugin ships a `Keyboard-Mappings.plist` — the same file the
/// macOS app read — naming a default key for each of its buttons, as a HID
/// usage. Those defaults are per system on purpose: Game Boy binds A and B to
/// two letters, the N64 binds its C buttons to four, and the ColecoVision
/// binds a whole number pad. A remap is stored in UserDefaults as an override
/// on top of the plugin's default, so a key that is never touched follows the
/// plugin even after an update.
struct KeyboardBindings {

    /// User remaps: `[system identifier: [button name: HID usage]]`.
    static let storeKey = "cassowary.keyboardBindings"

    /// HID usage 0 is reserved, so a stored 0 means "this button has no key".
    /// It is how clearing a default binding is remembered.
    static let unbound = 0

    let systemID: String
    let layout: ControllerLayout

    /// The plugin's default keys: button name → HID usage.
    private let defaults: [String: Int]

    /// The user's remaps: button name → HID usage.
    private(set) var overrides: [String: Int]

    init(systemID: String, layout: ControllerLayout, defaults: [String: Int]) {
        self.systemID = systemID
        self.layout = layout
        self.defaults = defaults
        self.overrides = Self.storedOverrides(for: systemID)
    }

    /// Build the bindings from a system plugin and the controls it describes.
    init(systemPlugin: OESystemPlugin, layout: ControllerLayout) {
        self.init(
            systemID: systemPlugin.systemIdentifier,
            layout: layout,
            defaults: Self.defaultKeys(in: systemPlugin)
        )
    }

    /// Whether anything in this system has been remapped.
    var isCustomized: Bool { !overrides.isEmpty }

    /// How many of the system's buttons answer to a key.
    var boundCount: Int {
        layout.allButtons.filter { keyCode(for: $0) != nil }.count
    }

    /// The key driving a button, or nil when it has none.
    func keyCode(for button: ControllerButton) -> Int? {
        let stored = overrides[button.id] ?? defaults[button.id]
        guard let stored, stored != Self.unbound else { return nil }
        return stored
    }

    /// The name of the key driving a button, for the settings list.
    func keyName(for button: ControllerButton) -> String {
        guard let keyCode = keyCode(for: button) else { return "—" }
        return KeyboardKey.name(for: keyCode)
    }

    /// Every button, grouped by the key that drives it, for the game.
    ///
    /// A key can drive more than one button — a plugin that maps two buttons
    /// to the same key, or a remap that lands on one — and each group presses
    /// all of its buttons together.
    var keyMap: [Int: [ControllerButton]] {
        var map: [Int: [ControllerButton]] = [:]
        for button in layout.allButtons {
            guard let keyCode = keyCode(for: button) else { continue }
            map[keyCode, default: []].append(button)
        }
        return map
    }

    // MARK: - Editing

    /// Give a button a key, taking that key from whichever other button had
    /// it. A key that drives two buttons would press both every time, which is
    /// never what a remap means, so the key moves rather than copies.
    mutating func assign(_ keyCode: Int, to button: ControllerButton) {
        for other in layout.allButtons where other.id != button.id && self.keyCode(for: other) == keyCode {
            overrides[other.id] = Self.unbound
        }
        overrides[button.id] = keyCode
        persist()
    }

    /// Remove a button's key without touching the rest of the system.
    mutating func clear(_ button: ControllerButton) {
        overrides[button.id] = Self.unbound
        persist()
    }

    /// Drop every remap and go back to the plugin's defaults.
    mutating func reset() {
        overrides.removeAll()
        persist()
    }

    // MARK: - Storage

    private static func storedOverrides(for systemID: String) -> [String: Int] {
        guard let all = UserDefaults.standard.dictionary(forKey: storeKey),
              let stored = all[systemID] as? [String: Any]
        else { return [:] }

        var overrides: [String: Int] = [:]
        for (button, value) in stored {
            if let number = value as? NSNumber {
                overrides[button] = number.intValue
            }
        }
        return overrides
    }

    private func persist() {
        var all = UserDefaults.standard.dictionary(forKey: Self.storeKey) ?? [:]
        if overrides.isEmpty {
            all.removeValue(forKey: systemID)
        } else {
            all[systemID] = overrides
        }
        UserDefaults.standard.set(all, forKey: Self.storeKey)
    }

    /// The system's default keys, read from its own plugin bundle.
    private static func defaultKeys(in plugin: OESystemPlugin) -> [String: Int] {
        guard let url = plugin.bundle.url(forResource: OEKeyboardMappingsFileName, withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Int]
        else { return [:] }

        return plist
    }
}

#if DEBUG
extension KeyboardBindings {
    /// Apply a remap from the command line, `-cassowary.testKeyboardRemap
    /// "OEGBButtonA:20"`, for the automated test. It goes through the same
    /// `assign` the settings editor calls, so persistence is exercised too.
    static func testRemap(_ spec: String, systemPlugin: OESystemPlugin, layout: ControllerLayout) {
        if spec == "reset" {
            var bindings = KeyboardBindings(systemPlugin: systemPlugin, layout: layout)
            bindings.reset()
            NSLog("[Cassowary] test remap: restored defaults")
            return
        }

        let parts = spec.split(separator: ":")
        guard parts.count == 2,
              let keyCode = Int(parts[1]),
              let button = layout.allButtons.first(where: { $0.id == String(parts[0]) })
        else {
            NSLog("[Cassowary] test remap: cannot parse %@", spec)
            return
        }

        var bindings = KeyboardBindings(systemPlugin: systemPlugin, layout: layout)
        bindings.assign(keyCode, to: button)
        NSLog("[Cassowary] test remap: %@ → %@", button.id, KeyboardKey.name(for: keyCode))
    }
}
#endif

/// Names for the HID usages the keyboard reports.
///
/// GameController identifies keys by HID usage and does not name them, so the
/// settings list builds its own table. Common keys get a readable name;
/// anything out of the table — a media key, an international key — falls back
/// to its usage so a binding is never invisible.
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
