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

/// The on-screen gamepad.
///
/// The directional style (Settings → Controls) picks one of three pads; the
/// face buttons on the right stay the same. That keeps every style correct
/// for every system without per-system views.
struct OnScreenControls: View {

    let layout: ControllerLayout
    let session: GameSession

    @AppStorage("cassowary.padStyle") private var styleRaw: String = DPadStyle.buttons.rawValue
    @AppStorage("cassowary.buttonTheme") private var themeRaw: String = ButtonTheme.glass.rawValue

    private var style: DPadStyle {
        DPadStyle(rawValue: styleRaw) ?? .buttons
    }

    private var theme: ButtonTheme {
        ButtonTheme(rawValue: themeRaw) ?? .glass
    }

    var body: some View {
        GeometryReader { geometry in
            // Controls scale with the screen so they stay reachable on a small
            // phone without covering the game on a large one.
            let buttonSize = min(max(geometry.size.width * 0.075, 46), 64)

            HStack(alignment: .bottom, spacing: 0) {
                directionalPad(buttonSize: buttonSize)
                Spacer(minLength: 12)
                actionPad(buttonSize: buttonSize)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    // MARK: - D-pad

    /// The directional control, in the style the user picked.
    ///
    /// A system with no d-pad shows nothing here either way; the buttons it
    /// does have show up on the right instead.
    @ViewBuilder
    private func directionalPad(buttonSize: CGFloat) -> some View {
        // The d-pad styles use the plugin's d-pad buttons; the thumbstick style
        // uses the plugin's stick buttons when the system has them, so on N64
        // it drives the analog inputs. Both sets come from the same layout a
        // physical controller uses.
        let buttons = style == .stick ? layout.leftStick : layout.dPad

        if buttons.isEmpty {
            Color.clear.frame(width: buttonSize * 3, height: buttonSize * 3)
        } else {
            switch style {
            case .buttons:
                SplitButtonsPad(up: buttons.up, down: buttons.down, left: buttons.left, right: buttons.right, handler: session, theme: theme, buttonSize: buttonSize)
            case .dpad:
                ClassicDPadView(up: buttons.up, down: buttons.down, left: buttons.left, right: buttons.right, handler: session, theme: theme, size: buttonSize * 3)
            case .stick:
                ThumbstickView(up: buttons.up, down: buttons.down, left: buttons.left, right: buttons.right, handler: session, theme: theme, diameter: buttonSize * 2.8)
                    .frame(width: buttonSize * 3, height: buttonSize * 3)
            }
        }
    }

    // MARK: - Action buttons

    /// Everything that is not a direction: A/B, Start/Select, and so on.
    private func actionPad(buttonSize: CGFloat) -> some View {
        let rows = actionButtons

        return VStack(alignment: .trailing, spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    ForEach(row) { button in
                        FaceButtonView(button: button, handler: session, theme: theme, size: buttonSize)
                    }
                }
            }
        }
    }

    /// Group the non-directional buttons into rows of at most two.
    private var actionButtons: [[ControllerButton]] {
        // Anything the directional controls already cover is not repeated as a
        // button: the d-pad, and for a system with an analog stick its
        // directions too.
        let directionalIDs = layout.dPad.ids.union(layout.leftStick.ids)

        let rest = layout.allButtons.filter { !directionalIDs.contains($0.id) }
        guard !rest.isEmpty else { return [] }

        return stride(from: 0, to: rest.count, by: 2).map {
            Array(rest[$0 ..< min($0 + 2, rest.count)])
        }
    }

}
