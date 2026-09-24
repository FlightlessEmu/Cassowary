// Copyright (c) 2026, Cassowary contributors
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the Cassowary contributors nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY Cassowary contributors ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL Cassowary contributors BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import SwiftUI

/// Default core and video picks for one system.
///
/// The phone's per-system screen with the TV's remote-friendly rows: the
/// keyboard and controller binding rows have no equivalent here — there is no
/// keyboard UI on tvOS, and controllers reach the game through the engine's
/// bridge untouched. Everything else reads and writes the same shared stores,
/// so a default core or filter picked here is honored by the phone too.
struct TVSystemView: View {

    @ObservedObject var catalog: CoreCatalog
    @ObservedObject var shaderCatalog: ShaderCatalog
    @ObservedObject var upscalingOptions: UpscalingOptions
    let systemID: String

    var body: some View {
        Group {
            if let system = catalog.system(forIdentifier: systemID) {
                List {
                    Section {
                        HStack(spacing: 14) {
                            SystemIconView(system: system, size: 52)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(system.name)
                                    .font(.title3.weight(.semibold))
                                Text(coreCountSummary(for: system))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Section {
                        Picker("Default Core", selection: defaultBinding(for: system)) {
                            Text("Automatic").tag(nil as String?)
                            ForEach(system.cores) { core in
                                Text(core.displayName).tag(core.id as String?)
                            }
                        }
                        .disabled(system.cores.isEmpty)
                    } footer: {
                        Text("Automatic uses the first installed core.")
                    }

                    Section {
                        Picker("Video Filter", selection: shaderChoiceBinding(for: system)) {
                            Text("Use Default").tag(ShaderCatalog.SystemChoice.automatic)
                            Text("None").tag(ShaderCatalog.SystemChoice.none)
                            ForEach(shaderCatalog.names, id: \.self) { name in
                                Text(name).tag(ShaderCatalog.SystemChoice.shader(name))
                            }
                        }
                        Picker("MetalFX Upscaling", selection: upscalingChoiceBinding(.metalFX, for: system)) {
                            Text("Use Default").tag(UpscalingOptions.Choice.automatic)
                            Text("Off").tag(UpscalingOptions.Choice.off)
                            Text("On").tag(UpscalingOptions.Choice.on)
                        }
                        Picker("Pixel Perfect Scaling", selection: upscalingChoiceBinding(.integerScaling, for: system)) {
                            Text("Use Default").tag(UpscalingOptions.Choice.automatic)
                            Text("Fill").tag(UpscalingOptions.Choice.off)
                            Text("Pixel Perfect").tag(UpscalingOptions.Choice.on)
                        }
                    } header: {
                        Text("Video")
                    } footer: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shaderSummary(for: system))
                            Text(upscalingSummary(for: system))
                        }
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

    private func coreCountSummary(for system: SystemEntry) -> String {
        if system.cores.isEmpty { return "No core installed" }
        if system.cores.count == 1 { return "1 core installed" }
        return "\(system.cores.count) cores installed"
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

    private func upscalingChoiceBinding(_ option: UpscalingOptions.Option, for system: SystemEntry) -> Binding<UpscalingOptions.Choice> {
        Binding(
            get: { upscalingOptions.choice(for: option, system: system.id) },
            set: { upscalingOptions.setChoice($0, for: option, system: system.id) }
        )
    }

    /// Two lines explaining what this system will actually do for upscaling.
    private func upscalingSummary(for system: SystemEntry) -> String {
        "MetalFX: \(upscalingOptions.summary(.metalFX, forSystem: system.id))\nPixel Perfect: \(upscalingOptions.summary(.integerScaling, forSystem: system.id))"
    }
}
