// Copyright (c) 2022, OpenEmu Team
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

public enum OEGameCorePluginError: Int, CustomNSError {
    case alreadyLoaded = -1000
    case invalid = -1001
    
    public static var errorDomain: String { "org.openemu.OpenEmuKit.OEPlugin" }
}

public class OEPlugin: NSObject {
    
    private static var pluginClasses: Set<String> = []
    private static var allPluginsByType: [String: [String: Result<OEPlugin, Error>]] = [:]
    
    public private(set) var url: URL
    public private(set) var name: String
    
    public private(set) var bundle: Bundle
    public private(set) var infoDictionary: [String: Any]
    public private(set) var version: String
    public private(set) var displayName: String
    
    private class var pluginType: String {
        return NSStringFromClass(self)
    }
    
    class var pluginExtension: String {
        assertionFailure("+pluginExtension must be overriden")
        return ""
    }
    
    class var pluginFolder: String {
        assertionFailure("+pluginFolder must be overriden")
        return ""
    }
    
    override public var description: String {
        "Type: \(Self.pluginType), Bundle: \(displayName), Version: \(version), Path: \(url.path)"
    }
    
    required init(bundleAtURL bundleURL: URL, name: String?) throws {
        guard let bundle = Bundle(url: bundleURL),
              let infoDictionary = bundle.infoDictionary,
              infoDictionary["CFBundleIdentifier"] is String
        else {
            throw OEGameCorePluginError.invalid
        }
        
        let name = name ?? (bundleURL.lastPathComponent as NSString).deletingPathExtension
        
        let loaded = Self.allPluginsByType[Self.pluginType]?.values.compactMap { try? $0.get() } ?? []
        if loaded.contains(where: { $0.name == name || $0.url == bundle.bundleURL }) {
            throw OEGameCorePluginError.alreadyLoaded
        }
        
        if bundleURL.pathExtension != Self.pluginExtension {
            throw OEGameCorePluginError.invalid
        }
        
        self.url = bundle.bundleURL
        self.name = name
        
        self.bundle = bundle
        self.infoDictionary = infoDictionary
        self.version = infoDictionary["CFBundleVersion"] as? String ?? ""
        self.displayName = infoDictionary["CFBundleName"] as? String ?? infoDictionary["CFBundleExecutable"] as? String ?? ""
        
        super.init()
        
        Self.allPluginsByType[Self.pluginType, default: [:]][name] = .success(self)
    }
    
    deinit {
        bundle.unload()
    }
    
    public class func plugin(bundleAtURL bundleURL: URL) throws -> Self? {
        let pluginName = (bundleURL.lastPathComponent as NSString).deletingPathExtension
        if let cached = allPluginsByType[Self.pluginType]?[pluginName] {
            // Failed loads throw once, then stay absent until the app restarts.
            return (try? cached.get()) as? Self
        }

        let result: Result<OEPlugin, Error> = Result {
            try Self.init(bundleAtURL: bundleURL, name: pluginName)
        }
        Self.willChangeValue(forKey: "allPlugins")
        allPluginsByType[Self.pluginType, default: [:]][pluginName] = result
        Self.didChangeValue(forKey: "allPlugins")
        return try result.get() as? Self
    }
    
    public class func registerClass() {
        pluginClasses.insert(Self.pluginType)
        
        _ = plugins()
    }
    
    class func plugins() -> [OEPlugin] {
        guard pluginClasses.contains(Self.pluginType) else {
            assertionFailure("\(pluginType) must be registered with +registerClass")
            return []
        }
        if allPluginsByType[Self.pluginType] == nil {
            let fm = FileManager.default

            // Load plugins from the app bundle only. The macOS app also looked in
            // ~/Library/Application Support/OpenEmu for user-installed cores; on
            // this app anything there is a leftover from another install and would
            // show up as duplicate systems and cores.
            let builtInPluginsURL = Bundle.main.builtInPlugInsURL!
            let bundledPluginsDir = builtInPluginsURL.appendingPathComponent(Self.pluginFolder, isDirectory: true)
            let bundledPluginURLs = try? fm.contentsOfDirectory(at: bundledPluginsDir, includingPropertiesForKeys: [])
            for bundleURL in bundledPluginURLs ?? [] where bundleURL.pathExtension == Self.pluginExtension {
                _ = try? plugin(bundleAtURL: bundleURL)
            }
        }
        
        let loaded = allPluginsByType[Self.pluginType]?.values.compactMap { try? $0.get() } ?? []
        return loaded.sorted { $0.displayName.caseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

extension OEPlugin: NSCopying {
    // When an instance is assigned as objectValue to an NSCell, the NSCell creates a copy.
    // Therefore we have to implement the NSCopying protocol
    // No need to make an actual copy, we can consider each OEPlugin instance like a singleton for their bundle
    public func copy(with zone: NSZone? = nil) -> Any {
        return self
    }
}
