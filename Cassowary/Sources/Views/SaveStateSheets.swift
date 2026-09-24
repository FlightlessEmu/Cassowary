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
import OpenEmuKit

/// A game tapped with the core it will launch with, waiting to hear whether
/// to resume a save state or start fresh.
struct ResumeRequest: Identifiable {
    let id = UUID()
    let game: Game
    let core: OECorePlugin?
}

/// The phone's side of play history: last played, play count, favorite.
///
/// The records travel to the TV as save blobs, so writing them here is all it
/// takes to keep history in sync. The id is the game's content hash, which is
/// only known once the library has indexed the file — before that there is
/// nothing to file history under, so reads come back empty and writes wait.
@MainActor
enum PlayHistory {

    static func gameID(for game: Game) -> String {
        GameIndexStore.shared.record(forPath: game.url.path)?.sha256 ?? ""
    }

    static func info(for game: Game) -> PlayInfo {
        let id = gameID(for: game)
        guard !id.isEmpty else { return .empty }
        return SaveStore.loadPlayInfo(gameID: id)
    }

    static func setFavorite(_ favorite: Bool, for game: Game) {
        let id = gameID(for: game)
        guard !id.isEmpty else { return }
        var info = SaveStore.loadPlayInfo(gameID: id)
        info.favorite = favorite
        SaveStore.savePlayInfo(info, gameID: id)
        HostShareController.shared.refreshSaveState()
    }

    /// Notes that a game was just played. The next scan picks the change up
    /// and queues it for the other devices.
    static func recordPlayed(_ game: Game) {
        let id = gameID(for: game)
        guard !id.isEmpty else { return }
        var info = SaveStore.loadPlayInfo(gameID: id)
        info.lastPlayedAt = Date()
        info.playCount += 1
        SaveStore.savePlayInfo(info, gameID: id)
        HostShareController.shared.refreshSaveState()
    }
}

/// Which device wrote a slot, in plain words.
func saveSlotDeviceLabel(_ slot: SaveSlotInfo) -> String {
    if let device = slot.deviceID {
        return device == DeviceIdentity.current.id ? "This device" : "Another device"
    }
    return "This device"
}

/// One save-state slot: its screenshot when there is one, its name, and when
/// and where it was written.
struct SaveSlotRow: View {

    let slot: SaveSlotInfo
    let romURL: URL

    var body: some View {
        HStack(spacing: 12) {
            if let image = thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 96, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: 96, height: 72)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(slot.displayName)
                    .font(.headline)
                Text(slot.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(saveSlotDeviceLabel(slot))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var thumbnail: UIImage? {
        guard slot.hasScreenshot,
              let data = SaveStore.screenshotData(romURL: romURL, kind: slot.kind)
        else { return nil }
        return UIImage(data: data)
    }
}

/// The choice on tapping a game that has save states: pick up a slot, or
/// start over. Tapping a row resumes that slot.
struct ResumeSheet: View {

    let game: Game
    let slots: [SaveSlotInfo]
    let onResume: (String?) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(slots, id: \.kind) { slot in
                        Button {
                            onResume(slot.kind)
                        } label: {
                            SaveSlotRow(slot: slot, romURL: game.url)
                        }
                    }
                } header: {
                    Text("Pick up where you left off")
                }

                Section {
                    Button("Start Fresh") {
                        onResume(nil)
                    }
                }
            }
            .navigationTitle(game.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}

/// Every slot for the running game: save into one, load one back, or throw
/// one away. The autosave is written by the app when a game closes, so it
/// can be loaded and deleted but never saved by hand.
struct SaveStatesSheet: View {

    let session: GameSession
    let romURL: URL
    let gameID: String

    @Environment(\.dismiss) private var dismiss
    @State private var slots: [SaveSlotInfo] = []
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(SaveKind.allStateKinds, id: \.self) { kind in
                    Section(SaveKind.displayName(for: kind)) {
                        if let slot = slots.first(where: { $0.kind == kind }) {
                            SaveSlotRow(slot: slot, romURL: romURL)

                            if kind != SaveKind.autosave {
                                Button("Save Here") {
                                    session.saveState(in: kind) { result in
                                        report(result, success: "Saved")
                                    }
                                }
                            }
                            Button("Load") {
                                session.loadState(from: kind) { result in
                                    report(result, success: "Loaded")
                                }
                            }
                            Button("Delete", role: .destructive) {
                                SaveStore.deleteState(gameID: gameID, romURL: romURL, kind: kind)
                                reload()
                            }
                        } else {
                            if kind == SaveKind.autosave {
                                Text("No autosave yet. One is written when the game closes.")
                                    .foregroundStyle(.secondary)
                            } else {
                                Button("Save Here") {
                                    session.saveState(in: kind) { result in
                                        report(result, success: "Saved")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Save States")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let notice {
                    Text(notice)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: .capsule)
                        .padding(.bottom, 20)
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        slots = SaveStore.slotSummaries(gameID: gameID, romURL: romURL)
    }

    private func report(_ result: Result<Void, Error>, success: String) {
        switch result {
        case .success:
            notice = success
            reload()
        case .failure(let error):
            notice = error.localizedDescription
        }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            notice = nil
        }
    }
}
