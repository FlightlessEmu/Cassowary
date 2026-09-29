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
import UniformTypeIdentifiers

/// Every system whose cores ask for BIOS files, with which files are in the
/// BIOS folder, and a way to add more.
struct BIOSSettingsView: View {

    @ObservedObject var catalog: CoreCatalog

    @State private var showImporter = false
    @State private var importMessage: String?
    /// Bumped after an import so the rows are checked again.
    @State private var refreshToken = 0

    var body: some View {
        List {
            let requirements = Self.requirements(for: catalog.systems)
            if requirements.isEmpty {
                Text("None of the installed cores needs a BIOS.")
                    .foregroundStyle(.secondary)
            }
            ForEach(requirements, id: \.system.id) { item in
                Section {
                    ForEach(item.requirement.files) { file in
                        BIOSFileRow(file: file)
                    }
                } header: {
                    HStack(spacing: 8) {
                        SystemIconView(system: item.system, size: 18)
                        Text(item.system.name)
                        Spacer()
                        BIOSStatusBadge(requirement: item.requirement)
                    }
                } footer: {
                    if item.requirement.isRegional {
                        Text("One BIOS per region. Any one of them runs games from its region.")
                    }
                }
            }
        }
        .id(refreshToken)
        .navigationTitle("BIOS Files")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add…") { showImporter = true }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            Task {
                importMessage = await Self.importBIOS(urls)
                refreshToken += 1
            }
        }
        .alert("BIOS Files", isPresented: Binding(
            get: { importMessage != nil },
            set: { if !$0 { importMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importMessage ?? "")
        }
    }

    /// The systems that ask for a BIOS, in the catalog's order.
    private static func requirements(for systems: [SystemEntry]) -> [(system: SystemEntry, requirement: BIOSRequirement)] {
        systems.compactMap { system in
            BIOSCatalog.requirement(forSystemIdentifier: system.id).map { (system, $0) }
        }
    }

    /// Files each picked file that is a BIOS, and says what happened.
    private static func importBIOS(_ urls: [URL]) async -> String {
        let signatures = BIOSCatalog.signatures()
        let folder = BIOSCatalog.directory
        let results = await Task.detached(priority: .userInitiated) {
            urls.map { url -> (String, BIOSCatalog.FilingResult) in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return (url.lastPathComponent, BIOSCatalog.file(url, signatures: signatures, into: folder))
            }
        }.value

        var filed: [String] = []
        var invalid: [String] = []
        var other: [String] = []
        for (name, result) in results {
            switch result {
            case .filed: filed.append(name)
            case .invalid: invalid.append(name)
            case .notBIOS, .failed: other.append(name)
            }
        }

        var lines: [String] = []
        if !filed.isEmpty {
            lines.append("Added: \(filed.joined(separator: ", ")).")
        }
        if !invalid.isEmpty {
            lines.append("These have BIOS names but the wrong contents, so they were left out: \(invalid.joined(separator: ", ")). Check the file is the right version.")
        }
        if !other.isEmpty {
            lines.append("Not a BIOS any installed core asks for: \(other.joined(separator: ", ")).")
        }
        return lines.joined(separator: "\n\n")
    }
}

/// One BIOS file: its name, what it is, and whether it is in.
struct BIOSFileRow: View {
    let file: BIOSFile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: file.isPresent ? "checkmark.circle.fill" : (file.isOptional ? "circle.dashed" : "xmark.circle"))
                .foregroundStyle(file.isPresent ? Color.green : Color.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.body.monospaced())
                Text(file.isOptional ? "\(file.description) · optional" : file.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(file.isPresent ? "Added" : "Not added")
    }
}

/// "Ready" or "Missing", for a system's BIOS files.
struct BIOSStatusBadge: View {
    let requirement: BIOSRequirement

    var body: some View {
        Text(requirement.isReady ? "Ready" : "Missing")
            .font(.caption2.weight(.semibold))
            .textCase(nil)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(requirement.isReady ? Color.green.opacity(0.2) : Color.orange.opacity(0.2), in: .capsule)
            .foregroundStyle(requirement.isReady ? Color.green : Color.orange)
    }
}
