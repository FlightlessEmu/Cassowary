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
import OpenEmuKit

/// One achievement in the loaded game's set.
struct RetroAchievement: Identifiable, Equatable {
    var id: UInt32
    var title: String
    var description: String
    var points: UInt32
    var unlocked: Bool
    var badgeURL: String?
    var lockedBadgeURL: String?
    var bucketTitle: String
    var setTitle: String

    init(id: UInt32, title: String, description: String = "", points: UInt32 = 0,
         unlocked: Bool = false, badgeURL: String? = nil, lockedBadgeURL: String? = nil,
         bucketTitle: String = "", setTitle: String = "") {
        self.id = id
        self.title = title
        self.description = description
        self.points = points
        self.unlocked = unlocked
        self.badgeURL = badgeURL
        self.lockedBadgeURL = lockedBadgeURL
        self.bucketTitle = bucketTitle
        self.setTitle = setTitle
    }

    init?(dictionary: [String: Any]) {
        guard let rawID = dictionary[OEAchievementIDKey] else { return nil }
        let id: UInt32
        if let number = rawID as? NSNumber {
            id = number.uint32Value
        } else if let int = rawID as? Int {
            id = UInt32(int)
        } else {
            return nil
        }
        self.id = id
        self.title = dictionary[OEAchievementTitleKey] as? String ?? ""
        self.description = dictionary[OEAchievementDescriptionKey] as? String ?? ""
        if let number = dictionary[OEAchievementPointsKey] as? NSNumber {
            self.points = number.uint32Value
        } else {
            self.points = 0
        }
        if let number = dictionary[OERetroAchievementsUnlockedKey] as? NSNumber {
            self.unlocked = number.boolValue
        } else {
            self.unlocked = (dictionary[OERetroAchievementsUnlockedKey] as? Bool) ?? false
        }
        self.badgeURL = dictionary[OEAchievementBadgeURLKey] as? String
        self.lockedBadgeURL = dictionary[OERetroAchievementsBadgeLockedURLKey] as? String
        self.bucketTitle = dictionary[OERetroAchievementsBucketTitleKey] as? String ?? ""
        self.setTitle = dictionary[OERetroAchievementsSetTitleKey] as? String ?? ""
    }
}

/// What the game at hand looks like on RetroAchievements.
enum RetroSessionStatus: Equatable {
    case idle
    case loaded
    case unrecognized
    case loginFailed(String)
    case loadFailed(String)
}

/// The live RetroAchievements state of one running game.
///
/// The emulator core posts raw notifications on background threads; the
/// session's owner callbacks hop to the main actor and land here, so the
/// views can read plain values.
@MainActor
final class RetroAchievementsSessionState: ObservableObject {

    /// The unlock currently toasting, if any.
    @Published var currentUnlock: RetroAchievement?

    /// The loaded game's title and progress, once identified.
    @Published var gameTitle = ""
    @Published var unlockedCount = 0
    @Published var achievementCount = 0
    @Published var unlockedPoints = 0
    @Published var totalPoints = 0
    @Published var achievements: [RetroAchievement] = []
    @Published var status: RetroSessionStatus = .idle

    /// Challenge indicators: achievements the player is close to earning.
    @Published var activeChallenges: [RetroAchievement] = []

    /// Measured-progress text for one achievement, e.g. "3 of 10".
    @Published var progressText: [UInt32: String] = [:]

    /// Leaderboard trackers: leaderboard id to live display text.
    @Published var leaderboardTrackers: [UInt32: String] = [:]

    /// Short-lived event lines (mastery, scoreboards, server hiccups).
    @Published var eventNotice: String?

    /// RetroAchievements does not recognize this client yet: hardcore
    /// unlocks land as softcore. Shown once per game.
    @Published var emulatorUnrecognized = false

    var hasSession: Bool {
        if case .loaded = status { return true }
        return false
    }

    func reset() {
        currentUnlock = nil
        gameTitle = ""
        unlockedCount = 0
        achievementCount = 0
        unlockedPoints = 0
        totalPoints = 0
        achievements = []
        status = .idle
        activeChallenges = []
        progressText = [:]
        leaderboardTrackers = [:]
        eventNotice = nil
        emulatorUnrecognized = false
    }

    // MARK: - Fed by the session's owner callbacks

    func unlocked(id: UInt32, title: String, description: String, badgeURL: String, points: UInt32) {
        let achievement = RetroAchievement(id: id, title: title, description: description,
                                           points: points, unlocked: true,
                                           badgeURL: badgeURL.isEmpty ? nil : badgeURL)
        currentUnlock = achievement
        markUnlocked(id: id)
    }

    func dismissUnlock() {
        currentUnlock = nil
    }

    func sessionUpdated(_ info: [String: Any]) {
        if let statusString = info[OERetroAchievementsSessionStatusKey] as? String {
            switch statusString {
            case OERetroAchievementsSessionStatusUnrecognized:
                status = .unrecognized
                return
            case OERetroAchievementsSessionStatusLoginFailed:
                status = .loginFailed(info[OERetroAchievementsSessionErrorMessageKey] as? String ?? "")
                return
            case OERetroAchievementsSessionStatusLoadFailed:
                status = .loadFailed(info[OERetroAchievementsSessionErrorMessageKey] as? String ?? "")
                return
            default:
                break
            }
        }
        gameTitle = info[OERetroAchievementsGameTitleKey] as? String ?? ""
        unlockedCount = (info[OERetroAchievementsUnlockedCountKey] as? NSNumber)?.intValue ?? 0
        achievementCount = (info[OERetroAchievementsAchievementCountKey] as? NSNumber)?.intValue ?? 0
        unlockedPoints = (info[OERetroAchievementsUnlockedPointsKey] as? NSNumber)?.intValue ?? 0
        totalPoints = (info[OERetroAchievementsTotalPointsKey] as? NSNumber)?.intValue ?? 0
        if let raw = info[OERetroAchievementsAchievementsKey] as? [[String: Any]] {
            achievements = raw.compactMap(RetroAchievement.init(dictionary:))
        }
        status = .loaded
    }

    func event(_ info: [String: Any]) {
        guard let kind = info[OERetroAchievementsEventKindKey] as? String else { return }
        let id = (info[OERetroAchievementsEventIDKey] as? NSNumber)?.uint32Value ?? 0
        switch kind {
        case "challengeShow":
            if let achievement = RetroAchievement(dictionary: eventAsAchievement(info)) {
                activeChallenges.removeAll { $0.id == achievement.id }
                activeChallenges.append(achievement)
            }
        case "challengeHide":
            activeChallenges.removeAll { $0.id == id }
        case "progressShow", "progressUpdate":
            if let text = info[OERetroAchievementsMeasuredProgressKey] as? String, !text.isEmpty {
                progressText[id] = text
            }
        case "progressHide":
            progressText.removeValue(forKey: id)
        case "leaderboardTrackerShow", "leaderboardTrackerUpdate":
            if let display = info[OERetroAchievementsEventDisplayKey] as? String {
                leaderboardTrackers[id] = display
            }
        case "leaderboardTrackerHide":
            leaderboardTrackers.removeValue(forKey: id)
        case "leaderboardStarted":
            if let title = info[OERetroAchievementsEventTitleKey] as? String {
                eventNotice = "Leaderboard started: \(title)"
            }
        case "leaderboardSubmitted":
            eventNotice = leaderboardScoreboardLine(info, prefix: "Score submitted")
        case "leaderboardScoreboard":
            eventNotice = leaderboardScoreboardLine(info, prefix: "Leaderboard")
        case "leaderboardFailed":
            eventNotice = "Leaderboard attempt failed."
        case "gameCompleted":
            eventNotice = "Game completed — congratulations!"
        case "subsetCompleted":
            if let title = info[OERetroAchievementsEventTitleKey] as? String {
                eventNotice = "Subset completed: \(title)"
            }
        case "resetRequested":
            eventNotice = "Hardcore mode reset the game."
        case "serverError":
            eventNotice = (info[OERetroAchievementsEventErrorMessageKey] as? String)
                .map { "RetroAchievements server error: \($0)" }
                ?? "RetroAchievements server error."
        case "disconnected":
            eventNotice = "Lost connection to RetroAchievements. Unlocks will retry."
        case "reconnected":
            eventNotice = "Reconnected to RetroAchievements."
        default:
            break
        }
    }

    func dismissEventNotice() {
        eventNotice = nil
    }

    // MARK: - Private

    private func markUnlocked(id: UInt32) {
        guard let index = achievements.firstIndex(where: { $0.id == id }) else { return }
        achievements[index].unlocked = true
        unlockedCount += 1
        unlockedPoints += Int(achievements[index].points)
    }

    /// The event payload uses `event*` keys; remap the achievement-shaped
    /// ones onto the keys `RetroAchievement.init(dictionary:)` reads.
    private func eventAsAchievement(_ info: [String: Any]) -> [String: Any] {
        var dictionary: [String: Any] = [:]
        dictionary[OEAchievementIDKey] = info[OERetroAchievementsEventIDKey]
        dictionary[OEAchievementTitleKey] = info[OERetroAchievementsEventTitleKey]
        dictionary[OEAchievementDescriptionKey] = info[OERetroAchievementsEventDescriptionKey]
        dictionary[OEAchievementPointsKey] = info[OERetroAchievementsEventPointsKey]
        dictionary[OEAchievementBadgeURLKey] = info[OERetroAchievementsEventBadgeURLKey]
        dictionary[OERetroAchievementsUnlockedKey] = false
        return dictionary
    }

    private func leaderboardScoreboardLine(_ info: [String: Any], prefix: String) -> String {
        let submitted = info[OERetroAchievementsEventSubmittedScoreKey] as? String ?? ""
        let rank = (info[OERetroAchievementsEventRankKey] as? NSNumber)?.intValue ?? 0
        let total = (info[OERetroAchievementsEventTotalEntriesKey] as? NSNumber)?.intValue ?? 0
        if rank > 0 && total > 0 {
            return "\(prefix): \(submitted) — rank \(rank) of \(total)"
        }
        return submitted.isEmpty ? "\(prefix)." : "\(prefix): \(submitted)"
    }
}
