# Next up

Things to tackle later, written down at the end of the October 2026 Apple TV
round (see [`tv-usability-plan.md`](tv-usability-plan.md) for what that round
did). Roughly in order of how much each matters. Cross an item off by
deleting it once it is done.

## Still to build

- **Try DS microphone input with a real game** (Nintendogs, or any game
  that asks you to blow). It is built: the app listens only while a game
  asks, and the phone and Mac use the real microphone after asking
  permission; a Blow button (phone top bar, TV game menu) stands in where
  there is none. The Mac build was not checked: it needs the new
  `device.audio-input` entitlement to hear anything.
- On a narrow phone the Blow button squeezes the game's title in the top
  bar to a few letters while a game listens.

## Needs a real Apple TV

None of these can be checked in the Simulator: it has no Siri Remote to
press, and no real RetroAchievements account was used.

- **The Siri Remote as a controller**: swipes and clicks on the touch surface
  for the d-pad, click for A, Play/Pause for B, in a Game Boy or NES game.
  Also held sideways.
- **Back opens the menu mid-game**, with only the remote and with a gamepad
  connected too.
- **Holding Menu on a gamepad** (0.7 s) opens the menu, and a short press is
  still the game's Start. Known side effect to judge: during the hold the
  game also sees Start pressed, so some games pause themselves behind the
  menu. If that is annoying, hold Menu to open the menu and do not pass that
  press to the game.
- **Home on a gamepad** opens the menu, if tvOS delivers it at all.
- **Remapping a controller's buttons** (Settings → a system → Controller
  Buttons): choose a button, press a control, and check it sticks in a game.
  While "Press a Button" is up the controller goes to the engine, so Back on
  the Siri Remote, or ten seconds, is the way out; check both.
- **Leaving with the TV button** writes the autosave and syncs before tvOS
  suspends the app (it now asks for background time to finish).
- **RetroAchievements with a real account**: turn on Share With Apple TV on
  the phone, check the TV says "Signed in as …", earn an unlock and see the
  banner, and try pausing quickly in hardcore (the server can refuse; the TV
  then says how long to wait instead of opening the menu).

## Bugs and rough edges found, not fixed

- **Atari Jaguar showed "no core installed" in the Mac app** (1 October).
  Not reproduced since: VirtualJaguar builds for Mac Catalyst cleanly
  (40 files), the Mac app built that morning contains it as a Catalyst
  binary, and opening it logs no plugin errors. The app lists a core from
  its Info.plist alone, so that message means the core was missing from
  the build that was running. If it shows again, check
  `Cassowary.app/Contents/PlugIns/Cores/` in that build.
- **Replacing a ROM with a different file of the same name** attaches the old
  file's save states to the new game, since saves sit beside the ROM by name.
  The sharing test hit this; it now clears them, but a person could too.
- **Compiler warnings that will be errors in Swift 6**: `GameSession`'s and
  `SystemBindingsForwarder`'s conformances cross into main-actor code
  (`GameSession+Owner.swift`, `InputBindings.swift`), a non-`Sendable` local
  function in `PeerBrowser.swift`, and an always-unused `??` in
  `MediaClient.swift`.

## Housekeeping

- **If every TV check in test-sharing.sh fails at once**, the Mac's Bonjour
  may have stopped resolving the phone (the simulators share it; it happened
  on 1 October). `CASSOWARY_TEST_DIRECT=1` connects by address instead.
- **Run the tests on simulators of their own.** Every worktree shares the
  default ones, and other work leaves games in them (a PlayStation disc once
  made the input test boot the wrong game). `test-cassowary.sh --device-id`
  and `CASSOWARY_TEST_PHONE` / `CASSOWARY_TEST_TV` for `test-sharing.sh` do it.
- **`chore/core-upstream-maintenance`** (another session's branch) uses
  `cores/upstream.json` as the core list where `main` now uses
  `Scripts/cassowary/cores.txt`, and keeps the four removed cores. Decide
  whether to merge it, adapt it, or delete it; it conflicts with `main` in
  `build-cassowary.sh` and CI either way.
- **In the Simulator, sign-ins are kept in the app's settings**, not the
  keychain: unsigned Simulator builds have no keychain. A device build always
  uses the keychain. Nothing to do, but worth knowing when a sign-in seems to
  "stick" in the Simulator.
