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

/// Settings → Share with Apple TV.
///
/// While sharing is on, the phone serves its library on the local network and
/// answers save questions. This screen is where the user turns it on, allows a
/// device in, and settles a save the two devices disagree about.
struct ShareSettingsView: View {

    @ObservedObject private var share = HostShareController.shared
    @ObservedObject private var trust = TrustStore.shared
    @ObservedObject private var sender = HostPeerSender.shared
    @AppStorage(SharingDefaults.deviceNameKey) private var deviceName = ""

    var body: some View {
        List {
            Section {
                Toggle("Share with Apple TV", isOn: Binding(
                    get: { share.isEnabled },
                    set: { share.setEnabled($0) }
                ))

                if share.isRunning {
                    LabeledContent("Status", value: "Sharing on this network")
                    LabeledContent("Devices allowed", value: "\(trust.peers.count)")
                    if share.pendingSaveCount > 0 {
                        LabeledContent("Saves to send", value: "\(share.pendingSaveCount)")
                    }
                }
            } footer: {
                Text("Your games stay on this device. The Apple TV copies one down before playing it, and sends saves back. Keep Cassowary open while you use the TV.")
            }

            if share.isRunning {
                Section("This Device") {
                    TextField("Name", text: Binding(
                        get: { deviceName.isEmpty ? DeviceIdentity.current.name : deviceName },
                        set: { deviceName = $0 }
                    ))
                    .autocorrectionDisabled()

                    Text("The name the Apple TV shows when it looks for your library.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let action = share.lastAction {
                    Section {
                        Text(action)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    if trust.peers.isEmpty {
                        Text("No devices yet. On the Apple TV, open Cassowary and pick this iPhone.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(trust.peers) { peer in
                        HStack(spacing: 12) {
                            Image(systemName: peer.platformName == "tvos" ? "appletv" : "ipad.and.iphone")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(peer.name)
                                Text(peer.platformLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Forget", role: .destructive) {
                                trust.remove(deviceID: peer.deviceID)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    Text("Devices")
                } footer: {
                    Text("A device has to be allowed once. Forget it to ask again next time.")
                }

                if !share.conflicts.isEmpty {
                    Section {
                        ForEach(share.conflicts) { conflict in
                            conflictRow(conflict)
                        }
                    } header: {
                        Text("Saves to Choose")
                    } footer: {
                        Text("The same game was played on two devices before they synced. Pick the copy to keep — the other is kept as a backup when you choose both.")
                    }
                }

                if !share.transfers.isEmpty {
                    Section("Transfers") {
                        ForEach(share.transfers) { transfer in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(transfer.title)
                                ProgressView(value: transfer.progress)
                            }
                        }
                    }
                }

                Section {
                    if sender.browser.hosts.isEmpty {
                        Text("Look for another iPhone, iPad, or Mac running Cassowary with sharing on.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(sender.browser.hosts) { host in
                        Menu {
                            ForEach(share.games) { game in
                                Button(game.title) {
                                    Task { await sender.send(game: game, to: host) }
                                }
                            }
                        } label: {
                            Label("Send a Game to \(host.name)", systemImage: "paperplane")
                        }
                        .disabled(share.games.isEmpty || sender.sendingTo != nil)
                    }

                    if let sendingTo = sender.sendingTo {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Sending to \(sendingTo)")
                            ProgressView(value: sender.progress)
                        }
                    } else if let message = sender.message {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Send a Game")
                } footer: {
                    Text("Copies one of your games to another device that is sharing. The other device has to allow this one in first.")
                }
            }
        }
        .navigationTitle("Share with Apple TV")
        .onAppear {
            if share.isRunning { sender.start() }
        }
        .onDisappear {
            sender.stop()
        }
        .alert(item: $share.pendingPairing) { prompt in
            Alert(title: Text("\(prompt.request.deviceName) wants to connect"),
                  message: Text("Allow it to see your games and sync saves?"),
                  primaryButton: .default(Text("Allow")) {
                      share.resolvePairing(id: prompt.id, accept: true)
                  },
                  secondaryButton: .cancel(Text("Don't Allow")) {
                      share.resolvePairing(id: prompt.id, accept: false)
                  })
        }
    }

    private func conflictRow(_ conflict: SaveConflict) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(share.title(forGameID: conflict.gameID))
                .font(.headline)
            Text(conflict.title)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                versionCard(name: "This Device", meta: conflict.local)
                versionCard(name: peerName(for: conflict.remote.deviceID), meta: conflict.remote)
            }

            HStack {
                Button("Keep This Device") {
                    share.resolve(conflict, choice: .keepLocal)
                }
                Button("Keep the Other") {
                    share.resolve(conflict, choice: .keepRemote)
                }
                Button("Keep Both") {
                    share.resolve(conflict, choice: .keepBoth)
                }
            }
            .font(.callout)
        }
        .padding(.vertical, 4)
    }

    private func versionCard(name: String, meta: TransferProtocol.SaveBlobMeta) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.caption.weight(.semibold))
            Text(meta.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(ByteCountFormatter.string(fromByteCount: meta.size, countStyle: .file))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary, in: .rect(cornerRadius: 10))
    }

    private func peerName(for deviceID: String) -> String {
        trust.peer(withID: deviceID)?.name ?? "Other Device"
    }
}
