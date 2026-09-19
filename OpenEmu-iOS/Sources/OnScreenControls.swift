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
/// the face buttons on the right, and anything else along the bottom. That
/// keeps it correct for every system without a per-system view.
struct OnScreenControls: View {

    let layout: ControllerLayout
    let session: GameSession

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .bottom) {
                directionalPad
                Spacer(minLength: 0)
                actionPad
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    // MARK: - D-pad

    /// The d-pad is the first group that looks directional. Systems that have
    /// no d-pad (a paddle, say) fall back to plain buttons.
    private var directionalPad: some View {
        let buttons = directionalButtons
        return VStack(spacing: 4) {
            HStack(spacing: 4) {
                padButton(buttons.up)
                padButton(buttons.down)
            }
            HStack(spacing: 4) {
                padButton(buttons.left)
                padButton(buttons.right)
            }
        }
    }

    private var directionalButtons: (up: ControllerButton?, down: ControllerButton?, left: ControllerButton?, right: ControllerButton?) {
        let all = layout.allButtons
        func find(_ needles: [String]) -> ControllerButton? {
            all.first { button in
                let name = button.id.lowercased()
                return needles.contains { name.contains($0) }
            }
        }
        return (
            find(["up"]),
            find(["down"]),
            find(["left"]),
            find(["right"])
        )
    }

    private func padButton(_ button: ControllerButton?) -> some View {
        Group {
            if let button {
                HoldableButton(button: button, session: session) {
                    Text(button.label)
                        .font(.caption)
                        .frame(width: 56, height: 56)
                        .background(.ultraThinMaterial, in: .rect(cornerRadius: 10))
                }
            } else {
                Color.clear.frame(width: 56, height: 56)
            }
        }
    }

    // MARK: - Action buttons

    /// Everything that is not a direction: A/B, Start/Select, and so on.
    private var actionPad: some View {
        let buttons = actionButtons
        return VStack(alignment: .trailing, spacing: 12) {
            ForEach(Array(buttons.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 12) {
                    ForEach(row) { button in
                        HoldableButton(button: button, session: session) {
                            Text(button.label)
                                .font(.caption.bold())
                                .frame(width: 56, height: 56)
                                .background(.ultraThinMaterial, in: .circle)
                        }
                    }
                }
            }
        }
    }

    /// Group the non-directional buttons into rows of at most three.
    private var actionButtons: [[ControllerButton]] {
        let directional = directionalButtons
        let directionalIDs = Set([directional.up, directional.down, directional.left, directional.right]
            .compactMap { $0?.id })

        let rest = layout.allButtons.filter { !directionalIDs.contains($0.id) }
        guard !rest.isEmpty else { return [] }

        // Two per row reads well for the common A/B + Start/Select layouts.
        return stride(from: 0, to: rest.count, by: 2).map {
            Array(rest[$0 ..< min($0 + 2, rest.count)])
        }
    }
}

/// A button that presses on touch down and releases on touch up.
///
/// Games read the button state every frame, so the press and release have to be
/// reported exactly, not just on tap.
private struct HoldableButton<Label: View>: View {

    let button: ControllerButton
    let session: GameSession
    @ViewBuilder let label: () -> Label

    @State private var isPressed = false

    var body: some View {
        label()
            .opacity(isPressed ? 0.5 : 1)
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
    }
}
