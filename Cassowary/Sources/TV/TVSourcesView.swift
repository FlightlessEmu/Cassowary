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
/// The phone is one source; the demo game in the bundle is already in the
/// library; a network share would be a third. The TV's own library stays put
/// whatever happens to a source, so this screen is about finding more games,
/// not about holding the library together.
struct TVSourcesView: View {

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

                        if let name = store.connectingTo {
                            Text("Connecting to \(name)…")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        } else {
                            switch store.connection {
                            case .failed(let message):
                            Text(message)
                                .font(.title3)
                                .foregroundStyle(.orange)
                            default:
                                Text("Where games come from. Connect as many as you like; a game on more than one is listed once. What you download stays on this Apple TV.")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if !store.connectedHosts.isEmpty {
                        section("Connected") {
                            ForEach(store.connectedHosts) { host in
                                // Pressable so it can be focused: the menu on
                                // a long press is how one source is let go.
                                hostCard(name: host.name,
                                         detail: Self.deviceKind(host.platformName),
                                         symbol: "checkmark.circle.fill",
                                         symbolTint: .green,
                                         subtitle: nil) {
                                    store.note("Hold the button on \(host.name) to disconnect it or forget it.")
                                }
                                .contextMenu {
                                    Button("Disconnect \(host.name)") {
                                        store.disconnect(deviceID: host.deviceID)
                                    }
                                    Button("Forget \(host.name)", role: .destructive) {
                                        store.forgetHost(deviceID: host.deviceID)
                                    }
                                }
                            }
                        }
                    }

                    if !discovered.isEmpty {
                        section("On Your Network") {
                            ForEach(discovered) { host in
                                hostCard(name: host.name,
                                         detail: Self.deviceKind(host.platformName),
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

                    Text("Turn on Sharing in Cassowary on your iPhone, iPad or Mac, and keep the app open while the Apple TV is using it. Games you have downloaded play here even when it is away.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 1100, alignment: .leading)
                }
                .padding(80)
            }
        }
        .overlay(alignment: .topLeading) {
            EmptyView()
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

    /// A card in one of the lists. Without an action it is a plain label, so
    /// the connected source can be shown without being something to press.
    private func hostCard(name: String,
                          detail: String,
                          symbol: String,
                          symbolTint: Color = .secondary,
                          subtitle: String?,
                          action: (() -> Void)? = nil) -> some View {
        let card = VStack(alignment: .leading, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 44))
                .foregroundStyle(symbolTint)
                .frame(height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(symbolTint == .green ? .green : .orange)
                        .lineLimit(2)
                }
            }
        }
        .frame(width: 420, alignment: .leading)
        .frame(minHeight: 220, alignment: .topLeading)
        .padding(24)
        .background(.quaternary, in: .rect(cornerRadius: 24))

        return Group {
            if let action {
                Button(action: action) { card }
                    .buttonStyle(.card)
            } else {
                card
            }
        }
    }

    /// What kind of device a source is, from the platform it reports.
    private static func deviceKind(_ platformName: String) -> String {
        switch platformName {
        case "tvos": return "Apple TV"
        case "mac":  return "Mac"
        case "ios":  return "iPhone or iPad"
        default:     return "iPhone, iPad, or Mac"
        }
    }

    /// Hosts the browser can see right now, other than the connected ones.
    ///
    /// Discovery names a host by its Bonjour service name when the system
    /// hands back no TXT record, so a name is compared as well as an id.
    private var discovered: [FoundHost] {
        store.browser.hosts.filter { host in
            !store.connectedHosts.contains { $0.deviceID == host.deviceID || $0.name == host.name }
        }
    }

    /// Hosts this TV has used before that are neither connected nor on the
    /// network.
    private var remembered: [TVStore.KnownHost] {
        store.knownHosts.filter { known in
            !store.connectedHosts.contains { $0.deviceID == known.deviceID || $0.name == known.name }
                && !store.browser.hosts.contains { $0.deviceID == known.deviceID || $0.name == known.name }
        }
    }
}
