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

/// Where downloaded cover art lives, shared by the phone and the TV.
///
/// `CoverArtStore` used to own these paths, but its `imageURL(for:)` takes a
/// `Game` — the phone's library type, which the TV target does not compile.
/// The host serves art to the TV from an index record rather than a `Game`,
/// so the paths live here on plain strings and both sides build on them.
enum CoverArtPaths {

    /// The folder downloaded art is kept in.
    ///
    /// Application Support rather than Documents: this is the app's own cache,
    /// and Documents is the folder the user browses in the Files app.
    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CoverArt", isDirectory: true)
    }

    /// The image file for a game, whether or not it has been downloaded.
    /// The ROM's own file name keeps the folder readable.
    nonisolated static func imageURL(systemIdentifier: String, fileName: String) -> URL {
        directory
            .appendingPathComponent(systemIdentifier, isDirectory: true)
            .appendingPathComponent("\(fileName).png")
    }

    /// The marker left behind when a lookup found nothing. Its date is when
    /// that happened.
    nonisolated static func missMarkerURL(systemIdentifier: String, fileName: String) -> URL {
        imageURL(systemIdentifier: systemIdentifier, fileName: fileName).appendingPathExtension("missing")
    }
}
