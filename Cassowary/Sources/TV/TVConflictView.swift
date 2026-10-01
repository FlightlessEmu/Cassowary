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

/// The question a save conflict asks: which copy do you want?
///
/// The same game was played here and on the phone before the two synced, so
/// neither copy is wrong. Keeping both is always offered, and the copy that
/// is not chosen is kept as a backup when that happens.
struct TVConflictView: View {

    let conflict: SaveConflict
    /// Carries out the choice. The library files it and moves on to the next
    /// conflict; the screenshot sample passes one that does nothing.
    let resolve: (SaveSyncEngine.ConflictChoice) -> Void

    @ObservedObject private var store = TVStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 44) {
                VStack(spacing: 10) {
                    Text("Keep which version?")
                        .font(.system(size: 44, weight: .semibold))
                    Text("\(store.title(forGameID: conflict.gameID)) · \(conflict.title)")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 48) {
                    versionCard(name: "This Apple TV", meta: conflict.local, isLocal: true)
                    versionCard(name: peerName, meta: conflict.remote, isLocal: false)
                }

                HStack(spacing: 28) {
                    Button("Keep This Apple TV") {
                        resolve(.keepLocal)
                        dismiss()
                    }

                    Button("Keep \(peerName)") {
                        resolve(.keepRemote)
                        dismiss()
                    }

                    Button("Keep Both") {
                        resolve(.keepBoth)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)

                Text("The copy you do not keep is saved as a backup beside it when you choose both.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(80)
        }
    }

    private var peerName: String {
        store.state.lastHostName ?? "the phone"
    }

    /// One copy: where it was written, when, and how big it is. Both cards
    /// keep the same layout — one line per fact — so they can be compared at
    /// a glance, and the newer one says so.
    private func versionCard(name: String, meta: TransferProtocol.SaveBlobMeta, isLocal: Bool) -> some View {
        let other = isLocal ? conflict.remote : conflict.local
        return VStack(spacing: 14) {
            Image(systemName: isLocal ? "appletv" : "ipad.and.iphone")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .frame(height: 56)

            // One size for both names, so the cards match; a very long name
            // shrinks rather than wraps.
            Text(name)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(meta.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(meta.size.formatted(.byteCount(style: .file)))
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Newer")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .opacity(meta.modifiedAt > other.modifiedAt ? 1 : 0)
        }
        .padding(.horizontal, 28)
        .frame(width: 440, height: 340)
        .background(.quaternary, in: .rect(cornerRadius: 24))
    }
}
