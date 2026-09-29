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

/// The keys and defaults SwanStationGameCore reads. The core runs in this
/// process and reads the same user defaults, so these must match
/// `cores/SwanStation/SwanStationGameCore.mm`.
enum SwanStationSettings {
    static let coreIdentifier = "org.openemu.SwanStation"

    static let metalRendererKey = "SwanStationMetalRenderer"
    static let resolutionScaleKey = "SwanStation.resolutionScale"
    static let trueColorKey = "SwanStation.trueColor"
    static let textureFilterKey = "SwanStation.textureFilter"
    static let pgxpKey = "SwanStation.pgxp"
    static let widescreenKey = "SwanStation.widescreen"

    static let defaultResolutionScale = 3
    static let defaultTrueColor = true
    static let defaultPGXP = true

    /// The internal resolutions offered, with roughly what each draws at.
    static let resolutionScales: [(scale: Int, title: String)] = [
        (1, "1x Native (240p)"),
        (2, "2x (480p)"),
        (3, "3x (720p)"),
        (4, "4x (960p)"),
        (5, "5x (1080p)"),
        (6, "6x (1440p)"),
        (8, "8x (4K)"),
    ]

    /// The texture filters the Metal renderer has been checked with.
    static let textureFilters: [(value: String, title: String)] = [
        ("Nearest", "Off"),
        ("Bilinear", "Bilinear"),
        ("JINC2", "JINC2"),
        ("xBR", "xBR"),
    ]
}

/// The PlayStation renderer settings, for SwanStation's system page.
///
/// Everything but the renderer itself applies to a running game on its next
/// frame; switching between Metal and software takes a restart.
struct SwanStationSettingsSection: View {

    @AppStorage(SwanStationSettings.metalRendererKey) private var metalRenderer = true
    @AppStorage(SwanStationSettings.resolutionScaleKey) private var resolutionScale = SwanStationSettings.defaultResolutionScale
    @AppStorage(SwanStationSettings.trueColorKey) private var trueColor = SwanStationSettings.defaultTrueColor
    @AppStorage(SwanStationSettings.textureFilterKey) private var textureFilter = "Nearest"
    @AppStorage(SwanStationSettings.pgxpKey) private var pgxp = SwanStationSettings.defaultPGXP
    @AppStorage(SwanStationSettings.widescreenKey) private var widescreen = false

    var body: some View {
        Section {
            Picker("Renderer", selection: $metalRenderer) {
                Text("Metal").tag(true)
                Text("Software").tag(false)
            }

            if metalRenderer {
                Picker("Internal Resolution", selection: $resolutionScale) {
                    ForEach(SwanStationSettings.resolutionScales, id: \.scale) { option in
                        Text(option.title).tag(option.scale)
                    }
                }
                Picker("Texture Filtering", selection: $textureFilter) {
                    ForEach(SwanStationSettings.textureFilters, id: \.value) { option in
                        Text(option.title).tag(option.value)
                    }
                }
                Toggle("True Color", isOn: $trueColor)
                Toggle("Geometry Correction", isOn: $pgxp)
                Toggle("Widescreen", isOn: $widescreen)
            }
        } header: {
            Text("SwanStation Renderer")
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        guard metalRenderer else {
            return "The software renderer draws at the console's own resolution, exactly as the hardware did. The renderer changes the next time a game starts."
        }
        return "Higher resolutions draw 3D sharper. True Color removes the console's dithering. Geometry Correction (PGXP) stops polygons wobbling and textures warping. Widescreen draws the sides of the picture too, which some games leave empty. Changes apply to a running game straight away; the renderer changes the next time a game starts."
    }
}
