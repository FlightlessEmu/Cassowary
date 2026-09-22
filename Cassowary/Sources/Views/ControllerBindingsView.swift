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
/// resolves the controller's events through those same bindings. Players come
/// from the same stack: the first pad to connect is player 1, the next player
/// 2, and so on. With more than one pad connected a picker chooses whose
/// bindings the rows show. Each row shows the control bound to a button and
/// lights up while that control is held, so a remap can be tried without
/// starting a game.
struct ControllerBindingsView: View {

    let systemID: String
    let systemName: String

    @State private var layout: ControllerLayout?
    @State private var controller: OESystemController?
    @State private var systemBindings: OESystemBindings?

    /// Every connected pad, in the player order the bindings stack gave them.
    @State private var pads: [ControllerPad] = []

    /// The player whose pad the rows describe.
    @State private var selectedPlayer: UInt?

    @State private var recording: ControllerButton?
    @State private var loadMessage: String?

    /// Bumped after every edit; the bindings are plain Objective-C objects, so
    /// this is what tells SwiftUI the row text has changed.
    @State private var revision = 0

    /// The pads the missing-association heal below has already run for. The
    /// heal re-posts the device-add notification, which comes straight back
    /// into this screen's own observer — without this the screen would
    /// re-enter itself until the stack blows.
    @State private var healedDevices: Set<ObjectIdentifier> = []

    /// The control identifier bound to each button, for the live highlight.
    @State private var controlIdentifiers: [String: String] = [:]

    /// Kept alive while the screen is up: connecting or unplugging a
    /// controller has to reshuffle the rows.
    @State private var observers: [NSObjectProtocol] = []

    @StateObject private var input = ControllerInputMonitor()

    /// The pad the rows describe: the picked player's, or the first pad when
    /// nothing is picked yet.
    private var selectedPad: ControllerPad? {
        if let selectedPlayer, let pad = pads.first(where: { $0.playerNumber == selectedPlayer }) {
            return pad
        }
        return pads.first
    }

    private var player: OEDevicePlayerBindings? { selectedPad?.bindings }
    private var device: OEDeviceHandler? { selectedPad?.device }

    var body: some View {
        Group {
            if let layout, let pad = selectedPad {
                List {
                    Section {
                        // One pad needs no picker: it is the only thing the
                        // rows can describe.
                        if pads.count > 1 {
                            Picker("Controller", selection: $selectedPlayer) {
                                ForEach(pads) { pad in
                                    Text(pad.label).tag(Optional(pad.playerNumber))
                                }
                            }
                        } else {
                            padHeader(pad)
                        }
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
        .onChange(of: selectedPlayer) { _, _ in
            syncMonitor()
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

    /// The one connected pad: its name and the player the bindings stack gave it.
    private func padHeader(_ pad: ControllerPad) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(pad.name)
                Text(pad.playerLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
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

    /// Pick the pads the rows can describe, and start listening to the picked
    /// one.
    private func refreshDevice() {
        // iOS has no IOKit, and Catalyst's sandbox blocks it: the bridge is
        // what turns GameController's controllers into the devices the
        // bindings stack knows.
        OEiOSGameControllerManager.shared.start()

        let handlers = OEDeviceManager.shared.controllerDeviceHandlers
        NSLog("[Cassowary] bindings refresh for %@: %lu device handlers", systemID, UInt(handlers.count))

        // The bindings object can miss a pad: it was bridged before this
        // system's bindings existed, and no later add reached it. A pad with
        // no bindings has no player, so it cannot be listed. Run the same
        // association a device add would, then read again. The post is
        // synchronous and this screen observes it too, so `healedDevices`
        // keeps the re-entrant pass from posting again; by the time the outer
        // post returns every observer has run and the association resolves.
        healedDevices.formIntersection(Set(handlers.map { ObjectIdentifier($0) }))
        let unassociated = handlers.filter { handler in
            guard systemBindings?.player(for: handler) == 0 else { return false }
            return !healedDevices.contains(ObjectIdentifier(handler))
        }
        if let handler = unassociated.first {
            healedDevices.insert(ObjectIdentifier(handler))
            NSLog("[Cassowary] bindings refresh for %@: healing missing association", systemID)
            NotificationCenter.default.post(
                name: .OEDeviceManagerDidAddDeviceHandler,
                object: nil,
                userInfo: [OEDeviceManagerDeviceHandlerUserInfoKey: handler])
        }

        pads = connectedPads()

        // Keep the picked player while its pad is around; otherwise fall back
        // to the first pad, which is all there was before the picker existed.
        if !pads.contains(where: { $0.playerNumber == selectedPlayer }) {
            selectedPlayer = pads.first?.playerNumber
        }

        syncMonitor()
    }

    /// The connected pads, in the player order the bindings stack gave them.
    private func connectedPads() -> [ControllerPad] {
        guard let systemBindings else { return [] }

        return OEDeviceManager.shared.controllerDeviceHandlers
            .compactMap { handler in
                // 0 means the bindings object has no player for this pad.
                let playerNumber = systemBindings.player(for: handler)
                guard playerNumber > 0 else { return nil }
                return ControllerPad(
                    playerNumber: playerNumber,
                    device: handler,
                    bindings: systemBindings.devicePlayerBindings(for: handler))
            }
            .sorted { $0.playerNumber < $1.playerNumber }
    }

    /// Point the live highlight at the picked pad, and let the old one go.
    private func syncMonitor() {
        guard let pad = selectedPad else {
            input.stop()
            return
        }

        if input.handler !== pad.device {
            recording = nil
            input.stop()
            input.start(handler: pad.device)
        }

        // The controls are named per pad, so the highlight map follows the pick.
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

/// One connected pad, with the player the bindings stack gave it.
///
/// Players come from the stack, not from this screen: the first pad to connect
/// is player 1, the next player 2, and a pad keeps its player for as long as it
/// stays connected.
private struct ControllerPad: Identifiable {

    let playerNumber: UInt
    let device: OEDeviceHandler
    let bindings: OEDevicePlayerBindings

    var id: UInt { playerNumber }

    /// The name GameController reports for the pad.
    var name: String { device.product.isEmpty ? "Controller" : device.product }

    var playerLabel: String { "Player \(playerNumber)" }

    /// "Player 2 — DualSense Wireless Controller", for the picker.
    var label: String { "\(playerLabel) — \(name)" }
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
