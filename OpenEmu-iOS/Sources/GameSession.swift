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
import QuartzCore
import OpenEmuBase
import OpenEmuSystem
import OpenEmuKit

/// Runs one game.
///
/// On macOS the host app and the emulator live in separate processes and talk
/// over XPC. On iOS they run in the same process: this object loads the core
/// and the system plugin, starts the core's frame loop, and exposes the Metal
/// layer the core draws into.
///
/// The heavy lifting is still OpenEmuKit's `OpenEmuHelperApp` — this is the
/// same code the macOS helper runs, just without the XPC wrapper.
@MainActor
final class GameSession: NSObject {

    enum SessionError: LocalizedError {
        case missingSystemPlugin(String)
        case missingCorePlugin(String)
        case couldNotLoadROM(String)

        var errorDescription: String? {
            switch self {
            case .missingSystemPlugin(let id):
                return "No system plugin found for \(id)."
            case .missingCorePlugin(let id):
                return "No core found that can run \(id)."
            case .couldNotLoadROM(let reason):
                return "The game could not be loaded: \(reason)"
            }
        }
    }

    let helper = OpenEmuHelperApp()
    private let systemPlugin: OESystemPlugin
    private let corePlugin: OECorePlugin

    /// The Metal layer the core renders into. Add it to a view to see the game.
    var videoLayer: CAMetalLayer? { helper.videoLayer }

    /// The system's name, for display.
    var systemName: String { systemPlugin.systemName }

    var isRunning = false

    /// Reported by the helper once the core knows its output size.
    var screenSize: OEIntSize = .init()
    var aspectSize: OEIntSize = .init()
    var discCount: UInt = 0
    var displayModes: [[String: Any]] = []

    /// Whether emulation is paused.
    var isPaused = false

    /// The game's display aspect ratio, as width ÷ height.
    ///
    /// The core reports the aspect size it wants, which is not always the
    /// buffer size — a Game Boy outputs 160×144 pixels but displays at 10:9.
    var displayAspectRatio: CGFloat {
        guard aspectSize.width > 0, aspectSize.height > 0 else { return 1 }
        return CGFloat(aspectSize.width) / CGFloat(aspectSize.height)
    }

    /// Tell the renderer how big the display area is.
    ///
    /// The macOS app does this from its game view's layout pass. The renderer
    /// uses it to size its drawable and to scale 3D cores' buffers.
    func updateDisplayBounds(_ bounds: CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        helper.setOutputBounds(bounds)
    }

    /// Stands in for "no shader selected". The helper checks for a readable
    /// file and falls back to no filtering when there is not one.
    private static let noShaderURL = URL(fileURLWithPath: "/dev/null")

    init(romURL: URL) throws {
        // Work out which system this ROM belongs to, then which core can run it.
        let system = try Self.systemPlugin(forROMAt: romURL)
        let core = try Self.corePlugin(for: system)

        systemPlugin = system
        corePlugin = core

        let info = OEGameStartupInfo(
            romURL: romURL,
            romMD5: "",
            romHeader: "",
            romSerial: "",
            systemRegion: OELocalizationHelper.shared.regionName,
            displayModeInfo: nil,
            shaderURL: Self.noShaderURL,
            shaderParameters: [:],
            corePluginURL: core.url,
            systemPluginURL: system.url,
            lockOnRomURL: nil,
            lockOnUpmemURL: nil
        )

        super.init()

        helper.gameCoreOwner = self
        try helper.load(withStartupInfo: info)
    }

    // MARK: - Lifecycle

    func start(completionHandler: @escaping () -> Void) {
        helper.setupEmulation { [weak self] _, _ in
            guard let self else { return }
            self.helper.startEmulation {
                self.isRunning = true
                completionHandler()
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        helper.stopEmulation {}
        isRunning = false
    }

    // MARK: - Input

    func press(_ button: OESystemKey) {
        helper.systemResponder?.pressEmulatorKey(button)
    }

    func release(_ button: OESystemKey) {
        helper.systemResponder?.releaseEmulatorKey(button)
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        helper.setPauseEmulation(paused)
    }

    // MARK: - Save states

    func saveState(to url: URL, completionHandler: @escaping (Result<Void, Error>) -> Void) {
        helper.saveStateToFile(at: url) { success, error in
            if success {
                completionHandler(.success(()))
            } else {
                completionHandler(.failure(error ?? SessionError.couldNotLoadROM("save failed")))
            }
        }
    }

    func loadState(from url: URL, completionHandler: @escaping (Result<Void, Error>) -> Void) {
        helper.loadStateFromFile(at: url) { success, error in
            if success {
                completionHandler(.success(()))
            } else {
                completionHandler(.failure(error ?? SessionError.couldNotLoadROM("load failed")))
            }
        }
    }

    // MARK: - Plugin lookup

    /// Find the system plugin whose file types cover this ROM.
    private static func systemPlugin(forROMAt url: URL) throws -> OESystemPlugin {
        let fileExtension = url.pathExtension.lowercased()

        // Prefer a plugin that claims this extension outright.
        let candidates = OESystemPlugin.allPlugins.filter {
            $0.supportedTypeExtensions.map { $0.lowercased() }.contains(fileExtension)
        }

        guard let plugin = candidates.first else {
            throw SessionError.missingSystemPlugin(fileExtension)
        }
        return plugin
    }

    /// Find a core that can run the given system.
    private static func corePlugin(for system: OESystemPlugin) throws -> OECorePlugin {
        let plugins = OECorePlugin.corePlugins(forSystemIdentifier: system.systemIdentifier)
        guard let plugin = plugins.first else {
            throw SessionError.missingCorePlugin(system.systemName)
        }
        return plugin
    }
}
