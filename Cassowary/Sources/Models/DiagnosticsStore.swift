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
import MetricKit
import os.log

/// Collects the crash and hang reports the system hands back, and keeps a short
/// note of the last game that ran.
///
/// A native crash in a core takes the whole process with it, so the app cannot
/// write anything at the moment it happens. What it can do is ask the system
/// afterwards: MetricKit delivers the reports on a later launch, on every
/// install whose owner agreed to share analytics. A note left behind by a game
/// that never stopped cleanly points at the same crash.
///
/// Reports are kept on the device as plain JSON under `Documents/Diagnostics`,
/// and nothing is uploaded anywhere. Because that folder is inside the app's
/// own container, the reports can also be pulled off a phone with Finder, or
/// with `devicectl device copy from`.
@MainActor
final class DiagnosticsStore: NSObject, ObservableObject {

    static let shared = DiagnosticsStore()

    // MARK: - What is kept

    /// One saved report file.
    struct Report: Identifiable, Hashable {
        enum Kind: String {
            case crash, hang, cpu, disk, other

            /// The prefix a file name starts with, so a report can be told
            /// apart without parsing it.
            var title: String {
                switch self {
                case .crash: return "Crash"
                case .hang:  return "Hang"
                case .cpu:   return "CPU"
                case .disk:  return "Disk Write"
                case .other: return "Report"
                }
            }

            var symbol: String {
                switch self {
                case .crash: return "xmark.octagon"
                case .hang:  return "hourglass"
                case .cpu:   return "cpu"
                case .disk:  return "externaldrive.badge.exclamationmark"
                case .other: return "doc.text"
                }
            }

            init(fileName: String) {
                let prefix = fileName.split(separator: "-").first.map(String.init) ?? ""
                self = Kind(rawValue: prefix) ?? .other
            }
        }

        let id: String
        let url: URL
        let kind: Kind
        let date: Date
        let size: Int
    }

    /// A game that started but never reported a clean stop.
    struct StaleSession: Codable {
        let title: String
        let core: String
        let system: String?
        let startedAt: Date
    }

    @Published private(set) var reports: [Report] = []

    /// The last game, when it did not close cleanly. This is the on-device
    /// hint that the app was killed while a core was running.
    @Published private(set) var staleSession: StaleSession?

    // MARK: - Where it lives

    private static let folderName = "Diagnostics"
    private static let staleName = "last-session.json"

    private static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folderName, isDirectory: true)
    }

    private static var staleURL: URL {
        folder.appendingPathComponent(staleName)
    }

    // MARK: - Lifecycle

    private override init() {
        super.init()
    }

    /// Subscribe to the system's reports and read what is already on disk.
    ///
    /// Called once, at launch, before any game can run.
    func start() {
        MXMetricManager.shared.add(self)
        reload()
        readStaleSession()
    }

    /// Re-read the folder. Cheap enough to call whenever the screen opens.
    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)

        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? fm.contentsOfDirectory(at: Self.folder,
                                                includingPropertiesForKeys: Array(keys),
                                                options: [.skipsHiddenFiles])) ?? []

        reports = urls
            .filter { $0.pathExtension.lowercased() == "json" && $0.lastPathComponent != Self.staleName }
            .map { url in
                let values = try? url.resourceValues(forKeys: keys)
                return Report(id: url.lastPathComponent,
                              url: url,
                              kind: Report.Kind(fileName: url.lastPathComponent),
                              date: values?.contentModificationDate ?? .distantPast,
                              size: values?.fileSize ?? 0)
            }
            .sorted { $0.date > $1.date }

        readStaleSession()
    }

    /// The JSON of one report, exactly as the system wrote it.
    func data(for report: Report) -> Data? {
        try? Data(contentsOf: report.url)
    }

    /// Delete every report on the device.
    func removeAll() {
        for report in reports {
            try? FileManager.default.removeItem(at: report.url)
        }
        reports = []
    }

    /// Delete the reports at the given positions in `reports`, for a list's
    /// swipe-to-delete.
    func remove(at offsets: IndexSet) {
        for index in offsets {
            try? FileManager.default.removeItem(at: reports[index].url)
        }
        reports = reports.enumerated()
            .filter { !offsets.contains($0.offset) }
            .map(\.element)
    }

    // MARK: - Last session

    /// Note that a game is about to start.
    ///
    /// The note is removed by `noteSessionEnded` when the game stops cleanly.
    /// One that survives to the next launch means the app did not get that far.
    func noteSessionStarted(title: String, core: String, system: String?) {
        let session = StaleSession(title: title, core: core, system: system, startedAt: Date())

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]

        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        if let data = try? encoder.encode(session) {
            try? data.write(to: Self.staleURL, options: .atomic)
        }
        os_log("last-session note written for %{public}@", log: Self.log, title)

        // While a game is running the note is expected, so it is not a warning.
        staleSession = nil
    }

    /// Note that the game stopped cleanly, so the note is no longer of interest.
    func noteSessionEnded() {
        try? FileManager.default.removeItem(at: Self.staleURL)
        os_log("last-session note cleared", log: Self.log)
        staleSession = nil
    }

    private func readStaleSession() {
        guard let data = try? Data(contentsOf: Self.staleURL) else {
            staleSession = nil
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        staleSession = try? decoder.decode(StaleSession.self, from: data)
    }

    // MARK: - Saving what the system sends

    /// Write one system payload to disk and refresh the list.
    private func save(_ items: [(name: String, data: Data)]) {
        guard !items.isEmpty else { return }

        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)

        for item in items {
            let url = Self.folder.appendingPathComponent(item.name)
            try? item.data.write(to: url, options: .atomic)
            os_log("saved diagnostic %{public}@ (%d bytes)", log: Self.log, item.name, item.data.count)
        }

        reload()
    }

    private static let log = OSLog(subsystem: "org.cassowary.Cassowary", category: "diagnostics")

    /// A file name for one payload: its kind first, so the list can tell what a
    /// report is without opening it, then when it happened.
    ///
    /// Not on the main actor: the system calls `didReceive` on its own queue.
    nonisolated private static func fileName(kind: Report.Kind, date: Date, index: Int) -> String {
        "\(kind.rawValue)-\(formatter.string(from: date))-\(index).json"
    }

    /// `DateFormatter` is safe to use from more than one thread on Apple
    /// platforms; the payloads are handled off the main actor.
    nonisolated(unsafe) private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

// MARK: - MetricKit

extension DiagnosticsStore: MXMetricManagerSubscriber {

    /// Performance metrics. The engine already has an in-app frame count, and
    /// these are not crashes, so nothing here is kept.
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) { }

    /// Crashes, hangs, CPU exceptions and disk-write exceptions.
    ///
    /// MetricKit calls this on its own queue, and a payload can carry more than
    /// one diagnostic, so each payload becomes one file.
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let items: [(name: String, data: Data)] = payloads.enumerated().map { index, payload in
            let kind: Report.Kind

            if payload.crashDiagnostics?.isEmpty == false {
                kind = .crash
            } else if payload.hangDiagnostics?.isEmpty == false {
                kind = .hang
            } else if payload.cpuExceptionDiagnostics?.isEmpty == false {
                kind = .cpu
            } else if payload.diskWriteExceptionDiagnostics?.isEmpty == false {
                kind = .disk
            } else {
                kind = .other
            }

            return (Self.fileName(kind: kind, date: payload.timeStampBegin, index: index),
                    payload.jsonRepresentation())
        }

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.save(items)
            }
        }
    }
}

#if DEBUG
extension DiagnosticsStore {

    /// Write a report shaped like the ones MetricKit sends, so the screen can
    /// be looked at on the Simulator, where MetricKit stays quiet. Used by
    /// Scripts/cassowary/run-cassowary.sh.
    func writeSampleReport() {
        let json = """
        {
          "crashDiagnostics" : [
            {
              "diagnosticMetaData" : {
                "appBuildVersion" : "1",
                "appVersion" : "0.1",
                "deviceType" : "iPhone",
                "osVersion" : "iOS 26.0"
              },
              "exceptionType" : 1,
              "signal" : 11,
              "terminationReason" : {
                "code" : 0,
                "namespace" : "SIGNAL"
              },
              "callStackTree" : { "callStacks" : [] }
            }
          ],
          "timeStampBegin" : "2026-01-01T00:00:00Z"
        }
        """

        noteSessionStarted(title: "Sample Game", core: "Sample Core", system: "com.openemu.sample")
        save([(name: Self.fileName(kind: .crash, date: Date(), index: 0), data: Data(json.utf8))])
    }
}
#endif
