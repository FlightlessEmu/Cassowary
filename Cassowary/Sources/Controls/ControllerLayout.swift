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
import OpenEmuSystem
import OpenEmuKit

/// One button on an on-screen controller.
struct ControllerButton: Identifiable, Hashable {
    let id: String
    let label: String
    /// The index of the key in the system's binding list. This is what the
    /// responder expects — see `-[OESystemResponder emulatorKeyForKey:player:]`.
    let keyIndex: UInt
    let isAnalog: Bool

    /// The key to hand to the responder when this button is pressed.
    ///
    /// Player numbers are 1-based all the way down: the responders hand the
    /// number straight to the cores, which index their per-player pad state
    /// with `player - 1`. Passing 0 here underflows that subtraction, so the
    /// press lands outside the pad array and the game never sees it.
    var systemKey: OESystemKey {
        OESystemKey(key: keyIndex, player: 1, isAnalogic: isAnalog)
    }
}

/// One input on a physical gamepad, named after the standard MFi extended
/// gamepad that the system plugins' controller maps describe.
enum GamepadControl: Hashable {
    case buttonA, buttonB, buttonX, buttonY
    case leftShoulder, rightShoulder, leftTrigger, rightTrigger
    case home, menu, options
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case leftStickUp, leftStickDown, leftStickLeft, leftStickRight
    case rightStickUp, rightStickDown, rightStickLeft, rightStickRight
}

/// Which analog stick a control belongs to.
enum StickSide {
    case left
    case right
}

/// The emulated buttons one directional control drives.
///
/// A system with a real analog stick gives the d-pad one set of buttons and
/// the stick another; a system with plain digital directions gives both the
/// same set.
struct DirectionalButtons {
    let up: ControllerButton?
    let down: ControllerButton?
    let left: ControllerButton?
    let right: ControllerButton?

    var all: [ControllerButton?] { [up, down, left, right] }
    var isEmpty: Bool { all.allSatisfy { $0 == nil } }
    var ids: Set<String> { Set(all.compactMap { $0?.id }) }
}

/// Everything the front end knows about how a system is driven: the buttons to
/// draw, and which physical control each one answers to.
///
/// Every system plugin ships an `OEControlListKey` describing its controls —
/// the same list the macOS app uses to lay out its keyboard preferences — and
/// a `Controller-Mappings.plist` describing how a standard gamepad drives them.
/// Reading both here means the on-screen pad and a real controller agree by
/// construction: Game Boy gets a d-pad and two buttons, SNES swaps A/B for a
/// Nintendo layout, N64's stick reaches the analog inputs, and so on, with no
/// per-system code.
struct ControllerLayout {

    /// Buttons grouped the way the plugin groups them: a d-pad, then face
    /// buttons, then start/select. Used to draw the on-screen pad.
    let groups: [[ControllerButton]]

    /// The system button each physical control drives, read from the plugin's
    /// controller map. The on-screen d-pad and thumbstick styles are derived
    /// from it, so the pad is laid out the way the plugin describes.
    let gamepadControls: [GamepadControl: ControllerButton]

    /// The direction buttons the d-pad styles drive.
    let dPad: DirectionalButtons

    /// The direction buttons the thumbstick style drives. On a system with an
    /// analog stick these are the analog inputs, which is why the on-screen
    /// stick and a physical stick do the same thing.
    let leftStick: DirectionalButtons

    /// The direction buttons a right stick drives, when the system has one.
    /// The pad does not draw this stick; its directions are kept out of the
    /// action cluster so they are not mistaken for four face buttons.
    let rightStick: DirectionalButtons

    static let deadzone: CGFloat = 0.18

    var allButtons: [ControllerButton] { groups.flatMap { $0 } }

    /// Whether this system has controls that can be shown as buttons.
    var hasButtons: Bool { !allButtons.isEmpty }

    func button(for control: GamepadControl) -> ControllerButton? {
        gamepadControls[control]
    }

    func stickControls(_ side: StickSide) -> (up: GamepadControl, down: GamepadControl, left: GamepadControl, right: GamepadControl) {
        switch side {
        case .left:  return (.leftStickUp, .leftStickDown, .leftStickLeft, .leftStickRight)
        case .right: return (.rightStickUp, .rightStickDown, .rightStickLeft, .rightStickRight)
        }
    }

    init(systemPlugin: OESystemPlugin) {
        let controller = systemPlugin.controller
        let descriptions = controller?.allKeyBindingsDescriptions ?? [:]
        let controlList = systemPlugin.infoDictionary[OEControlListKey] as? [[Any]] ?? []

        var groups: [[ControllerButton]] = []

        for group in controlList {
            var buttons: [ControllerButton] = []

            for item in group {
                guard let entry = item as? [String: String],
                      let name = entry[OEControlListKeyNameKey],
                      let label = entry[OEControlListKeyLabelKey],
                      let description = descriptions[name]
                else { continue }

                buttons.append(ControllerButton(
                    id: name,
                    label: label,
                    keyIndex: description.index,
                    isAnalog: description.isAnalogic
                ))
            }

            if !buttons.isEmpty {
                groups.append(buttons)
            }
        }

        self.groups = groups

        let buttons = groups.flatMap { $0 }
        let byName = Dictionary(buttons.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let controls = Self.gamepadControls(systemPlugin: systemPlugin, buttons: buttons, byName: byName)
        self.gamepadControls = controls

        // The d-pad styles use the plugin's d-pad buttons; a plugin with no map
        // falls back to matching direction names.
        var pad = Self.directions(controls, .dpadUp, .dpadDown, .dpadLeft, .dpadRight)
        if pad.isEmpty {
            pad = Self.directions(fromNames: buttons)
        }
        self.dPad = pad

        // The thumbstick uses the analog directions when the system has them,
        // and the d-pad buttons otherwise, so the stick is never dead.
        var stick = Self.directions(controls, .leftStickUp, .leftStickDown, .leftStickLeft, .leftStickRight)
        if stick.isEmpty {
            stick = pad
        }
        self.leftStick = stick

        // A right stick is not drawn, so it gets no fallback: an empty set
        // means the system has none.
        self.rightStick = Self.directions(controls, .rightStickUp, .rightStickDown, .rightStickLeft, .rightStickRight)
    }

    // MARK: - Reading the plugin

    /// Build the physical mapping from the plugin's own controller map.
    ///
    /// The map names the standard MFi extended gamepad, so this is where a
    /// system's intent lives: SNES maps its B to the pad's A, N64 maps the
    /// left stick to its analog inputs and the right stick to its C buttons.
    private static func gamepadControls(
        systemPlugin: OESystemPlugin,
        buttons: [ControllerButton],
        byName: [String: ControllerButton]
    ) -> [GamepadControl: ControllerButton] {
        var mapping: [GamepadControl: ControllerButton] = [:]

        let partners = axisPartners(in: systemPlugin)

        for (systemKey, controlName) in profileMapping(in: systemPlugin) {
            guard let button = byName[systemKey],
                  let control = control(forProfileName: controlName)
            else { continue }

            mapping[control] = button

            // A stick direction is one half of an axis. The plugins only name
            // one half; the other lives in the system's axis list, so mirror
            // the mapping onto it.
            if let opposite = opposite(of: control),
               let partnerKey = partners[systemKey],
               let partnerButton = byName[partnerKey] {
                mapping[opposite] = partnerButton
            }
        }

        applyNameFallbacks(to: &mapping, buttons: buttons)

        // The profile predates the Menu and Options buttons every modern
        // controller has, so the plugins never name them. Point them at
        // whichever pad control carries the system's Start and its Select (or
        // Mode) — that differs per plugin, so go by the button name.
        if mapping[.menu] == nil,
           let start = mapping.values.first(where: { $0.id.lowercased().contains("start") }) {
            mapping[.menu] = start
        }
        if mapping[.options] == nil,
           let select = mapping.values.first(where: { button in
               let id = button.id.lowercased()
               return id.contains("select") || id.contains("mode")
           }) {
            mapping[.options] = select
        }

        return mapping
    }

    /// The controller profile the mapping file describes. It is the string the
    /// plugins use as the dictionary key; the SDK does not export a constant.
    private static let profileIdentifier = "OEControllerGCExtendedGamepadProfile"

    private static func profileMapping(in plugin: OESystemPlugin) -> [String: String] {
        guard let url = plugin.bundle.url(forResource: OEControllerMappingsFileName, withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let profile = plist[profileIdentifier] as? [String: String]
        else { return [:] }

        return profile
    }

    /// Each analog/digital axis as an unordered pair of the two system buttons
    /// it covers, so a mapping onto one half can be mirrored to the other.
    private static func axisPartners(in plugin: OESystemPlugin) -> [String: String] {
        guard let types = plugin.infoDictionary[OEControlTypesKey] as? [String: Any],
              let groups = types[OEAxisControlsKey] as? [[String]]
        else { return [:] }

        var partners: [String: String] = [:]
        for group in groups where group.count == 2 {
            partners[group[0]] = group[1]
            partners[group[1]] = group[0]
        }
        return partners
    }

    private static func control(forProfileName name: String) -> GamepadControl? {
        let suffix = name.hasPrefix(profileIdentifier)
            ? String(name.dropFirst(profileIdentifier.count))
            : name

        switch suffix {
        case "ButtonA": return .buttonA
        case "ButtonB": return .buttonB
        case "ButtonX": return .buttonX
        case "ButtonY": return .buttonY
        case "ButtonL1": return .leftShoulder
        case "ButtonR1": return .rightShoulder
        case "ButtonL2": return .leftTrigger
        case "ButtonR2": return .rightTrigger
        case "ButtonHome": return .home
        case "DPadUp": return .dpadUp
        case "DPadDown": return .dpadDown
        case "DPadLeft": return .dpadLeft
        case "DPadRight": return .dpadRight
        case "LeftAnalogUp": return .leftStickUp
        case "LeftAnalogDown": return .leftStickDown
        case "LeftAnalogLeft": return .leftStickLeft
        case "LeftAnalogRight": return .leftStickRight
        case "RightAnalogUp": return .rightStickUp
        case "RightAnalogDown": return .rightStickDown
        case "RightAnalogLeft": return .rightStickLeft
        case "RightAnalogRight": return .rightStickRight
        default: return nil
        }
    }

    private static func opposite(of control: GamepadControl) -> GamepadControl? {
        switch control {
        case .dpadUp: return .dpadDown
        case .dpadDown: return .dpadUp
        case .dpadLeft: return .dpadRight
        case .dpadRight: return .dpadLeft
        case .leftStickUp: return .leftStickDown
        case .leftStickDown: return .leftStickUp
        case .leftStickLeft: return .leftStickRight
        case .leftStickRight: return .leftStickLeft
        case .rightStickUp: return .rightStickDown
        case .rightStickDown: return .rightStickUp
        case .rightStickLeft: return .rightStickRight
        case .rightStickRight: return .rightStickLeft
        default: return nil
        }
    }

    /// Wire up obvious names for any control the profile did not cover, and
    /// let the left stick drive the same buttons as the d-pad on systems whose
    /// directions are plain buttons.
    private static func applyNameFallbacks(to mapping: inout [GamepadControl: ControllerButton], buttons: [ControllerButton]) {
        func assign(_ control: GamepadControl, _ suffixes: [String]) {
            guard mapping[control] == nil else { return }
            if let match = buttons.first(where: { button in
                let name = button.id.lowercased()
                return suffixes.contains { name.hasSuffix($0.lowercased()) }
            }) {
                mapping[control] = match
            }
        }

        assign(.buttonA, ["ButtonA"])
        assign(.buttonB, ["ButtonB"])
        assign(.buttonX, ["ButtonX"])
        assign(.buttonY, ["ButtonY"])
        assign(.leftShoulder, ["ButtonL", "ButtonL1"])
        assign(.rightShoulder, ["ButtonR", "ButtonR1"])
        assign(.leftTrigger, ["ButtonL2"])
        assign(.rightTrigger, ["ButtonR2"])
        assign(.home, ["ButtonStart"])
        assign(.leftTrigger, ["ButtonSelect"])
        assign(.dpadUp, ["ButtonUp", "DPadUp"])
        assign(.dpadDown, ["ButtonDown", "DPadDown"])
        assign(.dpadLeft, ["ButtonLeft", "DPadLeft"])
        assign(.dpadRight, ["ButtonRight", "DPadRight"])

        let sticks: [(GamepadControl, GamepadControl)] = [
            (.leftStickUp, .dpadUp),
            (.leftStickDown, .dpadDown),
            (.leftStickLeft, .dpadLeft),
            (.leftStickRight, .dpadRight),
        ]
        for (stick, direction) in sticks where mapping[stick] == nil {
            if let button = mapping[direction] {
                mapping[stick] = button
            }
        }
    }

    // MARK: - Directions

    private static func directions(
        _ mapping: [GamepadControl: ControllerButton],
        _ up: GamepadControl, _ down: GamepadControl,
        _ left: GamepadControl, _ right: GamepadControl
    ) -> DirectionalButtons {
        DirectionalButtons(
            up: mapping[up],
            down: mapping[down],
            left: mapping[left],
            right: mapping[right]
        )
    }

    private static func directions(fromNames buttons: [ControllerButton]) -> DirectionalButtons {
        func find(_ needle: String) -> ControllerButton? {
            buttons.first { $0.id.lowercased().hasSuffix(needle) }
        }
        return DirectionalButtons(
            up: find("up"),
            down: find("down"),
            left: find("left"),
            right: find("right")
        )
    }
}
