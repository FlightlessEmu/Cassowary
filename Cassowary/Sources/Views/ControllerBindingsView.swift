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

import SwiftUI
import OpenEmuSystem
import OpenEmuKit

/// Remaps the controller controls one system's buttons answer to.
///
/// The engine gives every connected controller the system's
/// `Controller-Mappings.plist` defaults as device bindings, and the responder
/// resolves the controller's events through those same bindings. Each row
/// shows the control bound to a button and lights up while that control is
/// held, so a remap can be tried without starting a game.
struct ControllerBindingsView: View {

    let systemID: String
    let systemName: String

    @State private var layout: ControllerLayout?
    @State private var controller: OESystemController?
    @State private var systemBindings: OESystemBindings?
    @State private var device: OEDeviceHandler?
    @State private var player: OEDevicePlayerBindings?
    @State private var recording: ControllerButton?
    @State private var loadMessage: String?

    /// Bumped after every edit; the bindings are plain Objective-C objects, so
    /// this is what tells SwiftUI the row text has changed.
    @State private var revision = 0

    /// The control identifier bound to each button, for the live highlight.
    @State private var controlIdentifiers: [String: String] = [:]

    /// Kept alive while the screen is up: connecting or unplugging a
    /// controller has to reshuffle the rows.
    @State private var observers: [NSObjectProtocol] = []

    @StateObject private var input = ControllerInputMonitor()

    var body: some View {
        Group {
            if let layout, let player, let device {
                List {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "gamecontroller.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(.secondary)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.product.isEmpty ? "Controller" : device.product)
                                Text(deviceName(device, player: player))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    ForEach(Array(layout.groups.enumerated()), id: \.offset) { _, group in
                        Section {
                            ForEach(group) { button in
                                row(button)
                            }
                        }
                    }

                    Section {
                        Button("Restore Defaults") { reset() }
                            .disabled(!isCustomized)
                    } footer: {
                        Text("Tap a button and press a control on the controller to record it. Swipe left on a button to clear its control. \"—\" means the button has no control.")
                    }
                }
                .id(revision)
            } else if let loadMessage {
                ContentUnavailableView {
                    Label("No Controller Map", systemImage: "gamecontroller")
                } description: {
                    Text(loadMessage)
                }
            } else {
                ContentUnavailableView {
                    Label("No Controller", systemImage: "gamecontroller")
                } description: {
                    Text("Connect a controller over Bluetooth or the charging port. The controls it drives for \(systemName) show up here.")
                }
            }
        }
        .navigationTitle(systemName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            startWatching()
            load()
        }
        .onDisappear {
            input.stop()
            stopWatching()
        }
        .sheet(item: $recording) { button in
            ControllerCaptureSheet(button: button, deviceName: input.deviceName, input: input) { event in
                assign(event, to: button)
            } onCancel: {
                recording = nil
            }
        }
    }

    // MARK: - Rows

    private func row(_ button: ControllerButton) -> some View {
        Button {
            recording = button
        } label: {
            HStack {
                Text(button.label)
                Spacer()
                controlBadge(for: button)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button("Clear") { clear(button) }
                .tint(.gray)
                .disabled(player?.bindingDescriptions[button.id] == nil)
        }
    }

    /// The bound control as a badge. It fills in while the control is held.
    private func controlBadge(for button: ControllerButton) -> some View {
        let pressed = isDown(button)

        return Text(player?.bindingDescriptions[button.id] ?? "—")
            .font(.caption.weight(.semibold))
            .foregroundStyle(pressed ? Color.white : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(pressed ? Color.accentColor : Color(uiColor: .secondarySystemFill), in: Capsule())
            .animation(.easeOut(duration: 0.09), value: pressed)
    }

    private func deviceName(_ device: OEDeviceHandler, player: OEDevicePlayerBindings) -> String {
        player.playerNumber > 1 ? "Player \(player.playerNumber)" : "Player 1"
    }

    /// Whether the button's control is held right now.
    private func isDown(_ button: ControllerButton) -> Bool {
        guard let control = controlIdentifiers[button.id] else { return false }
        return input.pressedControls.contains(control)
    }

    private var isCustomized: Bool {
        guard let player, let controller, let controllerDescription = device?.controllerDescription else { return false }

        let defaults = controller.defaultDeviceControls[controllerDescription.identifier] ?? [:]
        let defaultNames = Set(defaults.keys)
        let boundNames = Set(player.bindingDescriptions.keys)

        // A key the defaults do not name is fine only when it belongs to an
        // axis or hat group whose other direction is named: assigning one
        // direction of a group binds the whole group. Anything else is a
        // custom binding.
        for name in boundNames.subtracting(defaultNames) {
            guard let key = controller.allKeyBindingsDescriptions[name],
                  let group = key.axisGroup ?? key.hatSwitchGroup,
                  !defaultNames.isDisjoint(with: group.keyNames)
            else { return true }
        }

        // Every key the defaults name has to carry the control it names.
        for name in defaultNames {
            guard let identifier = defaults[name],
                  let value = controllerDescription.controlValueDescription(forRepresentation: identifier)
            else { continue }
            if player.bindingDescriptions[name] != value.name { return true }
        }

        return false
    }

    // MARK: - Loading

    private func startWatching() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .OEDeviceManagerDidAddDeviceHandler, object: nil, queue: .main) { _ in
            onMain { refreshDevice() }
        })
        observers.append(center.addObserver(forName: .OEDeviceManagerDidRemoveDeviceHandler, object: nil, queue: .main) { _ in
            onMain { refreshDevice() }
        })
    }

    private func stopWatching() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    private func load() {
        guard systemBindings == nil else { return }

        guard let plugin = OESystemPlugin.allPlugins.first(where: { $0.systemIdentifier == systemID }),
              let systemController = plugin.controller
        else {
            loadMessage = "The \(systemName) system plugin is not installed."
            return
        }

        let controlLayout = ControllerLayout(systemPlugin: plugin)
        guard controlLayout.hasButtons else {
            loadMessage = "The \(systemName) system plugin does not describe any buttons."
            return
        }
        guard let bindings = InputBindings.systemBindings(for: plugin) else {
            loadMessage = "The \(systemName) bindings could not be created."
            return
        }

        controller = systemController
        layout = controlLayout
        systemBindings = bindings
        refreshDevice()
    }

    /// Pick the controller the rows describe, and start listening to it.
    private func refreshDevice() {
        // iOS has no IOKit, and Catalyst's sandbox blocks it: the bridge is
        // what turns GameController's controllers into the devices the
        // bindings stack knows.
        OEiOSGameControllerManager.shared.start()

        let handler = OEDeviceManager.shared.controllerDeviceHandlers.first
        if handler !== device {
            device = handler
            recording = nil
            input.stop()
            if let handler {
                input.start(handler: handler)
            }
        }

        loadPlayer()
    }

    private func loadPlayer() {
        guard let systemBindings, let device else {
            player = nil
            controlIdentifiers = [:]
            return
        }

        player = systemBindings.devicePlayerBindings(for: device)
            ?? systemBindings.devicePlayerBindings(forPlayer: 1)
        refreshControlIdentifiers()
    }

    /// The control behind each button, read from the bindings.
    private func refreshControlIdentifiers() {
        guard let player else {
            controlIdentifiers = [:]
            return
        }

        var identifiers: [String: String] = [:]
        for (key, value) in player.bindingEvents {
            let names: [String]

            if let simple = key as? OEKeyBindingDescription {
                names = [simple.name]
            } else if let group = key as? OEOrientedKeyGroupBindingDescription {
                names = group.keyNames
            } else {
                continue
            }

            // An axis or hat binds its whole group at once, so every
            // direction carries the same control. The row's own badge text
            // names the direction, which is what picks its value out of that
            // control — otherwise both ends of a stick light up together.
            let values = value.controlDescription?.controlValues ?? []
            for name in names {
                let badge = player.bindingDescriptions[name]
                identifiers[name] = values.first { $0.name == badge }?.identifier ?? value.identifier
            }
        }
        controlIdentifiers = identifiers
    }

    // MARK: - Editing

    private func assign(_ event: OEHIDEvent, to button: ControllerButton) {
        // A diagonal hat switch has no value of its own in the generic
        // profile, so it cannot be recorded; the next press will be.
        guard let player,
              let controllerDescription = device?.controllerDescription,
              let value = controllerDescription.controlValueDescription(for: event)
        else { return }

        player.assign(event, toKeyWithName: button.id)
        InputBindings.save()
        revision += 1
        recording = nil
        refreshControlIdentifiers()
        NSLog("[Cassowary] %@: %@ → %@", systemName, button.label, value.name)
    }

    private func clear(_ button: ControllerButton) {
        player?.removeEventForKey(withName: button.id)
        InputBindings.save()
        revision += 1
        refreshControlIdentifiers()
    }

    /// Put the plugin's defaults back: every control it ships is bound again,
    /// and everything else is left unbound.
    private func reset() {
        guard let player,
              let controller,
              let controllerDescription = device?.controllerDescription
        else { return }

        let defaults = controller.defaultDeviceControls[controllerDescription.identifier] ?? [:]

        // Clear everything first, so an old custom binding cannot survive on
        // a key the defaults do not mention.
        for name in controller.allKeyBindingsDescriptions.keys {
            player.removeEventForKey(withName: name)
        }

        // An axis or hat group names only one direction in the plugin's map,
        // so assigning the listed control binds the whole group, the opposite
        // direction included.
        for (name, identifier) in defaults {
            if let value = controllerDescription.controlValueDescription(forRepresentation: identifier) {
                player.assign(value.event, toKeyWithName: name)
            }
        }

        InputBindings.save()
        revision += 1
        refreshControlIdentifiers()
    }
}

/// Records the next controller press for one button.
private struct ControllerCaptureSheet: View {

    let button: ControllerButton
    let deviceName: String
    @ObservedObject var input: ControllerInputMonitor
    let onEvent: (OEHIDEvent) -> Void
    let onCancel: () -> Void

    /// A press is recorded once, even though the monitor keeps reporting the
    /// held control.
    @State private var captured = false

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("Press a Button")
                    .font(.headline)
                Text("This becomes \(button.label)'s control.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 32)

            VStack(spacing: 12) {
                Image(systemName: "gamecontroller")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Waiting for a button…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Press a button, trigger or stick direction on \(deviceName).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 8)

            Spacer()

            Button("Cancel", role: .cancel) { onCancel() }
                .padding(.bottom, 20)
        }
        .onAppear {
            input.onEvent = { event in
                guard !captured, ControllerInputMonitor.isPress(event) else { return }
                captured = true
                onEvent(event)
            }
        }
        .onDisappear { input.onEvent = nil }
        .presentationDetents([.medium])
    }
}
