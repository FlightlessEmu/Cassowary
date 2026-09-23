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
import Network

/// A host seen on the network, before anything is asked of it.
struct FoundHost: Identifiable, Hashable {
    let endpoint: NWEndpoint
    var deviceID: String
    var name: String
    var platformName: String

    /// The endpoint's description is unique per advertised service.
    var id: String { String(describing: endpoint) }
}

/// Watches the network for Cassowary hosts.
@MainActor
final class PeerBrowser: ObservableObject {

    @Published private(set) var hosts: [FoundHost] = []
    @Published private(set) var isBrowsing = false

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "org.cassowary.peer-browser")

    func start() {
        guard browser == nil else { return }

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        let browser = NWBrowser(for: .bonjour(type: TransferProtocol.serviceType, domain: nil),
                                using: parameters)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isBrowsing = true
                case .failed, .cancelled:
                    self?.isBrowsing = false
                    self?.hosts = []
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [FoundHost] = results.compactMap { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }

                let record: NWTXTRecord? = {
                    if case let .bonjour(txt) = result.metadata { return txt }
                    return nil
                }()

                let deviceID = record?["id"] ?? name
                let displayName = record?["name"] ?? name
                // A device sees its own advertisement; leave it out. Recent
                // systems hand the browser no TXT record at all, so the name
                // is the only thing left to recognize our own service by.
                let identity = DeviceIdentity.current
                guard deviceID != identity.id, displayName != identity.name else { return nil }

                return FoundHost(endpoint: result.endpoint,
                                 deviceID: deviceID,
                                 name: displayName,
                                 platformName: record?["platform"] ?? "")
            }
            Task { @MainActor in
                self?.hosts = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        }

        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
        hosts = []
    }

    // MARK: - TXT records

    /// Encodes a Bonjour TXT record by hand: each entry is a length byte
    /// followed by its UTF-8. Foundation's helper is deprecated.
    nonisolated static func txtData(_ values: [String: String]) -> Data {
        var data = Data()
        for (key, value) in values {
            let entry = Array("\(key)=\(value)".utf8)
            guard entry.count < 255 else { continue }
            data.append(UInt8(entry.count))
            data.append(contentsOf: entry)
        }
        return data
    }
}

/// Turns a Bonjour endpoint into an address URLSession can use.
enum BonjourResolver {

    /// Opens a connection far enough to learn where it went, and falls back
    /// to the classic service resolver when the path does not name a host.
    static func resolve(_ endpoint: NWEndpoint, timeout: TimeInterval = 8) async throws -> (host: String, port: UInt16) {
        // An IPv4 path first. A phone advertises a link-local IPv6 address as
        // well, and that one cannot go in a URL: its zone is not valid there,
        // and without the zone it is unroutable, so the request fails as if
        // the network were down. The plain path is tried after it, for a
        // network that is IPv6 only.
        for preferIPv4 in [true, false] {
            if let fromPath = try? await resolveThroughConnection(endpoint, preferIPv4: preferIPv4, timeout: timeout) {
                NSLog("[Cassowary] resolved %@:%d", fromPath.host, fromPath.port)
                return fromPath
            }
        }

        if case let .service(name, type, domain, _) = endpoint {
            let resolved = try await ServiceResolver().resolve(name: name,
                                                               type: type,
                                                               domain: domain,
                                                               timeout: timeout)
            NSLog("[Cassowary] resolved %@:%d (service)", resolved.host, resolved.port)
            return resolved
        }

        throw MediaClientError.noAddress
    }

    private static func resolveThroughConnection(_ endpoint: NWEndpoint, preferIPv4: Bool, timeout: TimeInterval) async throws -> (host: String, port: UInt16)? {
        let queue = DispatchQueue(label: "org.cassowary.resolve")
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        if preferIPv4, let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)

        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            let lock = NSLock()

            func finish(_ result: Result<(host: String, port: UInt16)?, Error>) {
                lock.lock()
                let alreadyDone = finished
                finished = true
                lock.unlock()
                guard !alreadyDone else { return }
                connection.cancel()
                continuation.resume(with: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.success(hostPort(from: connection.currentPath?.remoteEndpoint)))
                case .failed(let error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(MediaClientError.cancelled))
                default:
                    break
                }
            }

            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + timeout) {
                finish(.success(nil))
            }
        }
    }

    /// The address as something that can go straight into a URL: a name or an
    /// IPv4 address as-is, IPv6 in brackets because URLComponents needs them.
    /// Interface zones (`%en0`) are dropped: they are not valid in a URL, and
    /// a plain local address picks the right interface on its own.
    ///
    /// A link-local IPv6 address is refused: dropping its zone leaves an
    /// address nothing can reach, and keeping the zone is not valid in a URL
    /// either. Returning nil sends the caller on to the next way of resolving.
    private static func hostPort(from endpoint: NWEndpoint?) -> (host: String, port: UInt16)? {
        guard case let .hostPort(host, port)? = endpoint else { return nil }

        let text: String
        switch host {
        case .ipv4(let address):
            text = stripZone("\(address)")
        case .ipv6(let address):
            let value = stripZone("\(address)")
            if isLinkLocal(value) { return nil }
            text = "[\(value)]"
        case .name(let name, _):
            text = stripZone(name)
        @unknown default:
            return nil
        }

        return (text, port.rawValue)
    }

    /// `fe80::/10`, which is every address a device hands out for the local
    /// link alone.
    private static func isLinkLocal(_ address: String) -> Bool {
        let prefix = address.lowercased().prefix(4)
        guard prefix.count == 4 else { return false }
        return prefix.hasPrefix("fe8") || prefix.hasPrefix("fe9")
            || prefix.hasPrefix("fea") || prefix.hasPrefix("feb")
    }

    private static func stripZone(_ value: String) -> String {
        guard let percent = value.firstIndex(of: "%") else { return value }
        return String(value[..<percent])
    }

    /// A discovered host, resolved to an address and asked who it is.
    ///
    /// Discovery cannot be trusted for the id: current systems hand the
    /// browser no Bonjour TXT record, so a service's name stands in for it.
    /// The host's own answer is what reuses an existing pairing, and what
    /// recognizes the same device the next time it turns up.
    static func identify(_ found: FoundHost, timeout: TimeInterval = 8) async throws -> MediaHost {
        let address = try await resolve(found.endpoint, timeout: timeout)
        let discovered = MediaHost(deviceID: found.deviceID,
                                   name: found.name,
                                   address: address.host,
                                   port: address.port,
                                   platformName: found.platformName)
        // A real id came through with the advertisement; nothing to ask.
        guard found.deviceID == found.name else { return discovered }

        let probe = MediaClient(host: discovered, token: nil)
        guard let info = try? await probe.info() else { return discovered }
        return MediaHost(deviceID: info.deviceID,
                         name: info.deviceName,
                         address: address.host,
                         port: address.port,
                         platformName: found.platformName)
    }
}

/// `NetService` resolution, for when the connection path does not report a
/// host. It hands back the service's own name, which resolves to whatever the
/// network prefers.
private final class ServiceResolver: NSObject, NetServiceDelegate {

    private var continuation: CheckedContinuation<(host: String, port: UInt16), Error>?
    private var service: NetService?
    private var finished = false

    func resolve(name: String, type: String, domain: String, timeout: TimeInterval) async throws -> (host: String, port: UInt16) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let service = NetService(domain: domain, type: type, name: name)
            self.service = service
            service.delegate = self
            service.resolve(withTimeout: timeout)
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        var host = sender.hostName ?? ""
        if host.hasSuffix(".") { host = String(host.dropLast()) }
        finish(.success((host, UInt16(sender.port))))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        finish(.failure(MediaClientError.noAddress))
    }

    private func finish(_ result: Result<(host: String, port: UInt16), Error>) {
        guard !finished else { return }
        finished = true
        service?.stop()
        continuation?.resume(with: result)
        continuation = nil
    }
}
