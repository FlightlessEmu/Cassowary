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

/// Finding the phone.
///
/// A host advertises itself on the network, so this is a list of what is
/// around, not a place to type addresses. The phone has to be open with
/// sharing switched on; the hint below says so when nothing turns up.
struct TVConnectView: View {

    @ObservedObject private var store = TVStore.shared

    @State private var demos: [TVDemoGame] = []
    @State private var playingDemo: TVDemoGame?

    var body: some View {
        Group {
            if let playingDemo {
                TVPlayerView(title: playingDemo.title, url: playingDemo.url) {
                    self.playingDemo = nil
                }
            } else {
                content
            }
        }
        .onAppear {
            store.start()
            demos = TVDemoLibrary.load()
        }
    }

    private var content: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 48) {
                VStack(spacing: 12) {
                    Text("Cassowary")
                        .font(.system(size: 76, weight: .semibold))

                    switch store.connection {
                    case .connecting(let name):
                        Text("Connecting to \(name)…")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    case .failed(let message):
                        Text(message)
                            .font(.title3)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 900)
                    default:
                        Text("Choose the iPhone, iPad, or Mac holding your games.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }

                if store.browser.hosts.isEmpty {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.6)
                        Text("Looking for Cassowary on your network…")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 20)
                } else {
                    HStack(spacing: 40) {
                        ForEach(store.browser.hosts) { host in
                            Button {
                                Task { await store.connect(to: host) }
                            } label: {
                                hostTile(host)
                            }
                            .buttonStyle(.card)
                        }
                    }
                }

                VStack(spacing: 20) {
                    if !demos.isEmpty {
                        Button {
                            playingDemo = demos.first
                        } label: {
                            Label("Play the Demo Game", systemImage: "gamecontroller")
                        }
                        .buttonStyle(.bordered)
                    }

                    VStack(spacing: 8) {
                        Text("Nothing there? Open Cassowary on your iPhone and turn on Settings → Share with Apple TV. The phone serves the library, so it has to stay open while you play.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 1000)

                        if store.state.lastHostName != nil {
                            Button("Forget \(store.state.lastHostName ?? "the saved phone")") {
                                store.forgetHost()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(.top, 12)
            }
            .padding(80)
        }
    }

    private func hostTile(_ host: FoundHost) -> some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.quaternary)

                Image(systemName: host.platformName == "mac" ? "laptopcomputer" : "ipad.and.iphone")
                    .font(.system(size: 80))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 340, height: 340)

            VStack(spacing: 4) {
                Text(host.name)
                    .font(.title3.weight(.semibold))
                if host.deviceID == store.state.lastHostDeviceID {
                    Text("Last used")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
