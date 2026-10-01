// Copyright (c) 2026, Cassowary contributors
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the Cassowary contributors nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY Cassowary contributors ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL Cassowary contributors BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import SwiftUI

/// RetroAchievements over the game on the TV: an unlock across the top, and
/// challenges, leaderboard trackers and short notices in the corner.
///
/// The phone's versions can be tapped to dismiss. Nothing here can take
/// focus, so none of it can take the controller from the game; everything
/// goes by itself after a few seconds instead.
struct TVAchievementOverlay: View {

    @ObservedObject var state: RetroAchievementsSessionState

    var body: some View {
        VStack(alignment: .trailing, spacing: 14) {
            if let unlock = state.currentUnlock {
                unlockBanner(unlock)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: unlock.id) {
                        try? await Task.sleep(for: .seconds(5))
                        withAnimation { state.dismissUnlock() }
                    }
            }

            ForEach(state.activeChallenges) { challenge in
                pill(badge: challenge.badgeURL,
                     text: [challenge.title, state.progressText[challenge.id]].compactMap { $0 }.joined(separator: "  "))
            }

            ForEach(state.leaderboardTrackers.keys.sorted(), id: \.self) { id in
                pill(badge: nil, text: state.leaderboardTrackers[id] ?? "")
            }

            if let notice = state.eventNotice {
                pill(badge: nil, text: notice)
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(4))
                        state.dismissEventNotice()
                    }
            }
        }
        .padding(.top, 50)
        .padding(.horizontal, 70)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.3), value: state.currentUnlock?.id)
        .allowsHitTesting(false)
    }

    private func unlockBanner(_ unlock: RetroAchievement) -> some View {
        HStack(spacing: 22) {
            badge(unlock.badgeURL, size: 84)
            VStack(alignment: .leading, spacing: 4) {
                Text("Achievement Unlocked")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(unlock.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(unlock.points) points")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 26)
        .frame(maxWidth: 760, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 28, style: .continuous))
    }

    private func pill(badge url: String?, text: String) -> some View {
        HStack(spacing: 12) {
            if url != nil { badge(url, size: 40) }
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .capsule)
    }

    private func badge(_ url: String?, size: CGFloat) -> some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Image(systemName: "trophy.fill")
                .font(.system(size: size * 0.45))
                .foregroundStyle(.yellow)
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.18))
    }
}
