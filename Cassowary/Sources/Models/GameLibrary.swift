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
import UIKit
import OpenEmuBase
import OpenEmuSystem
import OpenEmuKit

/// A game the user has added to their library.
struct Game: Identifiable, Hashable {
    let id: URL
    let url: URL
    let title: String
    let system: SystemInfo?

    var systemName: String? { system?.name }

    init(url: URL, system: SystemInfo? = nil) {
        self.id = url
        self.url = url
        self.title = url.deletingPathExtension().lastPathComponent
        self.system = system
    }
}

/// What we know about a system, for display.
struct SystemInfo: Hashable {
    let identifier: String
    let name: String
    let icon: UIImage?

    init(plugin: OESystemPlugin) {
        identifier = plugin.systemIdentifier
        name = plugin.systemName
        icon = plugin.systemIcon as? UIImage
    }
}

/// What happened when files were handed to `GameLibrary.add(contentsOf:)`.
///
/// Adding games is normally silent — they simply appear in the grid — so this
/// exists to explain a drop that was not taken in full.
struct ImportSummary: Sendable {
    /// File names copied into the library.
    var added: [String] = []
    /// File names already in the library; nothing was copied.
    var alreadyInLibrary: [String] = []
    /// File names no installed system has an extension for, and folders.
    var unsupported: [String] = []
    /// File names that could not be read or copied.
    var failed: [String] = []
}

/// Finds games on disk and remembers which ones the user has added.
///
/// The macOS app keeps a Core Data library with artwork, play counts and so on.
/// This is a deliberately small stand-in: it scans the app's Documents folder,
/// which is where files land when the user drags them in.
@MainActor
final class GameLibrary: ObservableObject {

    @Published private(set) var games: [Game] = []

    /// Where the user's ROMs live. Visible in the Files app because the app
    /// declares `UIFileSharingEnabled`.
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// The system plugin for each installed system, keyed by file extension.
    ///
    /// Built on each refresh rather than cached: plugins are discovered by
    /// scanning the bundle, which only happens once the app has registered the
    /// plugin classes.
    private static func systemsByExtension() -> [String: SystemInfo] {
        var map: [String: SystemInfo] = [:]
        for plugin in OESystemPlugin.allPlugins {
            // A plugin whose principal class will not load has no controller,
            // and every accessor on it would trap. One bad plugin should not
            // take the whole library down.
            guard plugin.controller != nil else {
                NSLog("[Cassowary] ignoring system plugin with no controller: %@", plugin.url.lastPathComponent)
                continue
            }

            let info = SystemInfo(plugin: plugin)
            for ext in plugin.supportedTypeExtensions {
                // The first plugin to claim an extension wins, so a more
                // specific plugin can be given priority by installing it first.
                if map[ext.lowercased()] == nil {
                    map[ext.lowercased()] = info
                }
            }
        }
        return map
    }

    func refresh() {
        let systems = Self.systemsByExtension()
        let fm = FileManager.default

        let found = (try? fm.contentsOfDirectory(
            at: Self.documentsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        games = found
            .compactMap { url -> Game? in
                guard let system = systems[url.pathExtension.lowercased()] else { return nil }
                return Game(url: url, system: system)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func delete(_ game: Game) {
        try? FileManager.default.removeItem(at: game.url)
        refresh()
    }

    /// Copy files the user dropped onto the library into Documents, then
    /// rescan.
    ///
    /// The copies happen away from the main actor: a disc image can be
    /// hundreds of megabytes, and the library should not lock up while one
    /// is copied.
    func add(contentsOf urls: [URL]) async -> ImportSummary {
        let supported = Set(Self.systemsByExtension().keys)
        let documents = Self.documentsDirectory

        let summary = await Task.detached(priority: .userInitiated) {
            Self.copy(urls, into: documents, supportedExtensions: supported)
        }.value

        refresh()
        return summary
    }

    /// The file work behind `add(contentsOf:)`, off the main actor.
    ///
    /// Dropped files sit outside the app's sandbox on the Mac, so access is
    /// held for the copy and released straight after. A name already in
    /// Documents is skipped rather than overwritten: it may be a different
    /// game with the same name, and save states live beside the ROM.
    private nonisolated static func copy(
        _ urls: [URL],
        into documents: URL,
        supportedExtensions: Set<String>
    ) -> ImportSummary {
        let fm = FileManager.default
        var summary = ImportSummary()

        for url in urls {
            let name = url.lastPathComponent

            // Start access before touching the file: outside the sandbox even
            // asking whether it exists fails without it.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                summary.failed.append(name)
                continue
            }
            guard !isDirectory.boolValue else {
                // Folders are not games; only files are copied.
                summary.unsupported.append(name)
                continue
            }
            guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
                summary.unsupported.append(name)
                continue
            }

            let destination = documents.appendingPathComponent(name)
            guard !fm.fileExists(atPath: destination.path) else {
                summary.alreadyInLibrary.append(name)
                continue
            }

            do {
                try fm.copyItem(at: url, to: destination)
                summary.added.append(name)
            } catch {
                NSLog("[Cassowary] could not add \(name): \(error.localizedDescription)")
                summary.failed.append(name)
            }
        }

        return summary
    }
}
