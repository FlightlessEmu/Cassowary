// Copyright (c) 2021, OpenEmu Team
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
internal import os.log

public class OECorePlugin: OEPlugin {
    
    override public class var pluginExtension: String {
        "oecoreplugin"
    }
    
    override public class var pluginFolder: String {
        "Cores"
    }
    
    @objc public class var allPlugins: [OECorePlugin] {
        // swiftlint:disable:next force_cast
        let all = plugins() as! [OECorePlugin]
        var seen: [String: OECorePlugin] = [:]
        for plugin in all {
            let id = plugin.bundleIdentifier
            if let existing = seen[id] {
                os_log(.error, "OECorePlugin: CFBundleIdentifier collision — '%{public}@' is claimed by both '%{public}@' and '%{public}@' in the app bundle.",
                       id, existing.url.lastPathComponent, plugin.url.lastPathComponent)
            } else {
                seen[id] = plugin
            }
        }
        return all
    }

    /// Bundle identifiers for which more than one .oecoreplugin is present in the
    /// Cores folder. Non-empty means at least one core has an ambiguous install that
    /// may cause silent failures (black screen, wrong version loaded, etc.).
    public class var collidingBundleIdentifiers: Set<String> {
        var seen = Set<String>()
        var collisions = Set<String>()
        for plugin in allPlugins {
            let id = plugin.bundleIdentifier
            if !seen.insert(id).inserted {
                collisions.insert(id)
            }
        }
        return collisions
    }
    
    required init(bundleAtURL bundleURL: URL, name: String?) throws {
        try super.init(bundleAtURL: bundleURL, name: name)
        
        // invalidate global cache
        Self.cachedRequiredFiles = nil
    }
    
    public static func corePlugin(bundleAtURL bundleURL: URL) -> OECorePlugin? {
        return try? plugin(bundleAtURL: bundleURL)
    }
    
    public static func corePlugin(bundleIdentifier identifier: String) -> OECorePlugin? {
        return allPlugins.first(where: {
            $0.bundleIdentifier.caseInsensitiveCompare(identifier) == .orderedSame
        })
    }
    
    @objc public static func corePlugins(forSystemIdentifier identifier: String) -> [OECorePlugin] {
        return allPlugins.filter { $0.systemIdentifiers.contains(identifier) }
    }
    
    // MARK: -
    
    typealias Controller = OEGameCoreController
    
    private var _controller: Controller?
    public var controller: OEGameCoreController! {
        if _controller == nil,
           let principalClass = bundle.principalClass {
            _controller = newPluginController(with: principalClass)
        }
        return _controller
    }
    
    private func newPluginController(with bundleClass: AnyClass) -> Controller? {
        guard let bundleClass = bundleClass as? Controller.Type else { return nil }
        return bundleClass.init(bundle: bundle)
    }
    
    // MARK: -
    
    private static var cachedRequiredFiles: [[String: Any]]?
    public static var requiredFiles: [[String: Any]] {
        if cachedRequiredFiles == nil {
            var files: [[String: Any]] = []
            for plugin in allPlugins {
                files.append(contentsOf: plugin.requiredFiles)
            }
            
            cachedRequiredFiles = files
        }
        
        return cachedRequiredFiles!
    }
    
    public var gameCoreClass: AnyClass? {
        return controller?.gameCoreClass
    }
    
    public var bundleIdentifier: String {
        // swiftlint:disable:next force_cast
        return infoDictionary["CFBundleIdentifier"] as! String
    }
    
    public var systemIdentifiers: [String] {
        return infoDictionary[OEGameCoreSystemIdentifiersKey] as? [String] ?? []
    }
    
    public var coreOptions: [String: [String: Any]] {
        return infoDictionary[OEGameCoreOptionsKey] as? [String: [String: Any]] ?? [:]
    }
    
    public var requiredFiles: [[String: Any]] {
        var allRequiredFiles: [[String: Any]] = []
        
        for value in coreOptions.values {
            if let object = value[OEGameCoreRequiredFilesKey] as? [[String: Any]] {
                allRequiredFiles.append(contentsOf: object)
            }
        }
        
        return allRequiredFiles
    }
}

public extension OECorePlugin {
    
    func requiredFiles(forSystemIdentifier systemIdentifier: String) -> [[String: Any]]? {
        let options = coreOptions[systemIdentifier]
        return options?[OEGameCoreRequiredFilesKey] as? [[String: Any]] ?? nil
    }
    
    func supportsCheatCode(forSystemIdentifier systemIdentifier: String) -> Bool {
        let options = coreOptions[systemIdentifier]
        return options?[OEGameCoreSupportsCheatCodeKey] as? Bool ?? false
    }

    func supportsRewinding(forSystemIdentifier systemIdentifier: String) -> Bool {
        let options = coreOptions[systemIdentifier]
        return options?[OEGameCoreSupportsRewindingKey] as? Bool ?? false
    }
    
    func supportsRetroAchievements(forSystemIdentifier systemIdentifier: String) -> Bool {
        let options = coreOptions[systemIdentifier]
        return options?[OEGameCoreSupportsRetroAchievementsKey] as? Bool ?? false
    }
    
    func rewindInterval(forSystemIdentifier systemIdentifier: String) -> Int {
        let options = coreOptions[systemIdentifier]
        return options?[OEGameCoreRewindIntervalKey] as? Int ?? 0
    }
    
    func rewindBufferSeconds(forSystemIdentifier systemIdentifier: String) -> Int {
        let options = coreOptions[systemIdentifier]
        return options?[OEGameCoreRewindBufferSecondsKey] as? Int ?? 0
    }
}
