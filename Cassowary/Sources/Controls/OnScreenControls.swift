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
///
/// The pad follows the controls each system plugin describes: a three-button
/// console gets a row of three, a four-button one a square, and the system
/// controls — Start, Select, Mode — stay with the buttons on the right, drawn
/// as symbols.
struct OnScreenControls: View {

    let layout: ControllerLayout
    let session: GameSession

    @AppStorage("cassowary.padStyle") private var styleRaw: String = DPadStyle.buttons.rawValue
    @AppStorage("cassowary.buttonTheme") private var themeRaw: String = ButtonTheme.glass.rawValue

    /// System controls are drawn a little smaller than the face buttons, the
    /// way they are on a real controller.
    private static let systemScale: CGFloat = 0.8
    private static let systemSpacing: CGFloat = 8

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
            let buttonSize = Self.buttonSize(in: geometry.size)

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

    /// The size of one on-screen button.
    ///
    /// It follows the shorter side of the screen, so turning the device — or
    /// unfolding one — keeps the controls the same size instead of making
    /// them jump. The floor keeps them a comfortable touch target; the cap
    /// stops a row of buttons from swallowing a short landscape screen.
    private static func buttonSize(in size: CGSize) -> CGFloat {
        min(max(min(size.width, size.height) * 0.075, 46), 64)
    }

    /// The on-screen pads report through this, so every touch press buzzes the
    /// phone at the strength picked in Settings → Controls. A physical
    /// controller or keyboard goes straight to the session and stays silent.
    private var pressHandler: any ControlPressHandler {
        HapticPressHandler(target: session)
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
                SplitButtonsPad(up: buttons.up, down: buttons.down, left: buttons.left, right: buttons.right, handler: pressHandler, theme: theme, buttonSize: buttonSize)
            case .dpad:
                ClassicDPadView(up: buttons.up, down: buttons.down, left: buttons.left, right: buttons.right, handler: pressHandler, theme: theme, size: buttonSize * 3)
            case .stick:
                ThumbstickView(up: buttons.up, down: buttons.down, left: buttons.left, right: buttons.right, handler: pressHandler, theme: theme, diameter: buttonSize * 2.8)
                    .frame(width: buttonSize * 3, height: buttonSize * 3)
            }
        }
    }

    // MARK: - Which buttons are which

    /// The directions the pad already draws, which the action cluster leaves
    /// out.
    ///
    /// A real right stick is not drawn either, so its directions are left out
    /// too — but a system whose "right stick" is a set of buttons, like the
    /// N64's C buttons, keeps them: those are face buttons on that pad, and
    /// only the analog ones belong to a stick.
    private var directionalIDs: Set<String> {
        var ids = layout.dPad.ids.union(layout.leftStick.ids)
        for button in layout.rightStick.all.compactMap({ $0 }) where button.isAnalog {
            ids.insert(button.id)
        }
        return ids
    }

    /// The system controls the plugin describes, in its own order.
    private var systemButtons: [ControllerButton] {
        layout.allButtons.filter { !directionalIDs.contains($0.id) && ButtonGlyph.isSystem($0) }
    }

    /// The buttons the action cluster shows, kept in the groups the plugin put
    /// them in. System controls are left out here: they get their own block,
    /// in the same cluster.
    private func actionGroups() -> [[ControllerButton]] {
        layout.groups
            .map { group in
                group.filter { button in
                    !directionalIDs.contains(button.id) && !ButtonGlyph.isSystem(button)
                }
            }
            .filter { !$0.isEmpty }
    }

    // MARK: - Action buttons

    /// Everything that is not a direction: A/B, L/R, and so on — with the
    /// system controls at the top of the cluster, where they stay over the
    /// black bars in landscape rather than over the game.
    private func actionPad(buttonSize: CGFloat) -> some View {
        let groups = actionGroups()

        return VStack(alignment: .trailing, spacing: 10) {
            if !systemButtons.isEmpty {
                buttonBlock(systemButtons, buttonSize: buttonSize * Self.systemScale, spacing: Self.systemSpacing)
            }

            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                buttonBlock(group, buttonSize: buttonSize)
            }
        }
    }

    /// One plugin group: a row for up to three buttons, a 2×2 grid for four
    /// or more. That keeps a three-button console (Genesis) in one row and a
    /// four-button one (SNES) in a square, the way their pads are.
    private func buttonBlock(_ buttons: [ControllerButton], buttonSize: CGFloat, spacing: CGFloat = 10) -> some View {
        let rows: [[ControllerButton]] = buttons.count <= 3
            ? [buttons]
            : stride(from: 0, to: buttons.count, by: 2).map {
                Array(buttons[$0 ..< min($0 + 2, buttons.count)])
            }

        return VStack(spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: spacing) {
                    ForEach(row) { button in
                        FaceButtonView(button: button, handler: pressHandler, theme: theme, size: buttonSize)
                    }
                }
            }
        }
    }

}
