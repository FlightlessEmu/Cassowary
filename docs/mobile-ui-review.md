# iPhone and iPad UI review — October 1, 2026

Review order: finish Catalyst, then iPhone, then iPad. Each platform needs
screenshots and checks of navigation, library controls, Settings, and gameplay.

Apple's [split-view guidance](https://developer.apple.com/design/human-interface-guidelines/split-views)
calls for considering multiple window widths on iPad. The app uses a navigation
stack on portrait phones and split navigation where there is room.

## Source findings

- The portrait phone's navigation stack did not use the stored navigation path.
  Rotation code updated that path, so returning from landscape could lose the
  current games screen. Bound the stack to the existing path and restore both
  All Games and selected-system screens when returning to portrait.
- Game toolbar labels and notices now use a dark backing. Catalyst inspection
  verified readability over a bright frame; the same controls were inspected on iPhone and iPad.
- Toolbar buttons have 44-point touch targets and plain styling, avoiding an
  extra Catalyst button background around their circular backing.
- An unmatched search uses the native search-results empty state instead of
  claiming the library contains no games and suggesting an import.
- Mobile Settings keeps its native navigation stack and Done action. Mac-only
  window controls and category sidebar remain behind Catalyst compilation guards.

## Live checks

Device Hub access worked after reopening the thread directly in Codex. Review
used an iPhone 17 Simulator and an iPad mini Simulator running iOS/iPadOS 26.

- iPhone portrait and landscape: library titles and controls, back navigation,
  selected-screen retention across rotation, searching and no results, sorting,
  the native import picker and cancellation, and light/dark library appearance.
- iPhone Settings: all sections, About, system/core choices, keyboard and
  controller binding pages, artwork and sharing pages. Sharing stayed disabled.
- iPad portrait and landscape: split-view titles, selected system, sidebar
  collapse/restore, Settings sheet, and a narrow floating app window.
- iPad: dark appearance and the largest accessibility text size. At accessibility
  sizes the library now uses full-width navigation, a single game column,
  smaller cover images and unrestricted title wrapping.
- Both platforms: homebrew input-test game launch, pause, resume and close.
  This checks the UI flow, not general emulator compatibility.

## Further fixes from live inspection

The Glass controls could disappear over the test game's white frame. Their
backing is now dark, with a subtle light edge; the Settings preview also uses
that game appearance. Haptic settings are only shown when Core Haptics reports
hardware support, following Apple's
[hardware capability guidance](https://developer.apple.com/documentation/corehaptics/preparing-your-app-to-play-haptics).
This avoids offering vibration controls on an unsupported iPad or Simulator.

## Build and regression checks

The full Simulator build and existing end-to-end check passed during the review.
Touch, keyboard, and gamepad A input changed the test frame from bright to dark.
After bringing the UI changes onto the latest main branch, both full Catalyst
and Simulator builds passed. The final end-to-end check passed on the test-only
iPad Simulator: idle brightness 248; touch, keyboard and gamepad brightness 0.
An earlier run on the mixed phone library selected another game, so it was
not a valid input-test result. No runtime claim is made for that game.

A disk-space failure interrupted another build. Cleaning obsolete generated
Xcode output and downloaded build artifacts freed space, then the full builds
passed. No source changes were needed for that failure.

## Limits

Physical controller hardware, network sharing, physical-device haptics, every
Settings screen at maximum Dynamic Type and every possible game error were not tested. No bindings,
artwork or real-device library entries were deleted. The existing end-to-end
script replaces its Simulator Game Boy fixtures.
