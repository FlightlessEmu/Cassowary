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

/// The visual theme for the on-screen controls, picked in Settings → Controls.
enum ButtonTheme: String, CaseIterable, Identifiable {
    case glass
    case neon
    case retro

    var id: String { rawValue }

    var label: String {
        switch self {
        case .glass: return "Glass"
        case .neon: return "Neon"
        case .retro: return "Retro"
        }
    }

    var blurb: String {
        switch self {
        case .glass: return "Translucent buttons that sit lightly over the game."
        case .neon: return "Dark pads with a colored glow when pressed."
        case .retro: return "Solid clicky buttons with a hard shadow."
        }
    }

    // MARK: - Colors

    /// Unpressed directional fill (d-pad arms, stick base, cross).
    func padBase() -> Color {
        switch self {
        case .glass: return .white.opacity(0.16)
        case .neon: return .black.opacity(0.55)
        case .retro: return Color(red: 0.24, green: 0.24, blue: 0.28)
        }
    }

    /// Pressed directional fill.
    func padActive() -> Color {
        switch self {
        case .glass: return .white.opacity(0.35)
        case .neon: return .cyan.opacity(0.5)
        case .retro: return Color(red: 0.36, green: 0.36, blue: 0.42)
        }
    }

    /// Unpressed face-button fill.
    func faceBase() -> Color {
        switch self {
        case .glass: return .white.opacity(0.22)
        case .neon: return .black.opacity(0.55)
        case .retro: return Color(red: 0.62, green: 0.16, blue: 0.22)
        }
    }

    /// Pressed face-button fill.
    func faceActive() -> Color {
        switch self {
        case .glass: return .white.opacity(0.45)
        case .neon: return .pink.opacity(0.55)
        case .retro: return Color(red: 0.78, green: 0.24, blue: 0.30)
        }
    }

    /// Fill for the raised arm caps of the split direction pad. Slightly
    /// lighter than `padBase`, so the caps read as buttons sitting on the pad
    /// without needing an outline of their own.
    func padCap() -> Color {
        switch self {
        case .glass: return .white.opacity(0.26)
        case .neon: return .black.opacity(0.4)
        case .retro: return Color(red: 0.34, green: 0.34, blue: 0.40)
        }
    }

    /// Edge stroke drawn on pads and buttons. Clear when the theme has none.
    func edge() -> Color {
        switch self {
        case .glass: return .clear
        case .neon: return .cyan.opacity(0.35)
        case .retro: return .black.opacity(0.35)
        }
    }

    /// Glow shadow while pressed. Clear when the theme has none.
    func pressGlow() -> Color {
        switch self {
        case .glass: return .clear
        case .neon: return .cyan.opacity(0.8)
        case .retro: return .clear
        }
    }

    // MARK: - Press animation

    /// How much a button shrinks while held. Retro stays full-size and
    /// travels down instead (see `pressOffsetY`).
    var pressScale: CGFloat {
        switch self {
        case .glass, .neon: return 0.9
        case .retro: return 1.0
        }
    }

    /// How far a button travels down while held. Only Retro moves.
    var pressOffsetY: CGFloat {
        switch self {
        case .glass, .neon: return 0
        case .retro: return 2
        }
    }

    /// Resting drop-shadow depth. Only Retro casts one.
    var restShadowY: CGFloat {
        switch self {
        case .glass, .neon: return 0
        case .retro: return 3
        }
    }
}
