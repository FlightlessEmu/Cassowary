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
    var systemKey: OESystemKey {
        OESystemKey(key: keyIndex, player: 0, isAnalogic: isAnalog)
    }
}

/// The buttons for a system, read from its plugin.
///
/// Every system plugin ships an `OEControlListKey` describing its controls —
/// the same list the macOS app uses to lay out its keyboard preferences.
/// Reading it here means the on-screen controls match each system without any
/// per-system code: Game Boy gets a d-pad and two buttons, Genesis gets three,
/// and so on.
struct ControllerLayout {

    /// Buttons grouped the way the plugin groups them: a d-pad, then face
    /// buttons, then start/select.
    let groups: [[ControllerButton]]

    var allButtons: [ControllerButton] { groups.flatMap { $0 } }

    /// Whether this system has controls that can be shown as buttons.
    var hasButtons: Bool { !allButtons.isEmpty }

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
    }
}
