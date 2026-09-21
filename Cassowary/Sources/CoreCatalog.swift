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

/// One emulator core that can run one or more systems.
///
/// This is the iOS-visible slice of `OECorePlugin`: identity and display
/// info. The plugin itself is kept so the game session can launch it without
/// a second lookup.
struct CoreEntry: Identifiable, Hashable {
    /// The core's bundle identifier, e.g. `org.openemu.Gambatte`.
    let id: String
    let displayName: String
    let version: String
    let plugin: OECorePlugin

    init(plugin: OECorePlugin) {
        self.plugin = plugin
        self.id = plugin.bundleIdentifier
        self.displayName = plugin.displayName
        self.version = plugin.version
    }

    static func == (lhs: CoreEntry, rhs: CoreEntry) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// One game system and the cores installed for it.
struct SystemEntry: Identifiable, Hashable {
    /// The system identifier, e.g. `openemu.system.gb`.
    let id: String
    let name: String
    let icon: UIImage?
    let extensions: [String]
    let cores: [CoreEntry]

    /// Whether at least one core can run this system.
    var hasCore: Bool { !cores.isEmpty }

    init(plugin: OESystemPlugin) {
        self.id = plugin.systemIdentifier
        self.name = plugin.systemName
        self.icon = plugin.systemIcon as? UIImage
        self.extensions = plugin.supportedTypeExtensions
        self.cores = OECorePlugin.corePlugins(forSystemIdentifier: plugin.systemIdentifier)
            .map(CoreEntry.init(plugin:))
    }

    static func == (lhs: SystemEntry, rhs: SystemEntry) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// The installed systems and cores, plus the user's default per system.
///
/// This is what makes the library multi-core ready: every place that picks a
/// core — the library's Play action, the core picker sheet, Settings — reads
/// from here, so a newly installed core shows up everywhere with no other
/// changes.
///
/// Defaults use the same `defaultCore.<systemIdentifier>` UserDefaults keys
/// as the macOS app, so a shared container would agree on them.
@MainActor
final class CoreCatalog: ObservableObject {

    @Published private(set) var systems: [SystemEntry] = []

    /// Distinct installed cores across all systems.
    var coreCount: Int {
        Set(systems.flatMap { $0.cores.map(\.id) }).count
    }

    static func defaultCoreKey(forSystemIdentifier identifier: String) -> String {
        "defaultCore." + identifier
    }

    func refresh() {
        systems = OESystemPlugin.allPlugins
            .filter { plugin in
                // See GameLibrary: a plugin with no controller would trap when
                // its name or extensions are read.
                guard plugin.controller != nil else {
                    NSLog("[Cassowary] ignoring system plugin with no controller: %@", plugin.url.lastPathComponent)
                    return false
                }
                return true
            }
            .map(SystemEntry.init(plugin:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func system(forIdentifier identifier: String) -> SystemEntry? {
        systems.first { $0.id == identifier }
    }

    func cores(forSystemIdentifier identifier: String) -> [CoreEntry] {
        system(forIdentifier: identifier)?.cores ?? []
    }

    /// The user's chosen default core, or nil for automatic.
    ///
    /// A stale selection (core no longer installed) reads back as nil so the
    /// UI falls through to automatic instead of pointing at a missing core.
    func defaultCoreID(forSystemIdentifier identifier: String) -> String? {
        let saved = UserDefaults.standard.string(forKey: Self.defaultCoreKey(forSystemIdentifier: identifier))
        guard let saved else { return nil }
        return cores(forSystemIdentifier: identifier).contains(where: { $0.id == saved }) ? saved : nil
    }

    /// The core to launch with: the default if set, else the first installed.
    func preferredCore(forSystemIdentifier identifier: String) -> CoreEntry? {
        let cores = cores(forSystemIdentifier: identifier)
        if let saved = defaultCoreID(forSystemIdentifier: identifier) {
            return cores.first(where: { $0.id == saved })
        }
        return cores.first
    }

    func setDefaultCore(_ coreID: String?, forSystemIdentifier identifier: String) {
        if let coreID {
            UserDefaults.standard.set(coreID, forKey: Self.defaultCoreKey(forSystemIdentifier: identifier))
        } else {
            UserDefaults.standard.removeObject(forKey: Self.defaultCoreKey(forSystemIdentifier: identifier))
        }
        objectWillChange.send()
    }
}

extension Notification.Name {
    /// Posted by the Library menu command (Cmd+R on Catalyst). The library
    /// observes it and re-scans.
    static let refreshLibrary = Notification.Name("org.cassowary.refreshLibrary")
    /// Posted by the Settings menu command (Cmd+, on Catalyst). The library
    /// observes it and opens the Settings sheet.
    static let showSettings = Notification.Name("org.cassowary.showSettings")
}
