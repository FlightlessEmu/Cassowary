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
        case saveStateFailed
        case loadStateFailed

        var errorDescription: String? {
            switch self {
            case .missingSystemPlugin(let id):
                return "No system plugin found for \(id)."
            case .missingCorePlugin(let id):
                return "No core found that can run \(id)."
            case .couldNotLoadROM(let reason):
                return "The game could not be loaded: \(reason)"
            case .saveStateFailed:
                return "The save state could not be written."
            case .loadStateFailed:
                return "The save state could not be read."
            }
        }
    }

    let helper = OpenEmuHelperApp()
    private let systemPlugin: OESystemPlugin
    private let corePlugin: OECorePlugin
    private let romURL: URL

    /// The engine bindings driving this game, and the bridge that keeps the
    /// responder's key map up to date while the game runs.
    private var systemBindings: OESystemBindings?
    private var bindingsForwarder: SystemBindingsForwarder?

    /// The display name of the core running this game, for the UI.
    let coreDisplayName: String

    /// The system's on-screen controls, once they have been read.
    var layout: ControllerLayout?

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

    convenience init(romURL: URL, core: OECorePlugin? = nil) throws {
        // Work out which system this ROM belongs to, then which core can run it.
        let system = try Self.systemPlugin(forROMAt: romURL)

        // An explicitly picked core wins as long as it actually runs this
        // system; otherwise fall back to the first installed core so a stale
        // pick degrades to the same behavior as no pick.
        let resolved: OECorePlugin
        if let core, core.systemIdentifiers.contains(system.systemIdentifier) {
            resolved = core
        } else {
            resolved = try Self.corePlugin(for: system)
        }

        try self.init(romURL: romURL, system: system, core: resolved)
    }

    private init(romURL: URL, system: OESystemPlugin, core: OECorePlugin) throws {
        systemPlugin = system
        corePlugin = core
        self.romURL = romURL
        coreDisplayName = core.displayName

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
        // The bindings have to be in the responder's key map before the first
        // frame, or the opening seconds of input go nowhere.
        attachBindings()

        // Gamepad events reach the responder through the device manager's
        // unhandled-event monitor, which is off until a game asks for it.
        helper.setHandleEvents(true)

#if targetEnvironment(macCatalyst)
        // IOKit hands OEDeviceManager the Mac's controllers.
#else
        // iOS has no IOKit: the bridge builds devices from GameController.
        OEiOSGameControllerManager.shared.start()
#endif

        // The macOS app drives this from its RetroAchievements preferences. The
        // iOS app has no such screen yet, so hardcore mode is off: without it
        // the core refuses to load save states, which is surprising when there
        // is no achievement UI to explain why.
        helper.setHardcoreEnabled(false)

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
        helper.setHandleEvents(false)
#if !targetEnvironment(macCatalyst)
        OEiOSGameControllerManager.shared.stop()
#endif
        detachBindings()
        helper.stopEmulation {}
        isRunning = false
    }

    // MARK: - Bindings

    /// Connect this system's bindings to the responder.
    ///
    /// `OESystemBindings` notifies observers of every existing binding as soon
    /// as one is added, which is what fills the responder's event-to-key map:
    /// the plugin's defaults first, then the user's remaps over them.
    private func attachBindings() {
        guard systemBindings == nil,
              let responder = helper.systemResponder,
              let bindings = InputBindings.systemBindings(for: systemPlugin)
        else { return }

        let forwarder = SystemBindingsForwarder(responder: responder)
        bindings.add(forwarder)

        systemBindings = bindings
        bindingsForwarder = forwarder
    }

    private func detachBindings() {
        if let systemBindings, let bindingsForwarder {
            systemBindings.remove(bindingsForwarder)
        }
        systemBindings = nil
        bindingsForwarder = nil
    }

    /// Deliver one keyboard transition, resolved through the bindings.
    func handleKeyEvent(keyCode: Int, isDown: Bool) {
        guard let responder = helper.systemResponder,
              let event = InputBindings.keyEvent(keyCode: keyCode, isDown: isDown)
        else { return }

        responder.handle(event)
    }

#if DEBUG
    /// Press the key bound to a named button, for the automated test.
    ///
    /// The Simulator does not hand its hardware keyboard to GameController, so
    /// the test drives the same path a real key press would: the binding the
    /// settings screen shows decides which key is pressed.
    func pressBoundKey(forButtonID buttonID: String) {
        guard let player = systemBindings?.keyboardPlayerBindings(forPlayer: 1),
              let description = systemPlugin.controller?.keyBindingsDescriptions[buttonID],
              let event = player.bindingEvents[description]
        else {
            NSLog("[Cassowary] no key is bound to %@", buttonID)
            return
        }

        NSLog("[Cassowary] test keyboard: %@ pressed by key %@", buttonID, KeyboardKey.name(for: Int(event.keycode)))
        handleKeyEvent(keyCode: Int(event.keycode), isDown: true)
    }

    /// Remap a button through the same call the settings screen makes, so the
    /// automated test can prove a remap survives a relaunch.
    func remapForTesting(buttonID: String, keyCode: Int) {
        guard let player = systemBindings?.keyboardPlayerBindings(forPlayer: 1),
              let event = InputBindings.keyEvent(keyCode: keyCode, isDown: true)
        else { return }

        player.assign(event, toKeyWithName: buttonID)
        InputBindings.save()
        NSLog("[Cassowary] test remap: %@ → %@", buttonID, KeyboardKey.name(for: keyCode))
    }

    /// Hold the gamepad control with a HID usage, for the automated test.
    ///
    /// The Simulator has no hardware controller, so the test drives the same
    /// path a controller input would: the bridge dispatches the value and the
    /// bindings decide which emulator key it becomes.
    func holdGamepadControl(usage: UInt32) {
        OEiOSGameControllerManager.shared.holdControl(withUsage: usage)
    }
#endif

    // MARK: - Input

    /// Press a button by its name, for automated testing.
    ///
    /// Used by Scripts/cassowary/run-cassowary.sh to check that input reaches the core
    /// without needing to drive the UI.
    func pressButton(named name: String) {
        guard let layout, let button = layout.allButtons.first(where: { $0.id == name }) else {
            NSLog("[Cassowary] no button named %@; have %@", name, layout?.allButtons.map(\.id).joined(separator: ",") ?? "none")
            return
        }
        press(button.systemKey)
    }

    /// Release a button by its name.
    func releaseButton(named name: String) {
        guard let layout, let button = layout.allButtons.first(where: { $0.id == name }) else { return }
        release(button.systemKey)
    }

    func press(_ button: OESystemKey) {
        helper.systemResponder?.pressEmulatorKey(button)
    }

    func release(_ button: OESystemKey) {
        helper.systemResponder?.releaseEmulatorKey(button)
    }

    /// Report an analog deflection, 0…1, for a direction on an analog control.
    ///
    /// Used by the thumbstick on systems with analog directions (N64 and
    /// friends). Value 0 means centered, matching HID axis semantics — the
    /// core reads it as released, so no press/release pairing is needed.
    func moveAnalog(_ button: OESystemKey, value: CGFloat) {
        helper.systemResponder?.changeAnalogEmulatorKey(button, value: value)
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        // Pausing after the session has stopped is a no-op. The core is
        // already gone at that point, and asking the helper to pause it
        // would trap.
        guard isRunning else { return }
        helper.setPauseEmulation(paused)
    }

    // MARK: - Video filter

    /// Switch the running game's filter.
    ///
    /// Compiling a shader takes a moment, so the work happens on the core's
    /// own thread and `completionHandler` reports when it is done. `nil` goes
    /// back to plain, unfiltered output.
    func setShader(_ shader: OEShaderModel?, completionHandler: ((Result<Void, Error>) -> Void)? = nil) {
        guard let shader else {
            helper.clearShader {
                completionHandler?(.success(()))
            }
            return
        }

        helper.setShaderURL(shader.url, parameters: nil) { error in
            if let error {
                completionHandler?(.failure(error))
            } else {
                completionHandler?(.success(()))
            }
        }
    }

    // MARK: - Upscaling

    /// Turn MetalFX spatial upscaling on or off for the running game.
    ///
    /// The helper falls back to the plain picture wherever the device or the
    /// frame size does not suit MetalFX, so this is always safe to call.
    func setMetalFXUpscalingEnabled(_ enabled: Bool) {
        helper.setMetalFXUpscalingEnabled(enabled)
    }

    // MARK: - Save states

    /// Where save states for a game live.
    ///
    /// One file per game, named after the ROM, next to the ROM in Documents so
    /// it travels with the file when the user backs the folder up.
    private static func saveStateURL(for romURL: URL) -> URL {
        romURL.deletingPathExtension().appendingPathExtension("oesavestate")
    }

    private var saveStateURL: URL { Self.saveStateURL(for: romURL) }

    /// Whether a save state exists for this game.
    var hasSaveState: Bool {
        FileManager.default.fileExists(atPath: saveStateURL.path)
    }

    func saveState(completionHandler: ((Result<Void, Error>) -> Void)? = nil) {
        helper.saveStateToFile(at: saveStateURL) { success, error in
            if success {
                completionHandler?(.success(()))
            } else {
                completionHandler?(.failure(error ?? SessionError.saveStateFailed))
            }
        }
    }

    func loadState(completionHandler: ((Result<Void, Error>) -> Void)? = nil) {
        helper.loadStateFromFile(at: saveStateURL) { success, error in
            if success {
                completionHandler?(.success(()))
            } else {
                completionHandler?(.failure(error ?? SessionError.loadStateFailed))
            }
        }
    }

    // MARK: - Plugin lookup

    /// Find the system plugin whose file types cover this ROM.
    private static func systemPlugin(forROMAt url: URL) throws -> OESystemPlugin {
        let fileExtension = url.pathExtension.lowercased()

        // Prefer a plugin that claims this extension outright. A plugin whose
        // controller will not load has no extensions to offer, and asking
        // would trap, so skip it.
        let candidates = OESystemPlugin.allPlugins.filter {
            $0.controller != nil &&
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
