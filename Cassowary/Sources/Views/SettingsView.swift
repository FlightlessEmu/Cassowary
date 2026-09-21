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
    @StateObject private var shaderCatalog = ShaderCatalog()
    @StateObject private var tester = PreviewPressHandler()
    @AppStorage("cassowary.padStyle") private var styleRaw: String = DPadStyle.buttons.rawValue
    @AppStorage("cassowary.buttonTheme") private var themeRaw: String = ButtonTheme.glass.rawValue
    @AppStorage(DirectionRepeat.enabledKey) private var repeatEnabled = false
    @AppStorage(DirectionRepeat.rateKey) private var repeatRate = DirectionRepeat.defaultRate

    private var selectedStyle: DPadStyle { DPadStyle(rawValue: styleRaw) ?? .buttons }
    private var selectedTheme: ButtonTheme { ButtonTheme(rawValue: themeRaw) ?? .glass }

    private var styleBinding: Binding<DPadStyle> {
        Binding(
            get: { DPadStyle(rawValue: styleRaw) ?? .buttons },
            set: { styleRaw = $0.rawValue }
        )
    }

    private var themeBinding: Binding<ButtonTheme> {
        Binding(
            get: { ButtonTheme(rawValue: themeRaw) ?? .glass },
            set: { themeRaw = $0.rawValue }
        )
    }

    private var globalShaderBinding: Binding<String?> {
        Binding(
            get: { shaderCatalog.globalShaderName },
            set: { shaderCatalog.globalShaderName = $0 }
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

                    // Only the D-Pad style retriggers a held direction, so the
                    // option only appears when that style is the one in use.
                    if selectedStyle == .dpad {
                        Toggle("Repeat While Held", isOn: $repeatEnabled)

                        if repeatEnabled {
                            HStack {
                                Text("Repeat Rate")
                                Spacer()
                                Text("\(Int(repeatRate.rounded())) / sec")
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $repeatRate, in: DirectionRepeat.rateRange, step: 1) {
                                Text("Repeat Rate")
                            } minimumValueLabel: {
                                Image(systemName: "tortoise")
                            } maximumValueLabel: {
                                Image(systemName: "hare")
                            }
                            .accessibilityValue("\(Int(repeatRate.rounded())) per second")
                        }

                        Text("Retriggers a held direction, for games that need repeated presses. Holding to walk may stutter.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Picker("Button Theme", selection: themeBinding) {
                        ForEach(ButtonTheme.allCases) { theme in
                            Text(theme.label).tag(theme)
                        }
                    }
                    Text((ButtonTheme(rawValue: themeRaw) ?? .glass).blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Dark stage, like a running game: Glass is white-on-dark
                    // and would wash out against the white Settings row.
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.black)
                        VStack(spacing: 10) {
                            ControlPreview(style: selectedStyle, theme: selectedTheme, handler: tester)
                            Text("Last: \(tester.lastLabel) · Presses: \(tester.pressCount)")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .padding(16)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)

                    Text("Try it — press the pad. Feel only, not connected to a game.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Controls")
                }

                Section {
                    Picker("Video Filter", selection: globalShaderBinding) {
                        Text("None").tag(nil as String?)
                        ForEach(shaderCatalog.names, id: \.self) { name in
                            Text(name).tag(name as String?)
                        }
                    }
                    Text("Applies to every game unless a system sets its own below. A filter compiles the first time it is used, which takes a moment.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Video")
                }

                Section {
                    ForEach(catalog.systems) { system in
                        NavigationLink {
                            SystemCoresView(catalog: catalog, shaderCatalog: shaderCatalog, systemID: system.id)
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
                    NavigationLink {
                        AboutView(catalog: catalog)
                    } label: {
                        Text("About Cassowary")
                    }
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
    @ObservedObject var shaderCatalog: ShaderCatalog
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

                    Section {
                        Picker("Video Filter", selection: shaderChoiceBinding(for: system)) {
                            Text("Use Default").tag(ShaderCatalog.SystemChoice.automatic)
                            Text("None").tag(ShaderCatalog.SystemChoice.none)
                            ForEach(shaderCatalog.names, id: \.self) { name in
                                Text(name).tag(ShaderCatalog.SystemChoice.shader(name))
                            }
                        }
                    } header: {
                        Text("Video")
                    } footer: {
                        Text(shaderSummary(for: system))
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

    private func shaderChoiceBinding(for system: SystemEntry) -> Binding<ShaderCatalog.SystemChoice> {
        Binding(
            get: { shaderCatalog.choice(forSystem: system.id) },
            set: { shaderCatalog.setChoice($0, forSystem: system.id) }
        )
    }

    /// One line explaining what this system will actually use.
    private func shaderSummary(for system: SystemEntry) -> String {
        let name = shaderCatalog.resolvedShaderName(forSystem: system.id)
        switch shaderCatalog.choice(forSystem: system.id) {
        case .automatic:
            return name.map { "Following the app-wide setting: \($0)." } ?? "Following the app-wide setting: none."
        case .none, .shader:
            return name.map { "\($0) is used for this system." } ?? "No filter for this system."
        }
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

/// What Cassowary is, who made the engine, and under what licenses.
///
/// Cassowary is an independent project with no affiliation with the OpenEmu
/// Team. Its emulation engine — the shared frameworks, the plugin design,
/// and the cores — is the OpenEmu project's work, used under its licenses.
struct AboutView: View {

    @ObservedObject var catalog: CoreCatalog

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cassowary")
                        .font(.title2.weight(.bold))
                    Text("An independent iOS emulator frontend. Not affiliated with, sponsored, or endorsed by the OpenEmu Team.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Engine") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("OpenEmu")
                        .font(.headline)
                    Text("By the OpenEmu Team. The shared frameworks, plugin architecture, renderer, and audio engine Cassowary runs on. Used under the BSD 3-Clause license.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("OpenEmu shader presets")
                        .font(.headline)
                    Text("The video filters — CRT Geom, CRT Royale Kurozumi, MAME HLSL, NTSC, VHS, and the rest — are the shader presets from the OpenEmu project, by their original authors (cgwg, Themaister, hunterk, TroggleMonkey, and others). They keep their authors' licenses: MIT, BSD-3-Clause, or GPL.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            } header: {
                Text("Video Filters")
            }

            Section {
                ForEach(installedCores) { core in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(core.displayName)
                        Text(licenseLine(for: core))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Cores")
            } footer: {
                Text("Each core is its authors' work and keeps its own license. Full texts ship with the core projects.")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { catalog.refresh() }
    }

    /// Distinct installed cores, sorted by name.
    private var installedCores: [CoreEntry] {
        var seen: [String: CoreEntry] = [:]
        for core in catalog.systems.flatMap(\.cores) {
            seen[core.id] = core
        }
        return seen.values.sorted { $0.displayName < $1.displayName }
    }

    /// Known core licenses by bundle identifier. Cores ported later get an
    /// entry here; anything unknown points at the core project.
    private func licenseLine(for core: CoreEntry) -> String {
        let license = Self.licenses[core.id] ?? "License: see the core project"
        if core.version.isEmpty {
            return license
        }
        return "Version \(core.version) · \(license)"
    }

    private static let licenses: [String: String] = [
        "org.openemu.Gambatte": "GPL-2.0-or-later (Gambatte-DMS)",
        "org.openemu.mGBA": "MPL-2.0 (mGBA)",
        // Non-commercial only: never charge for a build that includes these.
        "org.openemu.GenesisPlus": "Non-commercial (Genesis Plus GX)",
        "org.openemu.Picodrive": "Non-commercial (Picodrive)",
    ]
}
