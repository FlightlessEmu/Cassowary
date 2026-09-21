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

/// App settings: default core per system, and what is installed.
///
/// The per-system default is what the library launches with and what the
/// core picker offers to remember. As more cores are ported, they appear
/// here with no further UI work.
struct SettingsView: View {

    @StateObject private var catalog = CoreCatalog()
    @AppStorage("OEDPadStyle") private var styleRaw: String = DPadStyle.buttons.rawValue

    private var styleBinding: Binding<DPadStyle> {
        Binding(
            get: { DPadStyle(rawValue: styleRaw) ?? .buttons },
            set: { styleRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("D-Pad Style", selection: styleBinding) {
                        ForEach(DPadStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    Text((DPadStyle(rawValue: styleRaw) ?? .buttons).blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Controls")
                }

                Section {
                    ForEach(catalog.systems) { system in
                        NavigationLink {
                            SystemCoresView(catalog: catalog, systemID: system.id)
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
                    Text("The default core is used when you tap a game. Long-press a game for Play With… to pick a different core once.")
                }

                Section("About") {
                    LabeledContent("Systems", value: "\(catalog.systems.count)")
                    LabeledContent("Cores", value: "\(catalog.coreCount)")
                    LabeledContent("Version", value: appVersion)
                }
            }
            .navigationTitle("Settings")
            .onAppear { catalog.refresh() }
        }
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

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    }
}

/// Default-core picker and core list for one system.
private struct SystemCoresView: View {

    @ObservedObject var catalog: CoreCatalog
    let systemID: String

    var body: some View {
        Group {
            if let system = catalog.system(forIdentifier: systemID) {
                List {
                    Section {
                        Picker("Default Core", selection: defaultBinding(for: system)) {
                            Text("Automatic").tag(nil as String?)
                            ForEach(system.cores) { core in
                                Text(core.displayName).tag(core.id as String?)
                            }
                        }
                        .disabled(system.cores.isEmpty)
                    } footer: {
                        Text("Automatic uses the first installed core. This matches the macOS preference.")
                    }

                    if !system.cores.isEmpty {
                        Section("Installed Cores") {
                            ForEach(system.cores) { core in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(core.displayName)
                                    if !core.version.isEmpty {
                                        Text("Version \(core.version)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }

                    Section("File Types") {
                        Text(system.extensions.joined(separator: ", ").uppercased())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle(system.name)
                .navigationBarTitleDisplayMode(.inline)
            } else {
                ContentUnavailableView("No Longer Installed", systemImage: "exclamationmark.triangle")
            }
        }
        .onAppear { catalog.refresh() }
    }

    private func defaultBinding(for system: SystemEntry) -> Binding<String?> {
        Binding(
            get: { catalog.defaultCoreID(forSystemIdentifier: system.id) },
            set: { catalog.setDefaultCore($0, forSystemIdentifier: system.id) }
        )
    }
}

/// A system icon in a rounded tile, with a game-controller fallback.
struct SystemIconView: View {

    let system: SystemEntry
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(.quaternary)
            if let icon = system.icon {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.14)
            } else {
                Image(systemName: "gamecontroller")
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}
