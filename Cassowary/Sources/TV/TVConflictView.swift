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
                        store.resolve(conflict, choice: .keepLocal)
                        dismiss()
                    }

                    Button("Keep \(peerName)") {
                        store.resolve(conflict, choice: .keepRemote)
                        dismiss()
                    }

                    Button("Keep Both") {
                        store.resolve(conflict, choice: .keepBoth)
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

    private func versionCard(name: String, meta: TransferProtocol.SaveBlobMeta, isLocal: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: isLocal ? "appletv" : "ipad.and.iphone")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text(name)
                .font(.title3.weight(.semibold))

            Text(meta.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(ByteCountFormatter.string(fromByteCount: meta.size, countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 320, height: 260)
        .background(.quaternary, in: .rect(cornerRadius: 24))
    }
}
