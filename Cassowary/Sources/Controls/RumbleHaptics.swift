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

import CoreHaptics
import GameController
import UIKit

/// How hard an emulated rumble plays back as haptics.
///
/// Read when a rumble starts rather than cached, so a change in the in-game
/// menu takes effect the next time the game rumbles.
enum RumbleStrength: String, CaseIterable, Identifiable {

    case off
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:    return "Off"
        case .low:    return "Low"
        case .medium: return "Medium"
        case .high:   return "High"
        }
    }

    /// How hard one impact hits, 0...1.
    var intensity: CGFloat {
        switch self {
        case .off:    return 0
        case .low:    return 0.35
        case .medium: return 0.7
        case .high:   return 1
        }
    }
}

/// Plays the emulated Rumble Pak.
///
/// Each player's rumble goes to that player's controller when it has motors,
/// so in a two-player game the pad that shakes is the one the game shook.
/// Players with no such controller — and single-device play — buzz the device
/// instead. The strength comes from the in-game menu, read when a rumble
/// starts rather than cached.
@MainActor
final class RumbleHaptics {

    static let strengthKey = "cassowary.rumbleStrength"

    static var strength: RumbleStrength {
        UserDefaults.standard.string(forKey: strengthKey)
            .flatMap(RumbleStrength.init(rawValue:)) ?? .medium
    }

    /// Controllers that can rumble, in the order they connected. The engine
    /// hands out players in that order too, so the first one is player one.
    /// A controller the app has given a `playerIndex` wins over the order.
    private var controllers: [GCController] = []

    /// Which players are rumbling right now. A game can rumble more than one.
    private var rumbling: Set<UInt> = []

    /// The controller engines, kept per controller so a fast rattle does not
    /// build a new one for every pulse.
    private var engines: [ObjectIdentifier: CHHapticEngine] = [:]

    /// The player running on a controller, by player number.
    private var players: [UInt: CHHapticPatternPlayer] = [:]

    // The device fallback.
    private var timer: Timer?
    private var generator: UIImpactFeedbackGenerator?

    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            Task { @MainActor in self?.add(controller) }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            Task { @MainActor in self?.remove(controller) }
        })

        for controller in GCController.controllers() {
            add(controller)
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func setRumbling(_ on: Bool, forPlayer player: UInt) {
        if on {
            rumbling.insert(player)
        } else {
            rumbling.remove(player)
        }

        update()
    }

    /// Stop everything, for when the game does.
    func stop() {
        rumbling.removeAll()
        update()
    }

    // MARK: - Controllers

    private func add(_ controller: GCController) {
        guard controller.haptics != nil, !controllers.contains(where: { $0 === controller }) else { return }

        controllers.append(controller)
    }

    private func remove(_ controller: GCController) {
        controllers.removeAll { $0 === controller }
        engines[ObjectIdentifier(controller)] = nil

        // Whatever it was playing is gone with it; the next rumble rebuilds.
        players.values.forEach { try? $0.stop(atTime: CHHapticTimeImmediate) }
        players.removeAll()

        update()
    }

    /// The controller for a player: its `playerIndex` if the app set one,
    /// otherwise the connection order the engine uses for players.
    private func controller(forPlayer player: UInt) -> GCController? {
        let index = Int(player) - 1

        if let assigned = controllers.first(where: { $0.playerIndex.rawValue == index }) {
            return assigned
        }

        return controllers.indices.contains(index) ? controllers[index] : nil
    }

    private func engine(for controller: GCController) -> CHHapticEngine? {
        let key = ObjectIdentifier(controller)

        if let engine = engines[key] {
            return engine
        }

        guard let haptics = controller.haptics,
              let engine = haptics.createEngine(withLocality: .default)
        else { return nil }

        engine.playsHapticsOnly = true
        engines[key] = engine

        return engine
    }

    private func startController(_ controller: GCController, forPlayer player: UInt) {
        guard let engine = engine(for: controller),
              let pattern = try? makePattern(on: engine),
              (try? engine.start()) != nil
        else { return }

        guard (try? pattern.start(atTime: CHHapticTimeImmediate)) != nil else { return }

        players[player] = pattern
    }

    private func stopController(forPlayer player: UInt) {
        guard let pattern = players.removeValue(forKey: player) else { return }

        try? pattern.stop(atTime: CHHapticTimeImmediate)
    }

    private func makePattern(on engine: CHHapticEngine) throws -> CHHapticPatternPlayer {
        let intensity = Float(Self.strength.intensity)

        // One long event: the game stops the rumble when it wants it stopped.
        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3),
            ],
            relativeTime: 0,
            duration: 3600)

        return try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
    }

    // MARK: - Playback

    private func update() {
        guard Self.strength != .off, !rumbling.isEmpty else {
            players.keys.forEach { stopController(forPlayer: $0) }
            stopDevice()
            return
        }

        for player in players.keys where !rumbling.contains(player) {
            stopController(forPlayer: player)
        }

        var needsDevice = false

        for player in rumbling {
            if let controller = controller(forPlayer: player) {
                if players[player] == nil {
                    startController(controller, forPlayer: player)
                }
            } else {
                // No controller for this player: the device stands in.
                needsDevice = true
            }
        }

        if needsDevice {
            startDevice()
        } else {
            stopDevice()
        }
    }

    // MARK: - Device

    private func startDevice() {
        guard timer == nil else { return }

        let generator = self.generator ?? UIImpactFeedbackGenerator(style: .medium)
        self.generator = generator
        generator.prepare()

        // Fourteen a second reads as one steady buzz rather than a rattle.
        let timer = Timer(timeInterval: 0.07, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.rumbling.isEmpty else { return }

                let strength = Self.strength
                guard strength != .off else { return }

                self.generator?.impactOccurred(intensity: strength.intensity)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopDevice() {
        timer?.invalidate()
        timer = nil
    }
}
