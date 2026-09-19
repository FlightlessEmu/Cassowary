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
/// The layout is whatever the system plugin described: a d-pad on the left,
/// the face buttons on the right, and anything else in between. That keeps it
/// correct for every system without a per-system view.
struct OnScreenControls: View {

    let layout: ControllerLayout
    let session: GameSession

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

    /// The directional buttons, laid out as a cross.
    ///
    /// A system with no d-pad simply produces no cross; the buttons it does
    /// have show up on the right instead.
    private func directionalPad(buttonSize: CGFloat) -> some View {
        let buttons = directionalButtons

        return ZStack {
            if buttons.isEmpty {
                Color.clear.frame(width: buttonSize * 3, height: buttonSize * 3)
            } else {
                VStack(spacing: 2) {
                    directionalButton(buttons.up, symbol: "chevron.up", size: buttonSize)
                    HStack(spacing: 2) {
                        directionalButton(buttons.left, symbol: "chevron.left", size: buttonSize)
                        directionalButton(buttons.right, symbol: "chevron.right", size: buttonSize)
                    }
                    directionalButton(buttons.down, symbol: "chevron.down", size: buttonSize)
                }
            }
        }
    }

    private func directionalButton(_ button: ControllerButton?, symbol: String, size: CGFloat) -> some View {
        Group {
            if let button {
                HoldableButton(button: button, session: session) { pressed in
                    ControlPadShape()
                        .fill(padFill(pressed: pressed))
                        .frame(width: size, height: size)
                        .overlay {
                            Image(systemName: symbol)
                                .font(.system(size: size * 0.32, weight: .semibold))
                                .foregroundStyle(.white.opacity(pressed ? 1 : 0.85))
                        }
                }
            } else {
                Color.clear.frame(width: size, height: size)
            }
        }
    }

    private var directionalButtons: DirectionalButtons {
        let all = layout.allButtons

        // Match on the button's identifier, which plugins name after the
        // direction, e.g. OEGBButtonUp or OESMSButtonLeft.
        func find(_ needles: [String]) -> ControllerButton? {
            all.first { button in
                let name = button.id.lowercased()
                return needles.contains { name.hasSuffix($0) }
            }
        }

        return DirectionalButtons(
            up: find(["up"]),
            down: find(["down"]),
            left: find(["left"]),
            right: find(["right"])
        )
    }

    // MARK: - Action buttons

    /// Everything that is not a direction: A/B, Start/Select, and so on.
    private func actionPad(buttonSize: CGFloat) -> some View {
        let rows = actionButtons

        return VStack(alignment: .trailing, spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    ForEach(row) { button in
                        HoldableButton(button: button, session: session) { pressed in
                            Circle()
                                .fill(actionFill(pressed: pressed))
                                .frame(width: buttonSize, height: buttonSize)
                                .overlay {
                                    Text(button.label)
                                        .font(.system(size: buttonSize * 0.28, weight: .semibold))
                                        .foregroundStyle(.white.opacity(pressed ? 1 : 0.9))
                                }
                        }
                    }
                }
            }
        }
    }

    /// Group the non-directional buttons into rows of at most two.
    private var actionButtons: [[ControllerButton]] {
        let directional = directionalButtons
        let directionalIDs = Set(directional.all.compactMap { $0?.id })

        let rest = layout.allButtons.filter { !directionalIDs.contains($0.id) }
        guard !rest.isEmpty else { return [] }

        return stride(from: 0, to: rest.count, by: 2).map {
            Array(rest[$0 ..< min($0 + 2, rest.count)])
        }
    }

    // MARK: - Styling

    private func padFill(pressed: Bool) -> Color {
        pressed ? .white.opacity(0.35) : .white.opacity(0.16)
    }

    private func actionFill(pressed: Bool) -> Color {
        pressed ? .white.opacity(0.45) : .white.opacity(0.22)
    }
}

/// The directional buttons a system has, if any.
private struct DirectionalButtons {
    let up: ControllerButton?
    let down: ControllerButton?
    let left: ControllerButton?
    let right: ControllerButton?

    var all: [ControllerButton?] { [up, down, left, right] }
    var isEmpty: Bool { all.allSatisfy { $0 == nil } }
}

/// A cross shape, used for the d-pad arms.
private struct ControlPadShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: rect.width * 0.28, style: .continuous)
    }
}

/// A button that presses on touch down and releases on touch up.
///
/// Games read the button state every frame, so the press and release have to be
/// reported exactly, not just on tap. The drag gesture with no minimum distance
/// is what gives us the touch-down callback.
private struct HoldableButton<Label: View>: View {

    let button: ControllerButton
    let session: GameSession
    @ViewBuilder let label: (Bool) -> Label

    @State private var isPressed = false

    var body: some View {
        label(isPressed)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        session.press(button.systemKey)
                    }
                    .onEnded { _ in
                        isPressed = false
                        session.release(button.systemKey)
                    }
            )
            .accessibilityLabel(button.label)
            .accessibilityAddTraits(.isButton)
    }
}
