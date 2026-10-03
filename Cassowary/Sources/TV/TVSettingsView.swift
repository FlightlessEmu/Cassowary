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

    #if DEBUG
    /// The system `TVScreenshotHooks.systemToOpen` asks for, pushed once.
    @State private var screenshotSystemID: String?
    @State private var screenshotBindingsID: String?
    #endif

    private let budgets: [(String, Int64)] = [
        ("1 GB", 1 * 1024 * 1024 * 1024),
        ("2 GB", 2 * 1024 * 1024 * 1024),
        ("4 GB", 4 * 1024 * 1024 * 1024),
        ("8 GB", 8 * 1024 * 1024 * 1024),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("Sources") {
                    if store.connectedHosts.isEmpty {
                        Text("Not connected")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.connectedHosts) { host in
                        LabeledContent("Connected to", value: host.name)
                    }

                    LabeledContent("Last synced", value: lastSyncedText)
                    LabeledContent("Saves to send", value: "\(store.pendingUploads)")
                    if store.savesWaitingElsewhere > 0 {
                        // Saves for games this phone does not have: they go
                        // to the device the game came from when it is back.
                        LabeledContent("Waiting for another device", value: "\(store.savesWaitingElsewhere)")
                    }

                    if let summary = store.syncSummary {
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await store.syncNow() }
                    } label: {
                        HStack {
                            Text(store.isSyncing ? "Syncing…" : "Sync Now")
                            if store.isSyncing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(store.isSyncing || !store.connection.isConnected)

                    // Red text, not a red button: tvOS draws a destructive
                    // button red on red.
                    ForEach(store.connectedHosts) { host in
                        Button("Forget \(host.name)") {
                            store.forgetHost(deviceID: host.deviceID)
                        }
                        .foregroundStyle(.red)
                    }
                }

                Section {
                    if let account = store.retroAchievementsAccount {
                        LabeledContent("Signed in as", value: account)
                        LabeledContent("Hardcore", value: RetroAchievementsCredentialStore.hardcoreEnabled ? "On" : "Off")
                    } else {
                        Text("Not signed in")
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Use the Phone's Sign-In", isOn: Binding(
                        get: { store.usesSharedRetroAchievements },
                        set: { store.setUsesSharedRetroAchievements($0) }
                    ))
                } header: {
                    Text("RetroAchievements")
                } footer: {
                    Text(retroAchievementsFooter)
                }

                Section {
                    // A list of its own: inline, tvOS squeezes every filter
                    // into one segmented row and cuts each name to "…".
                    Picker("Video Filter", selection: globalShaderBinding) {
                        Text("None").tag(nil as String?)
                        ForEach(shaderCatalog.names, id: \.self) { name in
                            Text(name).tag(name as String?)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    Toggle("MetalFX Upscaling", isOn: globalUpscalingBinding(.metalFX))
                    Toggle("Pixel Perfect Scaling", isOn: globalUpscalingBinding(.integerScaling))
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
                    Text("Used \(store.cacheBytes.formatted(.byteCount(style: .file))) of \(store.cacheBudget.formatted(.byteCount(style: .file))). Apple TV can remove downloaded games at any time; saves are kept separately and sent back to the phone.")
                }

                Section {
                    ForEach(catalog.systems) { system in
                        NavigationLink {
                            SystemCoresView(catalog: catalog,
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

                Section {
                    ForEach(installedCores) { core in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(core.displayName)
                            Text(AboutContent.licenseLine(coreID: core.id, version: core.version))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Cores")
                } footer: {
                    Text("Each core is its authors' work and keeps its own license. Cassowary is an independent project, not affiliated with the OpenEmu Team; its engine is OpenEmu's work, used under its licenses.")
                }
            }
            .navigationTitle("Settings")
            .onAppear { catalog.refresh() }
            #if DEBUG
            .navigationDestination(item: $screenshotSystemID) { id in
                SystemCoresView(catalog: catalog, shaderCatalog: shaderCatalog,
                                upscalingOptions: upscalingOptions, systemID: id)
            }
            .navigationDestination(item: $screenshotBindingsID) { id in
                ControllerBindingsView(systemID: id,
                                       systemName: catalog.system(forIdentifier: id)?.name ?? id)
            }
            .task {
                screenshotSystemID = TVScreenshotHooks.systemToOpen
                screenshotBindingsID = TVScreenshotHooks.bindingsToOpen
            }
            #endif
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
        return seen.values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var retroAchievementsFooter: String {
        if let source = store.retroAchievementsSource {
            return "Shared by \(source). Change the account or hardcore there; this Apple TV picks it up the next time it syncs."
        }
        if !store.usesSharedRetroAchievements {
            return "Games here play without achievements."
        }
        return "To earn achievements here, sign in to RetroAchievements in Cassowary on your iPhone, then turn on Share With Apple TV in its Achievements settings."
    }

    private var lastSyncedText: String {
        guard let date = store.lastSyncedAt else { return "Not yet" }
        return date.formatted(.relative(presentation: .named))
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    }
}
