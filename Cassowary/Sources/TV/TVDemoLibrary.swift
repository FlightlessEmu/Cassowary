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

import Foundation
import OpenEmuBase
import OpenEmuSystem
import OpenEmuKit

/// A game that ships inside the app, so the TV has something to play before a
/// phone is paired.
struct TVDemoGame: Identifiable, Hashable {
    /// The resource name, which is what makes one demo different from another.
    let id: String
    let title: String
    let systemName: String

    /// A writable copy of the ROM. The engine writes save states next to the
    /// ROM, and files inside the app bundle cannot be written to, so the
    /// playable copy lives in Application Support.
    let url: URL
}

/// Finds the demo ROMs in the app bundle and prepares a writable copy of each.
enum TVDemoLibrary {

    /// Where the playable copies live. tvOS keeps very little permanent
    /// storage, but the demo ROM is 32 KB.
    private static var gamesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Demo Games", isDirectory: true)
    }

    static func load() -> [TVDemoGame] {
        let fileManager = FileManager.default
        let bundled = Bundle.main.urls(forResourcesWithExtension: "gb", subdirectory: nil) ?? []

        guard !bundled.isEmpty else { return [] }
        try? fileManager.createDirectory(at: gamesDirectory, withIntermediateDirectories: true)

        return bundled.compactMap { source -> TVDemoGame? in
            let title = source.deletingPathExtension().lastPathComponent
            let destination = gamesDirectory.appendingPathComponent(source.lastPathComponent)

            // Copy again when the bundled file changes, so a regenerated demo
            // ROM replaces an older copy instead of being ignored.
            let bundledSize = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            let copiedSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            if !fileManager.fileExists(atPath: destination.path) || bundledSize != copiedSize {
                try? fileManager.removeItem(at: destination)
                do {
                    try fileManager.copyItem(at: source, to: destination)
                } catch {
                    NSLog("[Cassowary] could not copy the demo game: %@", error.localizedDescription)
                    return nil
                }
            }

            return TVDemoGame(
                id: title,
                title: title,
                systemName: systemName(forExtension: source.pathExtension),
                url: destination
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The name of the system plugin that claims this file extension.
    private static func systemName(forExtension fileExtension: String) -> String {
        systemPlugin(forExtension: fileExtension)?.systemName ?? "Unknown System"
    }

    /// The system plugin that claims this file extension, resolved the way the
    /// game session resolves it.
    static func systemPlugin(forExtension fileExtension: String) -> OESystemPlugin? {
        let wanted = fileExtension.lowercased()

        return OESystemPlugin.allPlugins.first { plugin in
            // A plugin whose controller will not load would trap on any
            // accessor, so skip it.
            guard plugin.controller != nil else { return false }
            return plugin.supportedTypeExtensions.map({ $0.lowercased() }).contains(wanted)
        }
    }
}
