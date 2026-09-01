# Broadcast picker hotfix report

## Scope

- Changed `BroadcastPickerView` so `RPSystemBroadcastPickerView` is constructed at the displayed 52 by 52 point size instead of `.zero`.
- Added a focused UIKit/SwiftUI characterization test. It creates the real representable in a 52 by 52 window, verifies the public picker bounds and ReplayKit configuration, and, when ReplayKit exposes its system button, verifies that button has positive finite bounds. The test does not invoke the button or use private APIs.

## TDD evidence

### RED

Command:

```sh
xcodebuild test -quiet -parallel-testing-enabled NO -project ios/LiveTranslate/LiveTranslate.xcodeproj -scheme LiveTranslate -destination 'platform=iOS Simulator,id=C1A3FD2D-B385-4153-B101-C5C824576F28' -only-testing:LiveTranslateTests/BroadcastPickerViewTests
```

Before the production change, the focused test failed with `XCTAssertGreaterThan failed: ("0.0") is not greater than ("0.0")`. This matches the observed ReplayKit system button's zero-height layout when the picker is created with `.zero`.

### GREEN

The same focused command passed after constructing the picker with a 52 by 52 frame.

## Verification

- Focused `BroadcastPickerViewTests`: passed.
- Full `LiveTranslateTests` on the fixed iPhone 17 Pro Max simulator: 50 passed, 0 failed, 0 skipped.
- `xcodebuild build -quiet -project ios/LiveTranslate/LiveTranslate.xcodeproj -scheme LiveTranslate -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`: passed.
- `git diff --check`: passed.
- No private ReplayKit API, private-button invocation, network/telemetry/dependency changes, or changes to the prohibited project, AppIcon, Speech, Translation, or Coordinator files were included in this hotfix.

## Remaining on-device check

The iPhone needs the normal reinstall-and-open visual check to confirm that the system broadcast glyph is now visible in the App row. Extension registration was already independently verified through Control Center before this hotfix.

## Fix Round 1/5: stable constructor boundary

The initial test hosted the SwiftUI representable and observed it after SwiftUI layout. That did not stably prove the app-controlled construction contract: a `.zero`-constructed picker can later receive a 52 by 52 outer layout, and the internal ReplayKit button is not guaranteed to exist in every simulator configuration.

The production view now exposes the smallest app-owned construction entry point, `BroadcastPickerView.makePicker()`, and `makeUIView` calls that same factory. The focused test calls the factory directly before any SwiftUI layout and asserts the real returned `RPSystemBroadcastPickerView` has exactly 52 by 52 positive finite bounds, the exact preferred extension, and `showsMicrophoneButton == false`.

### Round 1 TDD evidence

- RED: the focused test first failed to compile because `BroadcastPickerView.makePicker` did not exist (exit 65). This was the intended missing-factory boundary failure.
- GREEN: after extracting the factory and routing `makeUIView` through it, the same focused test passed (exit 0).
- Full `LiveTranslateTests`: 50 passed, 0 failed, 0 skipped.
- Generic iphoneos build with `CODE_SIGNING_ALLOWED=NO`: passed.
- Diff check: passed.

### Diagnostic distinction

The factory test's RED/GREEN contract is the constructor-time root `RPSystemBroadcastPickerView` bounds and public ReplayKit configuration. The earlier observed internal `UIButton` zero-height state is a useful real-device/simulator diagnosis of ReplayKit's reaction to a zero construction frame, but it is not a required test precondition and no longer carries the regression test's RED result.
