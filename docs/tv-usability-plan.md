# Apple TV usability plan

The Apple TV app plays games borrowed from a phone. This plan covers what is
missing or wrong on the TV after the September 2026 design pass. Each work
package (WP) below is meant to be done and checked on its own, in order.

Read `AGENTS.md` first. Plain language in comments and commit messages. Match
the surrounding code: comments explain *why*, one short paragraph at most.

## Ground rules for every package

- Only touch the files a package names, plus a test script if it says so.
- Do not edit `Cassowary.xcodeproj`; it is generated from `Cassowary/project.yml`.
- New files in `Cassowary/Sources/` start with the BSD header used by the
  files next to them.
- Debug-only launch flags (`cassowary.test…`, `cassowary.tv…`) go inside
  `#if DEBUG` where the surrounding hooks are, and follow their style.
- Build both apps before calling a package done:
  `./Scripts/cassowary/build-cassowary.sh --app-only` (phone) and
  `./Scripts/cassowary/build-cassowary.sh --tvos-sim --app-only` (TV).
- The Siri Remote cannot be scripted in the Simulator. Anything that depends
  on real remote presses is listed under "Needs a real Apple TV" for the
  maintainer to try.

---

## WP1 — Done. A game left with the TV button is saved and synced

**The bug.** Everything that protects a session lives in the Close Game
button (`TVPlayerView.close()` → `finishClose()` → `TVStore.finishPlaying`).
Nothing happens when the app goes to the background — someone presses the TV
button, or the TV sleeps. Then:

- the game keeps running, unpaused;
- no autosave is written;
- save states made this session stay beside the ROM in `Library/Caches`,
  which tvOS may empty, and are never filed to the vault;
- nothing syncs to the phone;
- play history is not recorded, so Continue Playing stays empty.

If tvOS then ends the app, the session is lost.

**What to build.**

1. `TVStore`: split `finishPlaying(_:)` into two steps that can each run
   more than once safely:
   - `fileSessionSaves(_ game:)` — copy the beside-ROM states into the vault
     and scan (the first half of `finishPlaying` today);
   - `recordPlay(_ game:)` — set `lastPlayedAt`, and bump `playCount` only
     once per play session (track the session, e.g. by the id of the game
     being played and a flag reset in `prepareForPlay`).
   `finishPlaying` calls both, then syncs, exactly as now.
2. `TVPlayerView`: watch `scenePhase`. When it leaves `.active` with a game
   running: pause, write the autosave (skip in hardcore, as `close()` does),
   then `fileSessionSaves` + `recordPlay` + `syncNow`. When it comes back to
   `.active`: open the game menu (paused), so the player chooses to resume.
   Do not close the game.
3. `TVStore.start()`: recovery for a session that ended without either path
   (the app was killed mid-game). For each downloaded game, if a state beside
   its ROM is newer than the vault copy (or the vault has none), file it.
   Then scan.

**Check it.**
- Both apps build. `test-sharing.sh` still passes all checks.
- Add to `Scripts/cassowary/test-sharing.sh`, after the "picture changed"
  check: put the TV app in the background by launching the TV's Settings app
  (`xcrun simctl launch "$TV_UDID" com.apple.TVSettings`), wait a few
  seconds, and pass if the TV's save vault holds an autosave file for a game
  (`$TV_CONTAINER/Library/Application Support/Sharing/…`; find the vault
  path from `SharingPaths.tvSaveVault`). Fail with a clear message otherwise.

---

## WP2 — Done. The Siri Remote plays simple games, and Back always escapes

**Today.** The engine ignores the Siri Remote: `OEiOSGameControllerManager`
only bridges extended gamepads ("not an extended gamepad; ignored"). That is
also why the remote's Back reaches the app and opens the game menu. A real
gamepad is handed to the game whole: its Menu button is the game's Start.

**The rule.** No matter what controls the game, **Back on the remote always
opens the game menu** and is never given to the game. A gamepad must also
have a way to reach the menu without the remote.

**What to build.**

1. The remote drives the game from the TV app, the way the phone's
   on-screen buttons do, so it and a gamepad are **both player 1** (decided
   by the maintainer; the engine is not changed). While a game plays and
   the menu is closed, the Siri Remote's `microGamepad` presses the game's
   buttons through `GameSession.press/release`, using the keys a gamepad's
   controls map to in `session.layout.gamepadControls`:
   - `dpad` up/down/left/right → the d-pad (`reportsAbsoluteDpadValues = NO`
     and `allowsRotation = YES`, so the remote works held sideways);
   - `buttonA` (clicking the touch surface) → what gamepad A presses;
   - `buttonX` (Play/Pause) → what gamepad B presses;
   - `buttonMenu` is left to the app.
   Held keys are released when the menu opens or the game stops.
2. Opening the menu while a game has the controller (`TVPlayerView`, and a
   small helper next to `ControllerCapture` if that is cleaner):
   - Siri Remote: `microGamepad.buttonMenu.pressedChangedHandler` opens the
     game menu. Keep `.onExitCommand` too; whichever fires first wins, and a
     second call while the menu is opening does nothing.
   - Extended gamepad: a short press of Menu stays Start for the game;
     **holding Menu for about 0.7 s** opens the game menu. Use a
     `pressedChangedHandler` on `buttonMenu` (it does not replace the
     engine's `valueChangedHandler`). If `buttonHome` is delivered, a press of
     it opens the menu too.
   - Attach these while a game plays and remove them when it stops. Handle
     controllers that connect mid-game (`GCControllerDidConnect`).
3. The game menu gets a row under Resume, shown only for systems whose
   layout has them: **Press Start** and **Press Select**, side by side. Each closes the
   menu, then taps that button (press, ~150 ms, release) through the same
   path `GameSession.pressButton(named:)` uses. Find the buttons in
   `session.layout` by id containing "Start" / "Select".
4. The start-of-game hint (`hintBanner`, "Press Back for options") says what
   applies: with only the Siri Remote, "Click to press A · Play/Pause is B ·
   Back for the menu"; with a gamepad, "Hold Menu or press Back on the remote
   for options".

**Check it.** Both apps build; phone and sharing tests still pass.

**Needs a real Apple TV:** remote as controller in a Game Boy or NES game,
sideways too; Back opens the menu mid-game with a gamepad connected;
holding Menu on a gamepad; a short Menu press still pauses the game (Start).

---

## WP3 — Done. Launch flags for the screens no screenshot has reached

Add debug launch flags, in the style of the existing ones, so each screen can
be opened without a remote:

- `cassowary.tvOpenVideo` — like `testOpenFilters`, but opens the Video list.
- `cassowary.tvOpenSystem <systemIdentifier>` — Settings tab, then pushes
  `TVSystemView` for that system.
- `cassowary.tvOpenCorePicker <systemIdentifier>` — presents
  `TVCorePickerView` for the first game of that system (or a made-up
  `LocalGame` if there is none).
- `cassowary.tvSampleConflict` — shows `TVConflictView` with a made-up
  conflict, never written to disk.

All of them live in `Cassowary/Sources/TV/TVScreenshotHooks.swift`, which
says how to launch with each.

---

## Later packages (planned, not started)

- **WP4 — RetroAchievements on the TV using the phone's sign-in.** A new
  paired-only endpoint on the phone hands the TV the RetroAchievements
  username and token, only if the phone's new "Share sign-in with Apple TV"
  switch is on (off by default: the link is plain HTTP on the home network).
  The TV stores it in its own keychain, shows "Signed in as … from <phone>"
  with Sign Out, and gets unlock notices sized for a TV.
- **WP5 — Controller button remapping on the TV**, with the same bindings
  store the phone uses.
- **WP6 — Delete a save slot on the TV**, removing the vault copy and
  telling the phone, so the slot does not come back on the next sync.
- **WP7 — Done. Sync you can see:** the library says "Syncing saves…",
  "N saves to send" or "Saves synced 2 minutes ago"; Settings adds the last
  sync time, saves waiting for another device, and a Sync Now that shows it
  is working. Two bugs that left saves "to send" for ever are fixed (see
  the commit).
