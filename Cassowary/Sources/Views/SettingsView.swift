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
import CoreHaptics

private enum SettingsPane: String, CaseIterable, Identifiable {
    case controls, video, library, sharing, systems, about, diagnostics
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .controls: return "gamecontroller"
        case .video: return "display"
        case .library: return "square.grid.2x2"
        case .sharing: return "appletv"
        case .systems: return "cpu"
        case .about: return "info.circle"
        case .diagnostics: return "stethoscope"
        }
    }
}

/// App settings: default core per system, and what is installed.
///
/// The per-system default is what the library launches with and what the
/// core picker offers to remember. As more cores are ported, they appear
/// here with no further UI work.
struct SettingsView: View {

    @StateObject private var catalog = CoreCatalog()
    @StateObject private var shaderCatalog = ShaderCatalog()
    @StateObject private var upscalingOptions = UpscalingOptions()
    @StateObject private var tester = PreviewPressHandler()
    @AppStorage("cassowary.padStyle") private var styleRaw: String = DPadStyle.buttons.rawValue
    @AppStorage("cassowary.buttonTheme") private var themeRaw: String = ButtonTheme.glass.rawValue
    @AppStorage(DirectionRepeat.enabledKey) private var repeatEnabled = false
    @AppStorage(DirectionRepeat.rateKey) private var repeatRate = DirectionRepeat.defaultRate
    @AppStorage(ButtonHaptics.enabledKey) private var hapticsEnabled = true
    @AppStorage(ButtonHaptics.styleKey) private var hapticStyle = "light"

#if targetEnvironment(macCatalyst)
    @AppStorage("cassowary.settingsPane") private var paneRaw = SettingsPane.video.rawValue
    private var pane: SettingsPane { SettingsPane(rawValue: paneRaw) ?? .video }
#endif

    @Environment(\.dismiss) private var dismiss

    /// A page opened straight away, for screenshots and UI checks: "bios", or
    /// a system identifier for that system's page. Only set from the command
    /// line (-cassowary.settingsPage).
    @State private var openedPage: String?
    @State private var didOpenLaunchPage = false

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

    private func globalUpscalingBinding(_ option: UpscalingOptions.Option) -> Binding<Bool> {
        Binding(
            get: { upscalingOptions.isOn(option) },
            set: { upscalingOptions.setOn($0, for: option) }
        )
    }

    var body: some View {
#if targetEnvironment(macCatalyst)
        HStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(SettingsPane.allCases) { item in
                        Button {
                            paneRaw = item.rawValue
                        } label: {
                            Label(item.title, systemImage: item.symbol)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .foregroundStyle(pane == item ? Color.white : Color.primary)
                                .background(pane == item ? Color.accentColor : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(pane == item ? .isSelected : [])
                    }
                }
                .padding(10)
            }
            .frame(width: 170)
            Divider()
            NavigationStack { settingsContent }
                .id(pane)
        }
        .background { CatalystSettingsWindow() }
#else
        NavigationStack { settingsContent }
#endif
    }

    private var settingsContent: some View {
        List {
            if showsPane(.controls) {
                Section {
                    Picker("D-Pad Style", selection: styleBinding) {
                        ForEach(DPadStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    Text((DPadStyle(rawValue: styleRaw) ?? .buttons).blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // The button pad and the cross both retrigger a held
                    // direction; the thumbstick follows the finger instead.
                    if selectedStyle != .stick {
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

#if !targetEnvironment(macCatalyst)
                    if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
                        Toggle("Button Haptics", isOn: $hapticsEnabled)

                        if hapticsEnabled {
                            Picker("Haptic Strength", selection: $hapticStyle) {
                                Text("Light").tag("light")
                                Text("Medium").tag("medium")
                                Text("Heavy").tag("heavy")
                            }
                            .pickerStyle(.segmented)
                        }

                        Text("Buzzes the phone when an on-screen button is pressed. Try it on the pad below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
#endif

                    // Dark stage, like a running game: Glass is white-on-dark
                    // and would wash out against the white Settings row.
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.black)
                        VStack(spacing: 10) {
                            ControlPreview(style: selectedStyle, theme: selectedTheme, handler: tester)
                                .environment(\.colorScheme, .dark)
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
                    Text("On-Screen Controls")
                }

            }
            if showsPane(.video) {
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
                    Text("Applies to every game unless a system sets its own below. A filter compiles the first time it is used, which takes a moment. MetalFX runs only on devices that support it; elsewhere the picture is drawn the normal way.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Video")
                }

            }
            if showsPane(.library) {
                Section {
                    NavigationLink {
                        CoverArtSettingsView()
                    } label: {
                        Label("Cover Art", systemImage: "photo.on.rectangle.angled")
                    }
                    NavigationLink {
                        BIOSSettingsView(catalog: catalog)
                    } label: {
                        LabeledContent {
                            Text(biosSummary)
                        } label: {
                            Label("BIOS Files", systemImage: "memorychip")
                        }
                    }
                } header: {
                    Text("Library")
                } footer: {
                    Text("Cassowary can download cover art for your games from libretro-thumbnails and ScreenScraper. BIOS files dropped on the library are checked and filed where the cores look.")
                }

            }
            if showsPane(.sharing) {
                Section {
                    NavigationLink {
                        ShareSettingsView()
                    } label: {
                        Label("Share with Apple TV", systemImage: "appletv")
                    }
                } header: {
                    Text("Sharing")
                } footer: {
                    Text("Serve your games to an Apple TV on the same network. The TV copies a game before playing it and sends saves back. Keep this app open while you play.")
                }

            }
            if showsPane(.systems) {
                Section {
                    NavigationLink {
                        RetroAchievementsSettingsView()
                    } label: {
                        Label("Achievements", systemImage: "trophy")
                    }
                } header: {
                    Text("RetroAchievements")
                } footer: {
                    Text("Sign in with a free retroachievements.org account to earn achievements and leaderboards in supported cores.")
                }

                Section {
                    ForEach(catalog.systems) { system in
                        NavigationLink {
                            SystemCoresView(catalog: catalog, shaderCatalog: shaderCatalog, upscalingOptions: upscalingOptions, systemID: system.id)
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
#if targetEnvironment(macCatalyst)
                    Text("The default core is used when you open a game. Right-click a game for Play With… to pick a different core once.")
#else
                    Text("The default core is used when you tap a game. Long-press a game for Play With… to pick a different core once.")
#endif
                }

            }
            if showsPane(.about) {
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
            if showsPane(.diagnostics) {
                Section {
                    NavigationLink {
                        DiagnosticsView(store: .shared)
                    } label: {
                        Label("Crash & Hang Reports", systemImage: "stethoscope")
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("See what the system has handed back about crashes and hangs, and the last game that did not close cleanly. Nothing leaves the device unless you share it.")
                }
            }
        }
#if targetEnvironment(macCatalyst)
        .navigationTitle(pane.title)
        .navigationBarTitleDisplayMode(.inline)
#else
        .navigationTitle("Settings")
        .toolbar {
            // Settings is a sheet, so it needs its own way out.
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
#endif
        .onAppear {
            catalog.refresh()
            if !didOpenLaunchPage {
                didOpenLaunchPage = true
                openedPage = UserDefaults.standard.string(forKey: "cassowary.settingsPage")
            }
        }
        .navigationDestination(item: $openedPage) { page in
            if page == "bios" {
                BIOSSettingsView(catalog: catalog)
            } else {
                SystemCoresView(catalog: catalog, shaderCatalog: shaderCatalog, upscalingOptions: upscalingOptions, systemID: page)
            }
        }
    }

    private func showsPane(_ candidate: SettingsPane) -> Bool {
#if targetEnvironment(macCatalyst)
        return pane == candidate
#else
        return true
#endif
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

    /// How many of the systems that need a BIOS have what they need.
    private var biosSummary: String {
        let requirements = catalog.systems.compactMap { BIOSCatalog.requirement(forSystemIdentifier: $0.id) }
            .filter { !$0.required.isEmpty }
        guard !requirements.isEmpty else { return "None needed" }
        return "\(requirements.filter(\.isReady).count) of \(requirements.count) ready"
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
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
                    Text("An independent emulator frontend for iPhone, iPad, and Mac. Not affiliated with, sponsored, or endorsed by the OpenEmu Team.")
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
                VStack(alignment: .leading, spacing: 4) {
                    Text("OpenEmuARM64")
                        .font(.headline)
                    Text("By bazley82. The first working Apple Silicon build of OpenEmu's ARM64-capable cores — the port the cores here descend from.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("OpenEmu-Silicon")
                        .font(.headline)
                    Text("The upstream fork this project grew out of, where the Metal renderer and the iOS core ports began. Thanks to its maintainers and contributors. Not affiliated with or endorsed by the OpenEmu Team.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("OpenEmu shader presets")
                        .font(.headline)
                    Text("The video filters — CRT Geom, CRT Royale Kurozumi, MAME HLSL, NTSC, VHS, and the rest — are the shader presets from the OpenEmu project, by their original authors (cgwg, Themaister, hunterk, TroggleMonkey, and others). The pixel-art scalers (Scale2x, Scale3x, 2xSaI, Super 2xSaI, Super Eagle, HQ2x, HQ3x, HQ4x) come from the libretro slang-shaders collection, by Andrea Mazzoleni, Derek Liauw Kie Fa, Maxim Stepin, and others. Each preset keeps its author's license: MIT, BSD-3-Clause, GPL, or LGPL.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shader compiler")
                        .font(.headline)
                    Text("The shader compiler in OpenEmuShaders bundles glslang (BSD-3-Clause and others), SPIRV-Tools, and SPIRV-Cross (both Apache-2.0), by the Khronos Group and contributors.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            } header: {
                Text("Video Filters")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cover art")
                        .font(.headline)
                    Text("Box art images are downloaded from libretro-thumbnails (thumbnails.libretro.com), and from ScreenScraper when an app key is set up. The images are the games' publishers' work; those services only collect and serve them, under their own terms.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            } header: {
                Text("Artwork")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("RetroAchievements")
                        .font(.headline)
                    Text("Achievements, leaderboards, and rich presence come from RetroAchievements (retroachievements.org) through its rcheevos client library. Progress earned while signed in is reported to their servers under their terms.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            } header: {
                Text("Achievements")
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
                Text("Each core is its authors' work and keeps its own license; the license is listed beside each one. Some cores allow non-commercial use only — never charge for a build that includes them.")
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

    /// Known core licenses by bundle identifier. Shared with the TV app: see
    /// `AboutContent.coreLicenses`.
    private func licenseLine(for core: CoreEntry) -> String {
        AboutContent.licenseLine(coreID: core.id, version: core.version)
    }
}
