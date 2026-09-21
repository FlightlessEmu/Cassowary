Run the verification loop for the current change.

This is the default check after any code change. Do not ask the user to test things manually until this has run.

## When to run which mode

| Change touched | Command |
|---|---|
| App code (`Cassowary/Sources/`), SDK, Kit, Shaders | `./Scripts/cassowary/build-cassowary.sh` |
| A core under `cores/` | `./Scripts/cassowary/build-core-ios.sh <CoreName>` |
| The whole thing, then launch it in the Simulator | `./Scripts/cassowary/test-cassowary.sh` |
| Scripts, CI, docs only | skip — no code to verify |

## What it does

`build-cassowary.sh` builds, in order: the SDK frameworks, OpenEmuShaders, OpenEmuKit, the system plugins, any missing core plugins, and the app itself. Cores already present in that mode's output directory (`build/cassowary-plugins/` for the Simulator, `build/cassowary-plugins-device/` for a phone) are skipped, so it is usually fast after the first run.

`test-cassowary.sh` runs the app end to end and checks it launched and stayed up.

## What you do with the output

- `** BUILD SUCCEEDED **` means the app built. Anything else means stop and fix it.
- Read the build log — do not pipe it through `tail`. New warnings are worth flagging even on a passing build.
- Only escalate to "please test this in a real game session" if the build passed and the change is one that genuinely needs in-game behavior to validate (input mapping, save states, rendering, audio sync, RA cheevos triggering).

## The one big footgun

The app loads plugins from its own bundle (`Cassowary/PlugIns/`), not from `build/`. Building a core does not change what the app runs. Always rebuild and restage through `build-cassowary.sh` before claiming a test result, or you are testing the previously staged plugin.

## What you do not do

- Do not ask the user to launch the app or read logs for you. Run the build and the Simulator yourself.
- Do not claim a core works because it compiled. Compiling and running are different things.
