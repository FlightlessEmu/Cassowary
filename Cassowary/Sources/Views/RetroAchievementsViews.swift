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

/// The unlock toast: badge, title, and points, tapping anywhere dismisses.
struct RAUnlockToast: View {

    @ObservedObject var state: RetroAchievementsSessionState

    var body: some View {
        if let unlock = state.currentUnlock {
            Button {
                state.dismissUnlock()
            } label: {
                HStack(spacing: 12) {
                    RABadgeImage(urlString: unlock.badgeURL, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Achievement Unlocked")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.75))
                        Text(unlock.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text("\(unlock.points) points")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: unlock.id) {
                try? await Task.sleep(for: .seconds(5))
                state.dismissUnlock()
            }
        }
    }
}

/// Challenge indicators, leaderboard trackers, and short-lived event lines.
struct RAIndicatorsView: View {

    @ObservedObject var state: RetroAchievementsSessionState

    var body: some View {
        VStack(spacing: 6) {
            ForEach(state.activeChallenges) { challenge in
                HStack(spacing: 8) {
                    RABadgeImage(urlString: challenge.badgeURL, size: 28)
                    Text(challenge.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let progress = state.progressText[challenge.id] {
                        Text(progress)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: .capsule)
            }

            ForEach(state.leaderboardTrackers.keys.sorted(), id: \.self) { trackerID in
                Text(state.leaderboardTrackers[trackerID] ?? "")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: .capsule)
            }

            if let notice = state.eventNotice {
                Button {
                    state.dismissEventNotice()
                } label: {
                    Text(notice)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: .capsule)
                }
                .buttonStyle(.plain)
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(4))
                    state.dismissEventNotice()
                }
            }

            if state.emulatorUnrecognized {
                Text("RetroAchievements doesn't recognize this app yet — hardcore unlocks count as softcore for now.")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: .capsule)
            }
        }
    }
}

/// The game's achievement list, opened from the trophy button.
struct AchievementsSheet: View {

    @ObservedObject var state: RetroAchievementsSessionState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch state.status {
                case .idle:
                    ContentUnavailableView("No Achievement Data Yet",
                                           systemImage: "trophy",
                                           description: Text("The game is still being identified. This takes a moment after launch."))
                case .unrecognized:
                    ContentUnavailableView("No Achievements for This Game",
                                           systemImage: "trophy",
                                           description: Text("RetroAchievements has no achievement set matching this game. It still plays normally."))
                case .loginFailed(let message):
                    ContentUnavailableView("Sign-In Failed",
                                           systemImage: "person.crop.circle.badge.exclamationmark",
                                           description: Text(message.isEmpty ? "RetroAchievements refused the saved login. Sign in again in Settings." : message))
                case .loadFailed(let message):
                    ContentUnavailableView("Achievements Unavailable",
                                           systemImage: "wifi.exclamationmark",
                                           description: Text(message.isEmpty ? "The achievement set could not be loaded." : message))
                case .loaded:
                    achievementList
                }
            }
            .navigationTitle(state.gameTitle.isEmpty ? "Achievements" : state.gameTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var achievementList: some View {
        List {
            Section {
                LabeledContent("Unlocked", value: "\(state.unlockedCount) of \(state.achievementCount)")
                LabeledContent("Points", value: "\(state.unlockedPoints) of \(state.totalPoints)")
            }

            if !unlocked.isEmpty {
                Section("Unlocked") {
                    ForEach(unlocked) { achievement in
                        achievementRow(achievement)
                    }
                }
            }

            if !locked.isEmpty {
                Section("Locked") {
                    ForEach(locked) { achievement in
                        achievementRow(achievement)
                    }
                }
            }
        }
    }

    private var unlocked: [RetroAchievement] {
        state.achievements.filter(\.unlocked)
    }

    private var locked: [RetroAchievement] {
        state.achievements.filter { !$0.unlocked }
    }

    private func achievementRow(_ achievement: RetroAchievement) -> some View {
        HStack(spacing: 12) {
            RABadgeImage(urlString: achievement.unlocked ? achievement.badgeURL : achievement.lockedBadgeURL,
                         size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(achievement.title)
                    .font(.subheadline.weight(.medium))
                if !achievement.description.isEmpty {
                    Text(achievement.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text("\(achievement.points) pts")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let progress = state.progressText[achievement.id] {
                        Text(progress)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            if achievement.unlocked {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A RetroAchievements badge that loads from the network, with a trophy
/// fallback while it loads or when there is no URL.
struct RABadgeImage: View {

    var urlString: String?
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    default:
                        Image(systemName: "trophy.fill")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(.secondary)
                            .padding(4)
                    }
                }
            } else {
                Image(systemName: "trophy.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary, in: .rect(cornerRadius: size * 0.24))
        .clipShape(.rect(cornerRadius: size * 0.24))
    }
}
