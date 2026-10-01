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
import OpenEmuKit

/// Lets the TV user pick which core to play a game with.
///
/// The phone's `CorePickerSheet` with the TV's game type: shown when a system
/// has more than one installed core and no default is set. Picking offers to
/// remember the choice as the default, so the sheet only appears until there
/// is a preference. The default lives in `CoreCatalog`, shared with the phone.
struct TVCorePickerView: View {

    @ObservedObject var catalog: CoreCatalog
    let game: TVStore.LocalGame
    let system: SystemEntry

    @State private var selectionID: String?
    @State private var rememberDefault = true

    @Environment(\.dismiss) private var dismiss

    let onPlay: (OECorePlugin) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(system.cores) { core in
                        Button {
                            selectionID = core.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(core.displayName)
                                            .foregroundStyle(.primary)
                                        if core.id == catalog.defaultCoreID(forSystemIdentifier: system.id) {
                                            Text("Default")
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(.blue.opacity(0.15), in: .capsule)
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                    if !core.version.isEmpty {
                                        Text("Version \(core.version)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if core.id == selectionID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Play \(game.title) with")
                } footer: {
                    Text("\(system.name) has \(system.cores.count) core\(system.cores.count == 1 ? "" : "s") installed. The default is used automatically next time.")
                }

                Section {
                    Toggle("Remember as default", isOn: $rememberDefault)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Play") { play() }
                        .fontWeight(.semibold)
                        .disabled(selectionID == nil)
                }
            }
            .onAppear {
                selectionID = catalog.preferredCore(forSystemIdentifier: system.id)?.id
            }
        }
    }

    private func play() {
        guard let id = selectionID,
              let core = system.cores.first(where: { $0.id == id }) else { return }
        if rememberDefault {
            catalog.setDefaultCore(core.id, forSystemIdentifier: system.id)
        }
        onPlay(core.plugin)
    }
}
