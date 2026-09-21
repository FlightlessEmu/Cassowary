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

/// Picks a system to remap the keyboard for.
///
/// The keys are per system because the buttons are: Game Boy has eight
/// controls, the N64 has analog C buttons, and the ColecoVision has a number
/// pad of its own. Listing the systems here keeps the binding editor one tap
/// away from the system it belongs to.
struct KeyboardBindingsView: View {

    @ObservedObject var catalog: CoreCatalog

    /// "8 keys · Defaults" and friends, built once per visit: reading every
    /// plugin's control list on every row redraw would be wasteful.
    @State private var summaries: [String: String] = [:]

    var body: some View {
        List {
            Section {
                ForEach(catalog.systems) { system in
                    NavigationLink {
                        SystemKeyboardBindingsView(systemID: system.id, systemName: system.name)
                    } label: {
                        HStack(spacing: 12) {
                            SystemIconView(system: system, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(system.name)
                                Text(summaries[system.id] ?? " ")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } footer: {
                Text("These keys work while a game is running. Each system starts with the defaults from its own plugin.")
            }
        }
        .navigationTitle("Keyboard")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            catalog.refresh()
            refreshSummaries()
        }
    }

    private func refreshSummaries() {
        var summaries: [String: String] = [:]

        for system in catalog.systems {
            guard let plugin = OESystemPlugin.allPlugins.first(where: { $0.systemIdentifier == system.id }) else {
                summaries[system.id] = "Not installed"
                continue
            }

            let layout = ControllerLayout(systemPlugin: plugin)
            guard layout.hasButtons else {
                summaries[system.id] = "No controls to bind"
                continue
            }

            let bindings = KeyboardBindings(systemPlugin: plugin, layout: layout)
            let keys = bindings.boundCount == 1 ? "1 key" : "\(bindings.boundCount) keys"
            summaries[system.id] = bindings.isCustomized ? "\(keys) · Customized" : "\(keys) · Defaults"
        }

        self.summaries = summaries
    }
}

/// The buttons of one system, each with the key that drives it.
struct SystemKeyboardBindingsView: View {

    let systemID: String
    let systemName: String

    @State private var bindings: KeyboardBindings?
    @State private var recording: ControllerButton?
    @State private var loadMessage: String?

    var body: some View {
        Group {
            if let bindings {
                List {
                    ForEach(Array(bindings.layout.groups.enumerated()), id: \.offset) { _, group in
                        Section {
                            ForEach(group) { button in
                                row(button, in: bindings)
                            }
                        }
                    }

                    Section {
                        Button("Restore Defaults") { reset() }
                            .disabled(!bindings.isCustomized)
                    } footer: {
                        Text("Press a button to record a new key for it. Swipe left on a button to clear its key. \"—\" means the button has no key.")
                    }
                }
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
        .task { load() }
        .sheet(item: $recording) { button in
            KeyCaptureSheet(button: button) { keyCode in
                assign(keyCode, to: button)
            } onCancel: {
                recording = nil
            }
        }
    }

    // MARK: - Rows

    private func row(_ button: ControllerButton, in bindings: KeyboardBindings) -> some View {
        Button {
            recording = button
        } label: {
            HStack {
                Text(button.label)
                Spacer()
                Text(bindings.keyName(for: button))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button("Clear") { clear(button) }
                .tint(.gray)
                .disabled(bindings.keyCode(for: button) == nil)
        }
    }

    // MARK: - Editing

    private func load() {
        guard bindings == nil else { return }

        guard let plugin = OESystemPlugin.allPlugins.first(where: { $0.systemIdentifier == systemID }) else {
            loadMessage = "The \(systemName) system plugin is not installed."
            return
        }

        let layout = ControllerLayout(systemPlugin: plugin)
        guard layout.hasButtons else {
            loadMessage = "The \(systemName) system plugin does not describe any buttons."
            return
        }
        bindings = KeyboardBindings(systemPlugin: plugin, layout: layout)
    }

    private func assign(_ keyCode: Int, to button: ControllerButton) {
        guard var current = bindings else { return }
        current.assign(keyCode, to: button)
        bindings = current
        recording = nil
        NSLog("[Cassowary] %@: %@ → %@", systemName, button.label, KeyboardKey.name(for: keyCode))
    }

    private func clear(_ button: ControllerButton) {
        guard var current = bindings else { return }
        current.clear(button)
        bindings = current
    }

    private func reset() {
        guard var current = bindings else { return }
        current.reset()
        bindings = current
    }
}

/// Records the next key press for one button.
private struct KeyCaptureSheet: View {

    let button: ControllerButton
    let onKey: (Int) -> Void
    let onCancel: () -> Void

    @State private var capture = KeyboardCapture()

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

            Group {
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
            // Both keyboard sources feed the one handler: the first real key
            // press binds, whichever source delivers it.
            KeyboardKeyCaptureView(
                onKey: { keyCode, isDown in
                    guard isDown else { return }
                    captureKey(keyCode)
                }
            )
            .allowsHitTesting(false)
        }
        .onAppear {
            capture.start { captureKey($0) }
        }
        .onDisappear { capture.stop() }
        .presentationDetents([.medium])
    }

    private func captureKey(_ keyCode: Int) {
        if keyCode == GCKeyCode.escape.rawValue {
            onCancel()
        } else {
            onKey(keyCode)
        }
    }
}

/// Watches the hardware keyboard for the next key press.
///
/// This is the settings-side counterpart of `KeyboardControlManager`: an
/// actual key is used, so a remap can never be a key the keyboard cannot
/// report.
@MainActor
final class KeyboardCapture {

    private var input: GCKeyboardInput?
    private var observers: [NSObjectProtocol] = []
    private var handler: ((Int) -> Void)?

    func start(_ handler: @escaping (Int) -> Void) {
        self.handler = handler

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in
            onMain { self?.attach() }
        })
        observers.append(center.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            onMain { self?.detach() }
        })

        attach()
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        detach()
        handler = nil
    }

    private func attach() {
        guard input == nil, let keyboard = GCKeyboard.coalesced?.keyboardInput else { return }

        input = keyboard
        keyboard.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            guard pressed else { return }
            onMain { self?.handler?(keyCode.rawValue) }
        }
    }

    private func detach() {
        input?.keyChangedHandler = nil
        input = nil
    }
}
