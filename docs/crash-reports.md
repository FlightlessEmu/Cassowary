# Crash and hang reports

How Cassowary collects and reads crashes, and where to look when a core takes
the app down.

---

## Why the app cannot just write a crash down

The emulator cores are not separate processes on iOS. Unlike the Mac build,
where the core runs in an XPC helper, the phone app loads the core into itself
and runs it on its own thread. So when a core hits a bad pointer, the whole app
goes with it — there is no moment in which the app could write a report.

There is no way around this on iOS. There are no third-party XPC services, the
app cannot spawn a helper process, and app extensions are too memory-limited (and
too short-lived) to host a core. See [PROJECT_LAYOUT.md](PROJECT_LAYOUT.md) for
where things live.

So the app does two things instead:

1. It asks the **system** for the reports it collected (MetricKit), and keeps
   them on the device so they can be shared.
2. It leaves a **note** while a game is running, and removes it when the game
   stops cleanly. A note that survives to the next launch means the app was
   killed mid-game.

---

## What the app keeps

`DiagnosticsStore` (in `Cassowary/Sources/Models/`) writes to:

```
Documents/Diagnostics/
├── crash-20260929-160353-0.json   # one file per system payload
├── hang-…
└── last-session.json              # only while a game runs, or after a crash
```

Nothing is uploaded anywhere. The folder is inside the app's own container, so
it is also visible over Finder file sharing and can be copied off a phone with
`devicectl`.

## Reading them

- **In the app:** Settings → Diagnostics → Crash & Hang Reports. Each report can
  be shared on its own, and the last uncleanly-closed game is shown at the top.
- **From a phone, over the wire:**

  ```bash
  UDID=$(xcrun devicectl list devices --columns udid --hide-headers | head -1)
  xcrun devicectl device copy from \
    --device "$UDID" \
    --domain-type appDataContainer --domain-identifier org.cassowary.Cassowary \
    --source Documents/Diagnostics --destination ./crash-reports
  ```

- **In Xcode:** Window → Devices and Simulators → View Device Logs, for a build
  installed from Xcode. Xcode Organizer (Window → Organizer → Crashes) only
  covers TestFlight and App Store installs, not `devicectl` ones.

## Symbolicating a MetricKit report

MetricKit hands over a `callStackTree` of raw addresses. To turn them into
function names you need the `.dSYM` for the exact build that crashed:

```bash
# Where the build left it:
find build -name 'Cassowary.app.dSYM'

# Symbolicate one address (repeat for each frame you care about):
xcrun atos -arch arm64 -o build/…/Cassowary.app.dSYM/Contents/Resources/DWARF/Cassowary \
  -l 0x102d50000 0x102d51234
```

Keep each release's `.dSYM` somewhere it will not be cleaned away, or the
reports cannot be read later.

## Limits worth knowing

- MetricKit only delivers reports when the phone is set to share analytics
  (Settings → Privacy & Security → Analytics & Improvements), and they arrive on
  a **later launch** — usually within a day.
- It does not include Objective-C exception names or messages.
- Native crashes and hangs are covered; a plain Swift `fatalError` is caught too
  (as a `SIGTRAP`/`SIGILL` termination), but a core's own logging is not.

## Testing the screen without a crash

Launch with the sample flag; the app writes a report shaped like MetricKit's and
a fake "last session", so the screen can be looked at in the Simulator:

```bash
xcrun simctl launch <device> org.cassowary.Cassowary -cassowary.writeSampleDiagnostics YES
```
