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

/// The controller shell the Console theme draws behind the pad, in the
/// console's own colors. Everything is drawn from shapes and gradients, so it
/// is sharp at any size and needs no artwork.
///
/// In portrait it is one wide shell across the bottom of the screen, like
/// holding the real controller. In landscape the middle is the game, so each
/// hand gets its own grip instead.
struct ControllerBodyView: View {

    let style: ControllerSkin.Body
    /// Only the corners that face the game are rounded; the rest run off the
    /// edge of the screen.
    var radii = RectangleCornerRadii(topLeading: 36, topTrailing: 36)
    /// The colored dots sit in the middle of the wide portrait shell.
    var showsDots = true

    private var shape: some InsettableShape {
        UnevenRoundedRectangle(cornerRadii: radii, style: .continuous)
    }

    var body: some View {
        shape
            .fill(LinearGradient(colors: [style.top, style.bottom], startPoint: .top, endPoint: .bottom))
            // Light along the top edge, the way it catches a molded shell.
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.0)], startPoint: .top, endPoint: .center),
                    lineWidth: 1.5
                )
            }
            .overlay(alignment: .top) {
                decorations
            }
            .shadow(color: .black.opacity(0.5), radius: 10, y: -2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var decorations: some View {
        VStack(spacing: 10) {
            if let stripe = style.stripe {
                Capsule()
                    .fill(stripe)
                    .frame(height: 3)
                    .padding(.horizontal, showsDots ? 48 : 26)
            }
            if !style.dots.isEmpty, showsDots {
                HStack(spacing: 7) {
                    ForEach(Array(style.dots.enumerated()), id: \.offset) { _, color in
                        Circle()
                            .fill(color)
                            .frame(width: 8, height: 8)
                            .overlay { Circle().stroke(.black.opacity(0.2), lineWidth: 0.5) }
                    }
                }
            }
        }
        .padding(.top, 14)
    }
}

/// The recessed area a d-pad or a set of buttons sits in: darker than the
/// shell, shaded at the top and lit at the bottom, so it reads as sunk in.
struct ControlWellView<S: InsettableShape>: View {

    let shape: S
    let color: Color

    var body: some View {
        shape
            .fill(color)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [.black.opacity(0.35), .white.opacity(0.18)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 2
                )
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
