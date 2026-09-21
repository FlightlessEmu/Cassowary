// Copyright (c) 2026, Cassowary App
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the Cassowary App nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY Cassowary App ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL Cassowary App BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import Foundation
import GameController
import OpenEmuSystem
import OpenEmuKit

/// Runs the physical gamepads the system has paired.
///
/// Each connected controller is read through GameController and translated
/// into the same presses the on-screen pad sends, using the same
/// `ControllerLayout`, so both paths share one destination: `GameSession`, and
/// from there the core. Controllers can come and go while a game is running.
/// Player 2 and up are not wired up yet.
@MainActor
final class PhysicalControllerManager {

    private let session: any ControlPressHandler
    private let layout: ControllerLayout
    private var connections: [GCController: ControllerConnection] = [:]
    private var observers: [NSObjectProtocol] = []

    init(session: any ControlPressHandler, layout: ControllerLayout) {
        self.session = session
        self.layout = layout
    }

    /// The number of controllers currently driving input, for the UI.
    var connectedCount: Int { connections.count }

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            onMain { self?.connect(controller) }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            onMain { self?.disconnect(controller) }
        })

        for controller in GCController.controllers() {
            connect(controller)
        }
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        connections.values.forEach { $0.tearDown() }
        connections.removeAll()
    }

    private func connect(_ controller: GCController) {
        guard connections[controller] == nil else { return }

        let connection = ControllerConnection(controller: controller, layout: layout, handler: session)
        guard connection.isUsable else { return }

        connections[controller] = connection
        NSLog("[Cassowary] controller connected: %@ (%ld controls mapped)",
              controller.vendorName ?? "unknown", layout.gamepadControls.count)
    }

    private func disconnect(_ controller: GCController) {
        guard let connection = connections.removeValue(forKey: controller) else { return }
        connection.tearDown()
        NSLog("[Cassowary] controller disconnected: %@", controller.vendorName ?? "unknown")
    }
}

/// One paired controller, translating its input while it is connected.
@MainActor
private final class ControllerConnection {

    private let controller: GCController
    private let layout: ControllerLayout
    private let handler: any ControlPressHandler

    /// The controls that are currently down, so a repeated callback for a
    /// control that has not changed does not count twice.
    private var heldControls: Set<GamepadControl> = []

    /// How many inputs are currently holding each system button down. A button
    /// can be driven by more than one control — the d-pad and the stick, or
    /// Menu aliased onto Start — so the press is only released when the last
    /// of them lets go.
    private var downCounts: [String: Int] = [:]

    /// The last deflection reported for each analog button, so repeat values
    /// do not spam the core, and the button behind each one, so a disconnect
    /// can recenter it.
    private var analogValues: [String: CGFloat] = [:]
    private var analogButtons: [String: ControllerButton] = [:]

    private var extendedGamepad: GCExtendedGamepad?
    private var gamepad: GCGamepad?

    var isUsable: Bool {
        controller.extendedGamepad != nil || controller.gamepad != nil
    }

    init(controller: GCController, layout: ControllerLayout, handler: any ControlPressHandler) {
        self.controller = controller
        self.layout = layout
        self.handler = handler
        attach()
    }

    func tearDown() {
        if let pad = extendedGamepad { detach(pad) }
        if let pad = gamepad { detach(pad) }
        extendedGamepad = nil
        gamepad = nil

        // A pad can be unplugged mid-press. Let go of everything so the game
        // does not keep moving, and recenter the sticks.
        for control in heldControls {
            if let button = layout.button(for: control) {
                handler.release(button.systemKey)
            }
        }
        heldControls.removeAll()
        downCounts.removeAll()

        for (id, value) in analogValues where value != 0 {
            if let button = analogButtons[id] {
                handler.moveAnalog(button.systemKey, value: 0)
            }
        }
        analogValues.removeAll()
        analogButtons.removeAll()
    }

    // MARK: - Attaching

    private func attach() {
        if let pad = controller.extendedGamepad {
            extendedGamepad = pad
            attach(pad)
        } else if let pad = controller.gamepad {
            gamepad = pad
            attach(pad)
        }
    }

    private func attach(_ pad: GCExtendedGamepad) {
        bind(pad.buttonA, to: .buttonA)
        bind(pad.buttonB, to: .buttonB)
        bind(pad.buttonX, to: .buttonX)
        bind(pad.buttonY, to: .buttonY)
        bind(pad.leftShoulder, to: .leftShoulder)
        bind(pad.rightShoulder, to: .rightShoulder)
        bind(pad.leftTrigger, to: .leftTrigger)
        bind(pad.rightTrigger, to: .rightTrigger)
        bind(pad.buttonMenu, to: .menu)
        if let home = pad.buttonHome { bind(home, to: .home) }
        if let options = pad.buttonOptions { bind(options, to: .options) }

        bind(pad.dpad, to: DPadControls(up: .dpadUp, down: .dpadDown, left: .dpadLeft, right: .dpadRight))
        bind(pad.leftThumbstick, to: .left)
        bind(pad.rightThumbstick, to: .right)
    }

    private func attach(_ pad: GCGamepad) {
        bind(pad.buttonA, to: .buttonA)
        bind(pad.buttonB, to: .buttonB)
        bind(pad.buttonX, to: .buttonX)
        bind(pad.buttonY, to: .buttonY)
        bind(pad.leftShoulder, to: .leftShoulder)
        bind(pad.rightShoulder, to: .rightShoulder)
        bind(pad.dpad, to: DPadControls(up: .dpadUp, down: .dpadDown, left: .dpadLeft, right: .dpadRight))
    }

    private func detach(_ pad: GCExtendedGamepad) {
        pad.buttonA.valueChangedHandler = nil
        pad.buttonB.valueChangedHandler = nil
        pad.buttonX.valueChangedHandler = nil
        pad.buttonY.valueChangedHandler = nil
        pad.leftShoulder.valueChangedHandler = nil
        pad.rightShoulder.valueChangedHandler = nil
        pad.leftTrigger.valueChangedHandler = nil
        pad.rightTrigger.valueChangedHandler = nil
        pad.buttonMenu.valueChangedHandler = nil
        pad.buttonHome?.valueChangedHandler = nil
        pad.buttonOptions?.valueChangedHandler = nil
        pad.dpad.valueChangedHandler = nil
        pad.leftThumbstick.valueChangedHandler = nil
        pad.rightThumbstick.valueChangedHandler = nil
    }

    private func detach(_ pad: GCGamepad) {
        pad.buttonA.valueChangedHandler = nil
        pad.buttonB.valueChangedHandler = nil
        pad.buttonX.valueChangedHandler = nil
        pad.buttonY.valueChangedHandler = nil
        pad.leftShoulder.valueChangedHandler = nil
        pad.rightShoulder.valueChangedHandler = nil
        pad.dpad.valueChangedHandler = nil
    }

    private func bind(_ input: GCControllerButtonInput, to control: GamepadControl) {
        input.valueChangedHandler = { [weak self] _, value, _ in
            onMain { self?.buttonChanged(control, value: value) }
        }
    }

    private func bind(_ dpad: GCControllerDirectionPad, to controls: DPadControls) {
        dpad.valueChangedHandler = { [weak self] dpad, _, _ in
            onMain {
                self?.buttonChanged(controls.up, value: dpad.up.value)
                self?.buttonChanged(controls.down, value: dpad.down.value)
                self?.buttonChanged(controls.left, value: dpad.left.value)
                self?.buttonChanged(controls.right, value: dpad.right.value)
            }
        }
    }

    private func bind(_ stick: GCControllerDirectionPad, to side: StickSide) {
        stick.valueChangedHandler = { [weak self] _, x, y in
            onMain { self?.stickChanged(side, x: x, y: y) }
        }
    }

    // MARK: - Translating input

    private func buttonChanged(_ control: GamepadControl, value: Float) {
        guard let button = layout.button(for: control) else { return }

        if button.isAnalog {
            setAnalog(button, value: CGFloat(max(0, value)))
        } else {
            setHeld(control, value >= 0.5)
        }
    }

    private func stickChanged(_ side: StickSide, x: Float, y: Float) {
        let controls = layout.stickControls(side)
        drive(controls.up, magnitude: max(0, -y))
        drive(controls.down, magnitude: max(0, y))
        drive(controls.left, magnitude: max(0, -x))
        drive(controls.right, magnitude: max(0, x))
    }

    private func drive(_ control: GamepadControl, magnitude: Float) {
        guard let button = layout.button(for: control) else { return }

        if button.isAnalog {
            setAnalog(button, value: CGFloat(magnitude))
        } else {
            setHeld(control, magnitude >= Float(ControllerLayout.deadzone))
        }
    }

    /// Track a control's own up/down state so repeated callbacks do not stack,
    /// and every control that shares a button presses and releases once.
    private func setHeld(_ control: GamepadControl, _ isDown: Bool) {
        guard let button = layout.button(for: control) else { return }

        if isDown {
            guard heldControls.insert(control).inserted else { return }
            setDown(button, true)
        } else {
            guard heldControls.remove(control) != nil else { return }
            setDown(button, false)
        }
    }

    private func setDown(_ button: ControllerButton, _ isDown: Bool) {
        let id = button.id
        let count = downCounts[id] ?? 0

        if isDown {
            if count == 0 {
                handler.press(button.systemKey)
            }
            downCounts[id] = count + 1
        } else if count > 0 {
            let remaining = count - 1
            downCounts[id] = remaining
            if remaining == 0 {
                handler.release(button.systemKey)
            }
        }
    }

    private func setAnalog(_ button: ControllerButton, value: CGFloat) {
        let id = button.id
        let deflection = value < ControllerLayout.deadzone ? 0 : value

        guard analogValues[id] != deflection else { return }
        analogValues[id] = deflection
        analogButtons[id] = button
        handler.moveAnalog(button.systemKey, value: deflection)
    }
}

/// The four controls one d-pad's directions drive.
private struct DPadControls {
    let up: GamepadControl
    let down: GamepadControl
    let left: GamepadControl
    let right: GamepadControl
}

/// Run `work` on the main actor.
///
/// GameController calls its handlers on the main thread, but nothing in the
/// API promises it, so be explicit and cheap about it. Shared by the physical
/// gamepad and keyboard managers.
func onMain(_ work: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { work() }
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }
}
