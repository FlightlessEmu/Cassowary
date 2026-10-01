# Catalyst UI review — October 1, 2026

This review covers the Mac library, game controls, and Settings screens.
Desktop inspection resumed with a fresh capture connection while the Mac was awake.

## Apple guidance

- [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars):
  keep the sidebar toggle at the leading edge, place the title beside it, and
  group related actions. The sidebar toggle and Settings have different jobs.
- [Settings](https://developer.apple.com/design/human-interface-guidelines/settings):
  use the app menu and Command-comma, organize settings into categories, remember
  the selected category, and use a separate Settings window on the Mac.
- [Mac interface idioms](https://developer.apple.com/documentation/uikit/choosing-a-user-interface-idiom-for-your-mac-app):
  use the Mac idiom for native control sizes and spacing.
- [MetricKit](https://developer.apple.com/documentation/metrickit):
  report delivery varies, and the system does not provide a diagnostic report
  for every incident.

## Changes made

| Area | Finding and change |
| --- | --- |
| Library heading | Removed the cramped custom title capsule. The sidebar uses a normal Library section header. |
| Window title | The selected system, or Games, is now the native window title. Removed the separate large content heading and redundant app title. |
| Toolbar | Moved controls into a compact native window toolbar. Sidebar toggle is leading and tracks the sidebar divider; Add, Sort, Refresh, and Search follow. |
| Menu access | Removed the toolbar gear. Settings is available in the app menu with Command-comma. Add Games has Command-O, search has Command-F, and sorting is available in the Library menu. |
| Empty search | Uses the native no-results message instead of claiming the library has no games. Verified filtering and clearing in the final build. |
| Mac controls | Selected the Mac interface idiom in the build spec. This fixes the oversized controls and nested search appearance seen in the earlier layout. |
| Selected system | Explicit selection tags and a visible row background keep the current system readable in the Catalyst sidebar. |
| Narrow windows | Catalyst keeps its split navigation and native toolbar rather than switching to phone navigation. |
| Settings organization | Added a separate Mac Settings window with Controls, Video, Library, Sharing, Systems, About, and Diagnostics categories. Remembered the last category and kept the category sidebar visible on subpages. |
| Touch-only options | Hidden button haptics on Mac. Kept on-screen control styling because the game view still offers these controls. |
| Binding editors | Titles now identify Keyboard Bindings and Controller Bindings. Mac instructions use click/right-click; context menus offer clearing a binding. |
| Help text | Updated artwork, sharing, per-system, and diagnostics explanations for desktop use. |
| About | Restored version information in the generated Catalyst plist and included Mac in the app description. |
| Game controls | Used a dark backing for game toolbar labels and notices, then verified readability over a white test frame. Toolbar buttons use 44-point targets and plain styling. |
| Diagnostics empty state | Changed the claim that no crashes had occurred to the accurate statement that no reports had been received. |

## Verification

Before desktop capture stopped working, live checks covered system selection
and title updates, sidebar hide/show, the sorting menu, search and clearing
search, the Add Games file picker and cancellation, Command-O, Settings access,
Mac-sized controls, and per-system settings. The Mac interface idiom and search
appearance were inspected onscreen.

Live inspection now also covers every Settings category, artwork and sharing
subpages, About, Diagnostics, Game Boy settings, keyboard binding context menus,
the controller empty state, and game launch/pause/close. The category sidebar
remains available during subpage navigation. Command-comma opens the separate
Settings window and reuses it. The game toolbar returns on closing the game.

The homebrew input-test game supplied a plain white frame; this review confirms
the game UI flow, not rendering correctness or general core compatibility.
No bindings were cleared, and sharing was left disabled.

The final full Catalyst build succeeded with all 26 core bundles staged,
including MAME. The final iOS Simulator app-only build also succeeded.
The generated Catalyst plist reports version 1.3.0. Whitespace and shell syntax
checks passed.
The existing Simulator end-to-end check (`test-cassowary.sh --skip-build`)
passed: touch, keyboard, and gamepad A input each changed the rendered test
frame from bright to dark. This confirms the Simulator input/rendering path;
it does not substitute for testing Catalyst cores.

Direct pointer entry, filtering, and clearing search were verified after a fresh
launch. Automation's accessibility click did not focus the native search field;
a pointer click did. Command-F leaves the search field focused in an active
window. Capture resumed after resetting the desktop connection following a rebuild.
Final library and Settings screenshots were captured. A narrower Mac window,
pointer-based sidebar collapse/restore, selected-row highlighting, and final
game-control contrast were inspected live.

## Remaining checks

- Finish keyboard focus order checks.
- Check dark library appearance, long-title truncation, toolbar overflow, and
  repeated resizing beyond the wide and narrower windows already inspected.
- Check game error presentation. Final game-control contrast was inspected.

MAME needed separate platform build folders, explicit Metal selection for BGFX,
and SQLite's standard locking mode to avoid Catalyst's unavailable OpenGL ES
headers and host UUID API. These are build flags; upstream emulator source was
not edited. The earlier skipped-core build is superseded by the full passing
build above. Compilation does not establish Arcade runtime compatibility.

No Mac artwork, game library entries, bindings, or diagnostic reports were
deleted during the review. The Simulator end-to-end script replaces Game Boy
fixtures in its test library. Controller hardware and network sharing were
not tested.

## Landing verification

Brought the changes onto the latest main branch, preserving Continue/Favorites,
BIOS notices, saved-game choices and microphone controls. The full Catalyst
and Simulator builds passed, including the newly shipped SwanStation bundle.
The final input regression check passed on the test-only iPad Simulator.
Native search filtering and its no-results state were checked again through
the toolbar field. The selected Mac row now fills the row width instead of
hugging its label.
