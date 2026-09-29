// Copyright (c) 2026, Cassowary contributors
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the Cassowary contributors nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY Cassowary contributors ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL Cassowary contributors BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import SwiftUI
import UIKit

/// A game's poster in the TV library: its box art when there is some, and a
/// placeholder drawn for its system when there is not.
///
/// System icons are 16-point list glyphs, and blown up to poster size they
/// turned every game without art into the same blur. The placeholder uses
/// the system's controller picture instead, over a colour kept for that
/// system, so a shelf of games without art still reads at a glance.
struct TVGameArtwork: View {

    let art: UIImage?
    let system: SystemEntry?
    /// Used for the colour when the system is not installed on this TV.
    let systemIdentifier: String

    var body: some View {
        ZStack {
            if let art {
                Image(uiImage: art)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.45), Color(white: 0.08)],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)

            if let controller = system?.controllerImage {
                Image(uiImage: controller)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(30)
                    .shadow(color: .black.opacity(0.45), radius: 14, y: 10)
            } else {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 88))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    /// One steady colour per system. The hash is written out rather than
    /// taken from `hashValue`, which changes from launch to launch.
    private var tint: Color {
        var hash: UInt64 = 5381
        for byte in systemIdentifier.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.5, brightness: 0.5)
    }
}
