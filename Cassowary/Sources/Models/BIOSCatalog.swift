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
import CryptoKit
import OpenEmuKit

/// One BIOS file a core asks for.
struct BIOSFile: Identifiable, Hashable {
    var id: String { name.lowercased() }
    let name: String
    let description: String
    /// Nice to have: games run without it (an add-on, a lock-on cartridge).
    let isOptional: Bool
    /// In the BIOS folder, with the size and contents the core expects.
    let isPresent: Bool
}

/// What a system needs from the BIOS folder, and whether it has it.
struct BIOSRequirement: Identifiable {
    var id: String { systemIdentifier }
    let systemIdentifier: String
    let files: [BIOSFile]
    /// One file per region, where any one lets that region's games run,
    /// rather than a set that is needed in full.
    let isRegional: Bool

    var required: [BIOSFile] { files.filter { !$0.isOptional } }
    var present: [BIOSFile] { files.filter(\.isPresent) }

    /// Whether games can run. A regional set needs one of its files; any
    /// other set needs every file that is not optional.
    var isReady: Bool {
        if required.isEmpty { return true }
        return isRegional ? required.contains(where: \.isPresent) : required.allSatisfy(\.isPresent)
    }

    /// The required files still worth adding.
    var missing: [BIOSFile] { required.filter { !$0.isPresent } }
}

/// The BIOS files the installed cores ask for, and which of them the BIOS
/// folder holds.
///
/// A file only counts as present when its size and MD5 match what the core
/// lists, which means reading it. Hashes are remembered by path, size and
/// modification date, so a screen that asks on every redraw costs a lookup
/// rather than a read.
enum BIOSCatalog {

    /// The BIOS folder every core shares: Application Support/OpenEmu/BIOS,
    /// the same folder the plugin controllers point their cores at.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("OpenEmu", isDirectory: true).appendingPathComponent("BIOS", isDirectory: true)
    }

    /// Systems whose files are one BIOS per region. Any one of them runs that
    /// region's games, so having one is enough to play.
    private static let regionalSystems: Set<String> = [
        "openemu.system.psx",
        "openemu.system.scd",
        "openemu.system.saturn",
    ]

    /// Every BIOS file any installed core asks for, by lowercase file name:
    /// the wanted MD5 and size. This is what a dropped file is checked
    /// against before it is taken as a BIOS rather than a game. Read straight
    /// off the core plugins' Info.plists so it works even when a controller
    /// will not load.
    nonisolated static func signatures() -> [String: (md5: String, size: UInt64)] {
        var signatures: [String: (md5: String, size: UInt64)] = [:]
        for plugin in OECorePlugin.allPlugins {
            for file in plugin.requiredFiles {
                guard let name = (file["Name"] as? String)?.lowercased(),
                      let md5 = (file["MD5"] as? String)?.lowercased() else {
                    continue
                }
                let size = (file["Size"] as? NSNumber)?.uint64Value ?? 0
                signatures[name] = (md5, size)
            }
        }
        return signatures
    }

    /// What a system needs, or nil when none of its cores asks for a BIOS.
    static func requirement(forSystemIdentifier identifier: String) -> BIOSRequirement? {
        var wanted: [[String: Any]] = []
        var seen: Set<String> = []
        for plugin in OECorePlugin.allPlugins where plugin.systemIdentifiers.contains(identifier) {
            // Asked per system: a core that runs several systems lists each
            // one's files apart. Without a controller, the plugin's own list
            // only speaks for this system when it runs nothing else.
            let files: [[String: Any]]
            if let controller = plugin.controller {
                files = controller.requiredFiles(forSystemIdentifier: identifier) ?? []
            } else if plugin.systemIdentifiers == [identifier] {
                files = plugin.requiredFiles
            } else {
                files = []
            }
            for file in files {
                guard let name = (file["Name"] as? String)?.lowercased(), !seen.contains(name) else { continue }
                seen.insert(name)
                wanted.append(file)
            }
        }
        guard !wanted.isEmpty else { return nil }

        let files = wanted.map { file -> BIOSFile in
            let name = (file["Name"] as? String) ?? "BIOS"
            return BIOSFile(
                name: name,
                description: (file["Description"] as? String) ?? name,
                isOptional: (file["Optional"] as? NSNumber)?.boolValue ?? false,
                isPresent: isPresent(
                    name: name,
                    md5: (file["MD5"] as? String)?.lowercased(),
                    size: (file["Size"] as? NSNumber)?.uint64Value
                )
            )
        }
        return BIOSRequirement(
            systemIdentifier: identifier,
            files: files,
            isRegional: regionalSystems.contains(identifier)
        )
    }

    /// What happened to one file handed to `file(_:)`.
    enum FilingResult {
        /// Not a BIOS name any core asks for.
        case notBIOS
        /// Checked and copied into the BIOS folder.
        case filed
        /// A BIOS's name, but not its size or contents.
        case invalid
        /// The right file, but it could not be copied.
        case failed(Error)
    }

    /// Files a BIOS into the BIOS folder when it is one a core asks for.
    ///
    /// A name match alone makes it a BIOS attempt: a misnamed game must keep
    /// working as a game, but a file with a BIOS's name must never land in
    /// the game grid, where it can only fail to launch. Only a file whose
    /// size and hash match lands where the cores look.
    nonisolated static func file(
        _ url: URL,
        signatures: [String: (md5: String, size: UInt64)],
        into folder: URL
    ) -> FilingResult {
        let name = url.lastPathComponent
        guard let wanted = signatures[name.lowercased()] else { return .notBIOS }

        let size = fileSize(at: url)
        let hash = size == wanted.size ? md5(of: url) : nil
        guard size == wanted.size, hash == wanted.md5 else {
            NSLog("[Cassowary] BIOS candidate \(name) failed check (size \(String(describing: size)) hash \(hash ?? "unreadable"))")
            return .invalid
        }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(name.lowercased())
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: url, to: destination)
            return .filed
        } catch {
            NSLog("[Cassowary] could not file BIOS \(name): \(error.localizedDescription)")
            return .failed(error)
        }
    }

    // MARK: - Checking files

    /// A remembered hash, and the file it was taken from.
    private struct HashRecord {
        let size: UInt64
        let modified: Date
        let md5: String?
    }

    private static let hashLock = NSLock()
    nonisolated(unsafe) private static var hashes: [String: HashRecord] = [:]

    /// Whether the BIOS folder holds this file with the right size and hash.
    /// A core that gives no hash is satisfied by the file being there.
    private static func isPresent(name: String, md5 wantedMD5: String?, size wantedSize: UInt64?) -> Bool {
        let url = directory.appendingPathComponent(name.lowercased())
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        guard let wantedMD5 else { return true }

        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        if let wantedSize, wantedSize > 0, size != wantedSize { return false }
        let modified = (attributes[.modificationDate] as? Date) ?? .distantPast

        hashLock.lock()
        let record = hashes[url.path]
        hashLock.unlock()
        if let record, record.size == size, record.modified == modified {
            return record.md5 == wantedMD5
        }

        let hash = md5(of: url)
        hashLock.lock()
        hashes[url.path] = HashRecord(size: size, modified: modified, md5: hash)
        hashLock.unlock()
        return hash == wantedMD5
    }

    /// The size of a file, or nil when it cannot be read.
    private nonisolated static func fileSize(at url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
    }

    /// The lowercase MD5 hex of a file's contents, or nil when it cannot be
    /// read. BIOS files are small; this only runs after a name-and-size
    /// match, never on a whole disc image.
    private nonisolated static func md5(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
