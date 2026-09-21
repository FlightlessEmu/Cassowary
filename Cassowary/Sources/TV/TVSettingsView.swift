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

                Section("About") {
                    Text("Apple TV is a borrower: it copies a game from the phone, plays it locally, and sends saves back. The phone has to stay open with sharing switched on while you play.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
