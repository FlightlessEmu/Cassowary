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
import UIKit

/// The crash and hang reports the system has handed back, and the last game
/// that did not close cleanly.
///
/// A native crash in a core takes the whole process with it, so nothing is
/// written at the moment it happens. These are what the app has afterwards —
/// enough to see which core it was, and to hand the report to whoever is going
/// to fix it.
struct DiagnosticsView: View {

    @ObservedObject var store: DiagnosticsStore

    var body: some View {
        List {
            if let session = store.staleSession {
                Section {
                    staleSessionRow(session)
                } header: {
                    Text("Last Session")
                } footer: {
                    Text("The app was ended while a game was running. If you did not close it yourself, this is where a crash would show up.")
                }
            }

            Section {
                if store.reports.isEmpty {
                    ContentUnavailableView {
                        Label("No Reports", systemImage: "checkmark.seal")
                    } description: {
                        Text("Nothing has crashed or hung since the app began keeping reports.")
                    }
                } else {
                    ForEach(store.reports) { report in
                        NavigationLink {
                            DiagnosticReportView(store: store, report: report)
                        } label: {
                            reportRow(report)
                        }
                    }
                    .onDelete { offsets in
                        store.remove(at: offsets)
                    }
                }
            } header: {
                Text("Crash & Hang Reports")
            } footer: {
                Text("The phone hands these over on a later launch, and only when it is set to share analytics (Settings → Privacy & Security → Analytics & Improvements). Nothing here is sent anywhere. On a build installed from Xcode the system may not collect them at all; then use Xcode's Devices window, or Settings → Privacy & Security → Analytics & Improvements → Analytics Data on the phone.")
            }
        }
        .navigationTitle("Diagnostics")
        .toolbar {
            if !store.reports.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
        }
        .onAppear { store.reload() }
    }

    // MARK: - Rows

    private func staleSessionRow(_ session: DiagnosticsStore.StaleSession) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("\(session.title) did not close cleanly", systemImage: "exclamationmark.triangle")
                .font(.headline)

            Text(sessionDetail(session))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func sessionDetail(_ session: DiagnosticsStore.StaleSession) -> String {
        var detail = "It was running \(session.core)"
        if let system = session.system {
            detail += " (\(system))"
        }
        detail += " when the app last ended, on \(session.startedAt.formatted(date: .abbreviated, time: .shortened))."
        return detail
    }

    private func reportRow(_ report: DiagnosticsStore.Report) -> some View {
        HStack(spacing: 12) {
            Image(systemName: report.kind.symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(report.kind.title)
                Text(report.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(ByteCountFormatter.string(fromByteCount: Int64(report.size), countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// One report, shown as the JSON the system wrote.
private struct DiagnosticReportView: View {

    @ObservedObject var store: DiagnosticsStore
    let report: DiagnosticsStore.Report

    @State private var text: String?

    var body: some View {
        Group {
            if let text {
                ScrollView {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else {
                ContentUnavailableView("Could Not Read Report", systemImage: "doc.questionmark")
            }
        }
        .navigationTitle(report.kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: report.url) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .task {
            guard let data = store.data(for: report) else { return }
            text = Self.prettyPrinted(data) ?? String(decoding: data, as: UTF8.self)
        }
    }

    /// The system's JSON arrives compact. Spread it out so it can be read.
    private static func prettyPrinted(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return String(decoding: pretty, as: UTF8.self)
    }
}
