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

    /// The file extensions the system's plugin claims.
    let extensions: [String]

    init(plugin: OESystemPlugin) {
        identifier = plugin.systemIdentifier
        name = plugin.systemName
        icon = plugin.systemIcon as? UIImage
        extensions = plugin.supportedTypeExtensions
    }
}

/// What happened when files were handed to `GameLibrary.add(contentsOf:)`.
///
/// Adding games is normally silent — they simply appear in the grid — so this
/// exists to explain a drop that was not taken in full.
struct ImportSummary: Sendable {
    /// File names copied into the library and filed under a system.
    var added: [String] = []
    /// Files copied into the library that still need a system. An extension
    /// claimed by more than one installed system, claimed by none, or hiding
    /// its contents — an archive — cannot be placed on its own, so the person
    /// adding the file is asked.
    var needsSystem: [URL] = []
    /// File names already in the library; nothing was copied.
    var alreadyInLibrary: [String] = []
    /// Folders, which are not games.
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

    /// Every installed system whose plugin controller loads.
    ///
    /// Built on each refresh rather than cached: plugins are discovered by
    /// scanning the bundle, which only happens once the app has registered the
    /// plugin classes. A plugin whose principal class will not load has no
    /// controller, and every accessor on it would trap, so it is skipped: one
    /// bad plugin should not take the whole library down.
    private static func installedSystems() -> [SystemInfo] {
        OESystemPlugin.allPlugins.compactMap { plugin in
            guard plugin.controller != nil else {
                NSLog("[Cassowary] ignoring system plugin with no controller: %@", plugin.url.lastPathComponent)
                return nil
            }
            return SystemInfo(plugin: plugin)
        }
    }

    /// The systems claiming each file extension.
    ///
    /// An extension can be claimed by several systems — `.bin` alone is
    /// claimed by a handful — so every claimant is kept, not one winner.
    private static func systemsByExtension() -> [String: [SystemInfo]] {
        var map: [String: [SystemInfo]] = [:]
        for system in installedSystems() {
            for ext in system.extensions {
                let key = ext.lowercased()
                // A plugin can list an extension more than once; one entry is
                // enough.
                if map[key]?.contains(where: { $0.identifier == system.identifier }) != true {
                    map[key, default: []].append(system)
                }
            }
        }
        return map
    }

    /// The systems to offer when the user has to say where a file goes.
    private static func systemsByIdentifier() -> [String: SystemInfo] {
        var map: [String: SystemInfo] = [:]
        for system in installedSystems() {
            map[system.identifier] = system
        }
        return map
    }

    /// Extensions whose contents the extension itself says nothing about.
    ///
    /// An archive can hold a ROM for any system, so even when one installed
    /// system claims the extension — `.zip` is Arcade's — the file is asked
    /// about rather than filed under a guess.
    private static let archiveExtensions: Set<String> = ["zip", "7z"]

    /// The extensions only one installed system claims, so a file with one can
    /// be filed without asking. Systems, not plugin entries: an extension
    /// listed twice by one plugin is still that one system's.
    private static func automaticExtensions() -> Set<String> {
        var claimants: [String: Set<String>] = [:]
        for system in installedSystems() {
            for ext in system.extensions {
                claimants[ext.lowercased(), default: []].insert(system.identifier)
            }
        }
        return Set(claimants.filter {
            $0.value.count == 1 && !archiveExtensions.contains($0.key)
        }.keys)
    }

    /// The system the user picked for files the app could not place, keyed by
    /// file name. ROMs live flat in Documents, so the name identifies one.
    private static let assignedSystemsKey = "cassowary.assignedSystems"

    private static func assignedSystemIdentifiers() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: assignedSystemsKey) as? [String: String] ?? [:]
    }

    func refresh() {
        let byExtension = Self.systemsByExtension()
        let byIdentifier = Self.systemsByIdentifier()
        let assigned = Self.assignedSystemIdentifiers()
        let fm = FileManager.default

        let found = (try? fm.contentsOfDirectory(
            at: Self.documentsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        games = found
            .compactMap { url -> Game? in
                guard let system = Self.system(
                    for: url,
                    assigned: assigned,
                    byExtension: byExtension,
                    byIdentifier: byIdentifier
                ) else { return nil }
                return Game(url: url, system: system)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The system a file in Documents belongs to, if one can be worked out.
    ///
    /// A system the user picked by hand wins. Otherwise the file's extension
    /// decides: `.gb` is a Game Boy game and nothing else, while `.bin` is
    /// several things at once — the first claimant keeps it, as it always did,
    /// and imports ask rather than guessing.
    private static func system(
        for url: URL,
        assigned: [String: String],
        byExtension: [String: [SystemInfo]],
        byIdentifier: [String: SystemInfo]
    ) -> SystemInfo? {
        if let identifier = assigned[url.lastPathComponent], let chosen = byIdentifier[identifier] {
            return chosen
        }
        return (byExtension[url.pathExtension.lowercased()] ?? []).first
    }

    func delete(_ game: Game) {
        try? FileManager.default.removeItem(at: game.url)
        var assigned = Self.assignedSystemIdentifiers()
        assigned.removeValue(forKey: game.url.lastPathComponent)
        UserDefaults.standard.set(assigned, forKey: Self.assignedSystemsKey)
        refresh()
    }

    /// Copy files the user dropped onto the library into Documents, then
    /// rescan.
    ///
    /// Any file is taken; the extension decides whether it can be filed under
    /// a system right away, and anything unclear comes back for the caller to
    /// ask about. The copies happen away from the main actor: a disc image can
    /// be hundreds of megabytes, and the library should not lock up while one
    /// is copied.
    func add(contentsOf urls: [URL]) async -> ImportSummary {
        let automatic = Self.automaticExtensions()
        let assignedNames = Set(Self.assignedSystemIdentifiers().keys)
        let documents = Self.documentsDirectory

        let summary = await Task.detached(priority: .userInitiated) {
            Self.copy(
                urls,
                into: documents,
                automaticExtensions: automatic,
                assignedNames: assignedNames
            )
        }.value

        refresh()
        return summary
    }

    /// Remember which system the user picked for files the app could not
    /// place, then rescan so they appear under it.
    func assign(_ choices: [URL: String]) {
        guard !choices.isEmpty else { return }
        var assigned = Self.assignedSystemIdentifiers()
        for (url, identifier) in choices {
            assigned[url.lastPathComponent] = identifier
        }
        UserDefaults.standard.set(assigned, forKey: Self.assignedSystemsKey)
        refresh()
    }

    /// Delete copies the user decided not to keep: files that were waiting for
    /// a system and never got one.
    func discard(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
        refresh()
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
        automaticExtensions: Set<String>,
        assignedNames: Set<String>
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

            let placed = automaticExtensions.contains(url.pathExtension.lowercased())
                || assignedNames.contains(name)

            let destination = documents.appendingPathComponent(name)
            guard !fm.fileExists(atPath: destination.path) else {
                // A file already in the library is left alone — unless it was
                // never given a system, in which case it is still waiting for
                // one and dropping it again is how it gets asked about.
                if placed {
                    summary.alreadyInLibrary.append(name)
                } else {
                    summary.needsSystem.append(destination)
                }
                continue
            }

            do {
                try fm.copyItem(at: url, to: destination)
                if placed {
                    summary.added.append(name)
                } else {
                    summary.needsSystem.append(destination)
                }
            } catch {
                NSLog("[Cassowary] could not add \(name): \(error.localizedDescription)")
                summary.failed.append(name)
            }
        }

        return summary
    }
}
