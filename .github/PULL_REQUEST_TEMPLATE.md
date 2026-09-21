## What does this PR do?

<!-- One or two sentences describing the change. What problem does it solve, or what does it add? -->

## What did you test?

<!-- How did you verify this works? Which game(s), system(s), or workflow(s) did you test with? -->

## Which cores or systems are affected?

<!-- List the emulation cores or systems this change touches, if any. If it's a general app change, say so. -->

## Did you use AI tools?

<!-- We're fully open to AI-assisted contributions — just be transparent about it. Did you use Claude, Copilot, Cursor, or anything else? If so, briefly describe how. (e.g. "Used Claude to draft the fix, reviewed and tested it myself.") -->

## Linked issues

<!-- Use "Fixes #N" to auto-close an issue on merge, or "Related to #N" to soft-link -->

Fixes #

---

## How to test locally

Replace `NUMBER` with the real PR number.

```bash
# 1. Check out this PR
gh pr checkout NUMBER

# 2. Build the app and everything it loads
./Scripts/cassowary/build-cassowary.sh

# 3. Run it in the Simulator
./Scripts/cassowary/run-cassowary.sh

# ...or run the end-to-end check
./Scripts/cassowary/test-cassowary.sh
```

The first build is slow because it builds every core. Later builds only build
what is missing.

If this PR changes a core, `build-cassowary.sh` restages it into the app
automatically. The app loads plugins from its own bundle, not from `build/` —
so a core that was only compiled will not be picked up.

<!-- Add any PR-specific setup here (ROM or system to test with, BIOS files, the specific behaviors to verify). -->

---

## PR checklist

- [ ] Branched from an up-to-date `main`
- [ ] Build passes: `./Scripts/cassowary/build-cassowary.sh`
- [ ] Tested in the Simulator (or on a device)
- [ ] No build logs, binaries, or credentials committed
- [ ] Copyright headers preserved on all modified files
- [ ] New files (if any) include the license header
