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

/// Where the games come from.
///
/// The phone is one source; the demo game in the bundle is another; a network
/// share would be a third. The TV's own library stays put whatever happens to
/// a source, so this screen is about finding more games, not about holding the
/// library together.
struct TVConnectView: View {

    /// Shown when this screen is opened from the library, so there is a way
    /// back. When it is the whole app (nothing cached yet), there is nothing
    /// to go back to and no button is shown.
    var onClose: (() -> Void)?

    @ObservedObject private var store = TVStore.shared

    var body: some View {
        content
            .onAppear {
                store.start()
            }
    }

    private var content: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 44) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Sources")
                            .font(.system(size: 64, weight: .semibold))

                        switch store.connection {
                        case .connecting(let name):
                            Text("Connecting to \(name)…")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        case .failed(let message):
                            Text(message)
                                .font(.title3)
                                .foregroundStyle(.orange)
                        default:
                            Text("Where games come from. What you download stays on this Apple TV.")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !discovered.isEmpty {
                        section("On Your Network") {
                            ForEach(discovered) { host in
                                hostCard(name: host.name,
                                         detail: host.platformName == "tvos" ? "Apple TV" : "iPhone, iPad, or Mac",
                                         symbol: "wifi",
                                         subtitle: nil) {
                                    Task { await store.connect(to: host) }
                                }
                            }
                        }
                    }

                    if !remembered.isEmpty {
                        section("Remembered") {
                            ForEach(remembered) { host in
                                hostCard(name: host.name,
                                         detail: host.platformLabel,
                                         symbol: "wifi.slash",
                                         subtitle: "Not on this network right now") {
                                    store.note("\(host.name) is not on the network right now. Open Cassowary on it and turn on sharing.")
                                }
                                .contextMenu {
                                    Button("Forget \(host.name)", role: .destructive) {
                                        store.forgetHost(deviceID: host.deviceID)
                                    }
                                }
                            }
                        }
                    }

                    if store.browser.hosts.isEmpty, remembered.isEmpty {
                        HStack(spacing: 16) {
                            ProgressView()
                            Text("Looking for Cassowary on your network…")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }

                    Text("Sharing has to be switched on in the phone's settings, and the phone has to stay open while the Apple TV uses it. The demo game that ships with the app is already in the library. A network share on your home server can be another source later.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 1100, alignment: .leading)
                }
                .padding(80)
            }
        }
        .overlay(alignment: .topLeading) {
            if let onClose {
                Button("Close", action: onClose)
                    .padding(40)
            }
        }
    }

    // MARK: - Pieces

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title)
                .font(.title2.weight(.semibold))
            HStack(spacing: 32) {
                content()
            }
        }
    }

    private func hostCard(name: String,
                          detail: String,
                          symbol: String,
                          subtitle: String?,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                    .frame(height: 56)

                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.title3.weight(.semibold))
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .frame(width: 300, height: 200, alignment: .leading)
            .padding(24)
            .background(.quaternary, in: .rect(cornerRadius: 24))
        }
        .buttonStyle(.card)
    }

    /// Hosts the browser can see right now, other than the one connected.
    private var discovered: [FoundHost] {
        store.browser.hosts.filter { host in
            if case .connected(let connected) = store.connection, connected.deviceID == host.deviceID {
                return false
            }
            return true
        }
    }

    /// Hosts this TV has used before that are not around at the moment.
    private var remembered: [TVStore.KnownHost] {
        store.knownHosts.filter { known in
            !store.browser.hosts.contains { $0.deviceID == known.deviceID }
        }
    }
}
