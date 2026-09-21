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

import Foundation

/// Sending a game from this device to another one.
///
/// This is the phone's half of the same protocol the TV uses to borrow a
/// game: resolve the other device, pair if this is the first time, then hand
/// the file over. It is used by the "Send a Game" list in the sharing screen.
@MainActor
final class HostPeerSender: ObservableObject {

    static let shared = HostPeerSender()

    let browser = PeerBrowser()

    @Published private(set) var sendingTo: String?
    @Published private(set) var progress: Double = 0
    @Published private(set) var message: String?

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        browser.start()
    }

    func stop() {
        browser.stop()
        started = false
    }

    /// Sends one game. Returns a sentence describing what happened, for the
    /// screen to show.
    func send(game: Game, to found: FoundHost) async -> String {
        guard sendingTo == nil else { return "A transfer is already running." }

        sendingTo = found.name
        progress = 0
        message = nil
        defer { sendingTo = nil }

        do {
            let address = try await BonjourResolver.resolve(found.endpoint)
            let host = MediaHost(deviceID: found.deviceID,
                                 name: found.name,
                                 address: address.host,
                                 port: address.port,
                                 platformName: found.platformName)

            var token = TrustStore.shared.peer(withID: host.deviceID)?.token
            if token == nil {
                let response = try await MediaClient(host: host, token: nil)
                    .pair(TransferProtocol.PairRequest(deviceID: DeviceIdentity.current.id,
                                                       deviceName: DeviceIdentity.current.name,
                                                       platformName: DeviceIdentity.current.platformName))
                guard response.accepted, let granted = response.token else {
                    message = "\(host.name) did not allow this device in."
                    return message ?? ""
                }
                TrustStore.shared.add(TrustedPeer(deviceID: host.deviceID,
                                                  name: host.name,
                                                  platformName: host.platformName,
                                                  token: granted,
                                                  lastSeen: Date()))
                token = granted
            }

            let result = await HostShareController.shared.send(game: game,
                                                               to: host,
                                                               token: token) { value in
                self.progress = value
            }
            message = result
            return result
        } catch {
            message = error.localizedDescription
            return error.localizedDescription
        }
    }
}
