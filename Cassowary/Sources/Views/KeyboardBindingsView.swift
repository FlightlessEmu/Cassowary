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
import GameController
import OpenEmuSystem
import OpenEmuKit

/// Remaps the keys one system's buttons answer to.
///
/// The bindings are the engine's: `OEBindingsController` holds one
/// `OESystemBindings` per system, filled from the plugin's
/// `Keyboard-Mappings.plist` and persisted in `Default.oebindings`. Each row
/// shows its key as a keycap, and the keycap fills in while that key is held,
/// so a binding can be tried without starting a game.
struct KeyboardBindingsView: View {

    let systemID: String
    let systemName: String

    @State private var layout: ControllerLayout?
    @State private var controller: OESystemController?
    @State private var bindings: OESystemBindings?
    @State private var recording: ControllerButton?
    @State private var loadMessage: String?

    /// Bumped after every edit; the bindings are plain Objective-C objects, so
    /// this is what tells SwiftUI the row text has changed.
    @State private var revision = 0

    /// The live keyboard, for the pressed-key highlight.
    @StateObject private var input = KeyboardInputMonitor()

    var body: some View {
        Group {
            if let layout, let bindings {
                List {
                    ForEach(Array(layout.groups.enumerated()), id: \.offset) { _, group in
                        Section {
                            ForEach(group) { button in
                                row(button, in: bindings)
                            }
                        }
                    }

                    Section {
                        Button("Restore Defaults") { reset() }
                            .disabled(!isCustomized)
                    } footer: {
                        Text("Tap a button and press a key to record it. Swipe left on a button to clear its key. \"—\" means the button has no key.")
                    }
                }
                .id(revision)
            } else {
                ContentUnavailableView {
                    Label("No Keyboard Map", systemImage: "keyboard")
                } description: {
                    Text(loadMessage ?? "This system does not describe any controls.")
                }
            }
        }
        .navigationTitle(systemName)
        .navigationBarTitleDisplayMode(.inline)
        .background {
            // The UIKit half of the keyboard: GameController can miss keys on
            // its own, and the capture sheet reads through the same monitor.
            KeyboardKeyCaptureView { keyCode, isDown in
                input.handle(keyCode: keyCode, isDown: isDown)
            }
        }
        .task {
            load()
            input.start()
        }
        .onDisappear { input.stop() }
        .sheet(item: $recording) { button in
            KeyCaptureSheet(button: button, input: input) { keyCode in
                assign(keyCode, to: button)
            } onCancel: {
                recording = nil
            }
        }
    }

    // MARK: - Rows

    private func row(_ button: ControllerButton, in bindings: OESystemBindings) -> some View {
        Button {
            recording = button
        } label: {
            HStack {
                Text(button.label)
                Spacer()
                keyBadge(for: button)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button("Clear") { clear(button) }
                .tint(.gray)
                .disabled(keyCode(for: button) == nil)
        }
    }

    /// The bound key as a keycap. It fills in while the key is down, which is
    /// the settings-side equivalent of a button lighting up in a game.
    private func keyBadge(for button: ControllerButton) -> some View {
        let pressed = isDown(button)

        return Text(keyName(for: button) ?? "—")
            .font(.caption.weight(.semibold))
            .foregroundStyle(pressed ? Color.white : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(pressed ? Color.accentColor : Color(uiColor: .secondarySystemFill), in: Capsule())
            .animation(.easeOut(duration: 0.09), value: pressed)
    }

    // MARK: - Reading the bindings

    private var player: OEKeyboardPlayerBindings? {
        bindings?.keyboardPlayerBindings(forPlayer: 1)
    }

    private func keyCode(for button: ControllerButton) -> Int? {
        guard let player,
              let description = controller?.keyBindingsDescriptions[button.id],
              let event = player.bindingEvents[description]
        else { return nil }

        return Int(event.keycode)
    }

    private func keyName(for button: ControllerButton) -> String? {
        keyCode(for: button).map(KeyboardKey.name(for:))
    }

    /// Whether the button's key is held right now.
    private func isDown(_ button: ControllerButton) -> Bool {
        guard let keyCode = keyCode(for: button) else { return false }
        return input.pressedKeys.contains(keyCode)
    }

    private var isCustomized: Bool {
        guard let player, let controller else { return false }

        let defaults = controller.defaultKeyboardControls ?? [:]
        for (description, event) in player.bindingEvents {
            guard let usage = defaults[description.name]?.uint32Value else { return true }
            if Int(usage) != Int(event.keycode) { return true }
        }
        return false
    }

    // MARK: - Editing

    private func load() {
        guard bindings == nil else { return }

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
        guard let systemBindings = InputBindings.systemBindings(for: plugin) else {
            loadMessage = "The \(systemName) bindings could not be created."
            return
        }

        controller = systemController
        layout = controlLayout
        bindings = systemBindings
    }

    private func assign(_ keyCode: Int, to button: ControllerButton) {
        guard let player,
              let event = InputBindings.keyEvent(keyCode: keyCode, isDown: true)
        else { return }

        player.assign(event, toKeyWithName: button.id)
        InputBindings.save()
        revision += 1
        recording = nil
        NSLog("[Cassowary] %@: %@ → %@", systemName, button.label, KeyboardKey.name(for: keyCode))
    }

    private func clear(_ button: ControllerButton) {
        player?.removeEventForKey(withName: button.id)
        InputBindings.save()
        revision += 1
    }

    /// Put the plugin's defaults back: every key it ships gets its key again,
    /// and everything else is left unbound.
    private func reset() {
        guard let player, let controller else { return }

        let defaults = controller.defaultKeyboardControls ?? [:]
        for name in controller.keyBindingsDescriptions.keys {
            if let usage = defaults[name]?.uint32Value,
               let event = InputBindings.keyEvent(keyCode: Int(usage), isDown: true) {
                player.assign(event, toKeyWithName: name)
            } else {
                player.removeEventForKey(withName: name)
            }
        }

        InputBindings.save()
        revision += 1
    }
}

/// Records the next key press for one button.
private struct KeyCaptureSheet: View {

    let button: ControllerButton
    @ObservedObject var input: KeyboardInputMonitor
    let onKey: (Int) -> Void
    let onCancel: () -> Void

    /// A key is recorded once, even though both keyboard sources report it.
    @State private var captured = false

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("Press a Key")
                    .font(.headline)
                Text("This becomes \(button.label)'s key.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 32)

            VStack(spacing: 12) {
                Image(systemName: "keyboard")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Waiting for a key…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Keys come from a hardware keyboard.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 8)

            Spacer()

            Text("Escape cancels.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button("Cancel", role: .cancel) { onCancel() }
                .padding(.bottom, 20)
        }
        .background {
            KeyboardKeyCaptureView { keyCode, isDown in
                guard isDown else { return }
                capture(keyCode)
            }
            .allowsHitTesting(false)
        }
        .onAppear {
            input.onKey = { keyCode, isDown in
                guard isDown else { return }
                capture(keyCode)
            }
        }
        .onDisappear { input.onKey = nil }
        .presentationDetents([.medium])
    }

    private func capture(_ keyCode: Int) {
        guard !captured else { return }

        if keyCode == GCKeyCode.escape.rawValue {
            onCancel()
        } else {
            captured = true
            onKey(keyCode)
        }
    }
}
