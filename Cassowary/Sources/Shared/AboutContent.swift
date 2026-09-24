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

import Foundation

/// The credits both apps show: who made the engine, the filters, the art
/// services, and each core.
///
/// The phone's About screen and the TV's Settings read from here, so adding a
/// core means one entry in this map rather than finding every screen.
enum AboutContent {

    /// Known core licenses by bundle identifier. Cores ported later get an
    /// entry here; anything unknown points at the core project.
    static let coreLicenses: [String: String] = [
        "org.openemu.Gambatte": "GPL-2.0-or-later (Gambatte-DMS)",
        "org.openemu.mGBA": "MPL-2.0 (mGBA)",
        "org.openemu.melonDS": "GPL-3.0-or-later (melonDS)",
        "org.openemu.VirtualC64": "GPL-3.0-or-later or MPL-2.0 (VirtualC64)",
        "org.openemu.VecXGL": "GPL-2.0-or-later (vecx / VecXGL)",
        // Non-commercial only: never charge for a build that includes these.
        "org.openemu.GenesisPlus": "Non-commercial (Genesis Plus GX)",
        "org.openemu.Picodrive": "Non-commercial (Picodrive)",
    ]

    /// One line for a core: its license, with its version when known.
    static func licenseLine(coreID: String, version: String) -> String {
        let license = coreLicenses[coreID] ?? "License: see the core project"
        if version.isEmpty {
            return license
        }
        return "Version \(version) · \(license)"
    }
}
