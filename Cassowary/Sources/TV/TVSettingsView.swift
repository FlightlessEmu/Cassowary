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

/// The Apple TV's settings: which phone is connected, how much room the cache
/// may use, and what still needs to go home.
struct TVSettingsView: View {

    @ObservedObject private var store = TVStore.shared
    @StateObject private var catalog = CoreCatalog()
    @StateObject private var shaderCatalog = ShaderCatalog()
    @StateObject private var upscalingOptions = UpscalingOptions()

    private let budgets: [(String, Int64)] = [
        ("1 GB", 1 * 1024 * 1024 * 1024),
        ("2 GB", 2 * 1024 * 1024 * 1024),
        ("4 GB", 4 * 1024 * 1024 * 1024),
        ("8 GB", 8 * 1024 * 1024 * 1024),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("Phone") {
                    if case .connected(let host) = store.connection {
                        LabeledContent("Connected to", value: host.name)
                    } else {
                        Text("Not connected")
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("Saves to send", value: "\(store.pendingUploads)")

                    if let summary = store.syncSummary {
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Button("Sync Now") {
                        Task { await store.syncNow() }
                    }

                    Button("Disconnect and Forget", role: .destructive) {
                        store.forgetHost()
                    }
                }

                Section {
                    Picker("Video Filter", selection: globalShaderBinding) {
                        Text("None").tag(nil as String?)
                        ForEach(shaderCatalog.names, id: \.self) { name in
                            Text(name).tag(name as String?)
                        }
                    }
                    Picker("MetalFX Upscaling", selection: globalUpscalingBinding(.metalFX)) {
                        Text("Off").tag(false)
                        Text("On").tag(true)
                    }
                    Picker("Pixel Perfect Scaling", selection: globalUpscalingBinding(.integerScaling)) {
                        Text("Fill").tag(false)
                        Text("Pixel Perfect").tag(true)
                    }
                    Text("Applies to every game unless a system sets its own. A filter compiles the first time it is used, which takes a moment. MetalFX runs only on devices that support it; elsewhere the picture is drawn the normal way.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Video")
                }

                Section {
                    ForEach(budgets, id: \.1) { budget in
                        Button {
                            store.setCacheBudget(budget.1)
                        } label: {
                            HStack {
                                Text(budget.0)
                                Spacer()
                                if store.cacheBudget == budget.1 {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } header: {
                    Text("Downloaded Game Budget")
                } footer: {
                    Text("Used \(ByteCountFormatter.string(fromByteCount: store.cacheBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: store.cacheBudget, countStyle: .file)). Apple TV can remove downloaded games at any time; saves are kept separately and sent back to the phone.")
                }

                Section("Systems") {
                    ForEach(catalog.systems) { system in
                        NavigationLink {
                            TVSystemView(catalog: catalog,
                                         shaderCatalog: shaderCatalog,
                                         upscalingOptions: upscalingOptions,
                                         systemID: system.id)
                        } label: {
                            HStack(spacing: 12) {
                                SystemIconView(system: system, size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(system.name)
                                    Text(coreSummary(for: system))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    Text("Systems")
                } footer: {
                    Text("The default core is used when you start a game. Cover art comes from the source you borrow the game from.")
                }

                Section("About") {
                    Text("Apple TV is a borrower: it copies a game from the phone, plays it locally, and sends saves back. The phone has to stay open with sharing switched on while you play.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    LabeledContent("Systems", value: "\(catalog.systems.count)")
                    LabeledContent("Cores", value: "\(catalog.coreCount)")
                    LabeledContent("Version", value: appVersion)
                }

                Section("Cores") {
                    ForEach(installedCores) { core in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(core.displayName)
                            Text(AboutContent.licenseLine(coreID: core.id, version: core.version))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Each core is its authors' work and keeps its own license. Cassowary is an independent project, not affiliated with the OpenEmu Team; its engine is OpenEmu's work, used under its licenses.")
                }
            }
            .navigationTitle("Settings")
            .onAppear { catalog.refresh() }
        }
    }

    private var globalShaderBinding: Binding<String?> {
        Binding(
            get: { shaderCatalog.globalShaderName },
            set: { shaderCatalog.globalShaderName = $0 }
        )
    }

    private func globalUpscalingBinding(_ option: UpscalingOptions.Option) -> Binding<Bool> {
        Binding(
            get: { upscalingOptions.isOn(option) },
            set: { upscalingOptions.setOn($0, for: option) }
        )
    }

    private func coreSummary(for system: SystemEntry) -> String {
        if system.cores.isEmpty {
            return "No core installed"
        }
        if let id = catalog.defaultCoreID(forSystemIdentifier: system.id),
           let core = system.cores.first(where: { $0.id == id }) {
            return "Default: \(core.displayName)"
        }
        if system.cores.count == 1 {
            return system.cores[0].displayName
        }
        return "\(system.cores.count) cores · Automatic"
    }

    /// Distinct installed cores, sorted by name.
    private var installedCores: [CoreEntry] {
        var seen: [String: CoreEntry] = [:]
        for core in catalog.systems.flatMap(\.cores) {
            seen[core.id] = core
        }
        return seen.values.sorted { $0.displayName < $1.displayName }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    }
}
