# Next up

Things to tackle later, written down at the end of the October 2026 Apple TV
round (see [`tv-usability-plan.md`](tv-usability-plan.md) for what that round
did). Roughly in order of how much each matters. Cross an item off by
deleting it once it is done.

## Still to build

- **Controller button remapping on the TV** (WP5 of the TV plan). The phone
  has a bindings screen; the TV has none, so a gamepad uses the defaults.
  Use the same bindings store, so a remap on one device could follow to the
  other later.

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
- **Leaving with the TV button** writes the autosave and syncs before tvOS
  suspends the app. It worked in the Simulator within five seconds; on a
  slow device it may need `beginBackgroundTask` to get the time.
- **RetroAchievements with a real account**: turn on Share With Apple TV on
  the phone, check the TV says "Signed in as …", earn an unlock and see the
  banner, and try pausing quickly in hardcore (the server can refuse; the TV
  then says how long to wait instead of opening the menu).

## Bugs and rough edges found, not fixed

- **Atari Jaguar shows "no core installed" in the Mac app.** VirtualJaguar is
  in `Scripts/cassowary/cores.txt`, so it probably fails to build for Mac
  Catalyst. Run `./Scripts/cassowary/build-core-ios.sh VirtualJaguar --catalyst`
  and read the error.
- **Un-favoriting does not sync.** Play history merges by "either device has
  it as a favorite", so a favorite removed on one device comes back from the
  other. Favorites need a version (or a time) like saves have.
- **Play counts undercount.** Merging keeps the larger of the two counts, so
  playing on both devices between syncs loses plays. Low stakes.
- **Saves waiting for another device never clear.** Saves for a game the
  phone no longer has wait for "its own source" for ever (Settings → Waiting
  for another device). There should be a way to forget a game and its saves
  on the TV; today a downloaded game the phone removed also stays.
- **Replacing a ROM with a different file of the same name** attaches the old
  file's save states to the new game, since saves sit beside the ROM by name.
  The sharing test hit this; it now clears them, but a person could too.
- **`build-cassowary.sh` on a fresh worktree** stops until
  `build/cassowary-catalyst/` and `build/cassowary-simulator/` exist (found by
  the library-title agent, which made the folders by hand). Make the script
  create them.
- **Compiler warnings that will be errors in Swift 6**: `GameSession`'s and
  `SystemBindingsForwarder`'s conformances cross into main-actor code
  (`GameSession+Owner.swift`, `InputBindings.swift`), a non-`Sendable` local
  function in `PeerBrowser.swift`, and an always-unused `??` in
  `MediaClient.swift`.

## Housekeeping

- **Old save conflicts on the test simulators** (`Cassowary-Audit-Phone`,
  `Cassowary-Audit-TV2`) came from test runs before the sharing test cleaned
  up after itself. Resolve or erase those simulators; they are not real data.
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
