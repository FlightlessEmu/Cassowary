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
import OpenEmuBase
import OpenEmuKit

/// The host side of the emulator conversation.
///
/// On macOS `OEGameDocument` implements this and the two sides talk over XPC.
/// Here the session implements it directly, because the helper runs in the
/// same process. Most of the methods are the ones the helper calls to tell the
/// host something changed; the rest are the actions a menu would trigger.
extension GameSession: OEGameCoreOwner {

    // MARK: - Reported by the helper

    /// The core reports this from its own frame thread. The main actor reads the
    /// sizes as it lays the picture out, so hand them over there.
    nonisolated func setScreenSize(_ newScreenSize: OEIntSize, aspectSize newAspectSize: OEIntSize) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.screenSize = newScreenSize
                self.aspectSize = newAspectSize
            }
        }
    }

    /// Reached from the core's thread once the game is loaded. The disc
    /// picker in the game menu reads it, so hand it over to the main actor.
    nonisolated func setDiscCount(_ discCount: UInt) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.discCount = discCount
            }
        }
    }

    /// Reached from the core's thread. Nothing reads the display modes, so
    /// there is nothing to store.
    nonisolated func setDisplayModes(_ displayModes: [[String: Any]]) { }

    nonisolated func setRemoteContextID(_ contextID: OEContextID) {
        // macOS uses this to hand a CAContext to the host process. In-process,
        // the layer is already available through `videoLayer`.
    }

    /// The core is shaking a controller. Play it on the device. Cores report
    /// this from their own thread, and the rumble state lives on the main one.
    nonisolated func didChangeRumble(_ enabled: Bool, forPlayer player: UInt) {
        onMain { $0.rumble.setRumbling(enabled, forPlayer: player) }
    }

    // MARK: - Actions

    nonisolated func saveState() { }
    nonisolated func loadState() { }
    nonisolated func quickSave() { }
    nonisolated func quickLoad() { }
    nonisolated func toggleFullScreen() { }
    nonisolated func toggleAudioMute() { }
    nonisolated func volumeDown() { }
    nonisolated func volumeUp() { }

    /// The core asks to quit from its own thread; teardown belongs on the main
    /// actor, so hop there.
    nonisolated func stopEmulation() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.stop()
            }
        }
    }

    nonisolated func resetEmulation() {
        onMain { $0.helper.resetEmulation {} }
    }

    /// Swaps to another disc of a multi-disc game, numbered from 1. The core
    /// opens the lid, changes the disc and closes it again a moment later,
    /// the way a player would.
    nonisolated func setDisc(_ discNumber: UInt) {
        onMain { session in
            guard discNumber >= 1, discNumber <= session.discCount else { return }
            session.helper.setDisc(discNumber)
        }
    }

    nonisolated func toggleEmulationPaused() {
        onMain { session in
            session.isPaused.toggle()
            session.setPaused(session.isPaused)
        }
    }

    nonisolated func takeScreenshot() { }

    // The helper forwards these to the owner, so the owner acts on the core
    // itself. `rate` is the supported way to change execution speed; rewind and
    // frame stepping are driven by the host app's menu on macOS and are not
    // wired up in this first iOS build.
    nonisolated func fastForwardGameplay(_ enable: Bool) {
        onMain { $0.helper.gameCore?.rate = enable ? 4.0 : 1.0 }
    }

    nonisolated func rewindGameplay(_ enable: Bool) { }
    nonisolated func stepGameplayFrameForward() { }
    nonisolated func stepGameplayFrameBackward() { }

    nonisolated func nextDisplayMode() { }
    nonisolated func lastDisplayMode() { }

    /// Runs `work` on the main actor: straight away when already there (the
    /// app's own buttons call these), and on the next turn when a core calls
    /// from its own thread.
    private nonisolated func onMain(_ work: @escaping @MainActor (GameSession) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work(self) }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { work(self) }
            }
        }
    }

    // MARK: - RetroAchievements

    /// An achievement was earned. The helper calls this on whatever thread
    /// the emulator posts on, so hop to the main actor before touching
    /// the session state the views read.
    nonisolated func achievementUnlocked(id: UInt32, title: String, description: String, badgeURL: String, points: UInt32) {
        Task { @MainActor [weak self] in
            self?.raState.unlocked(id: id, title: title, description: description, badgeURL: badgeURL, points: points)
        }
    }

    /// The loaded game's achievement metadata changed: first identification
    /// and after each unlock.
    nonisolated func retroAchievementsSessionUpdated(_ info: [String: Any]) {
        Task { @MainActor [weak self] in
            self?.raState.sessionUpdated(info)
        }
    }

    /// A gameplay event: challenge or progress indicator, leaderboard
    /// tracker or scoreboard, mastery, or a server connection change.
    nonisolated func retroAchievementsEvent(_ info: [String: Any]) {
        Task { @MainActor [weak self] in
            self?.raState.event(info)
        }
    }

    /// RetroAchievements does not recognize this client yet, so hardcore
    /// unlocks land as softcore. One notice per game.
    nonisolated func retroAchievementsEmulatorUnrecognized() {
        Task { @MainActor [weak self] in
            self?.raState.emulatorUnrecognized = true
        }
    }
}
