# Broadcast picker hotfix report

## Scope

- Changed `BroadcastPickerView` so `RPSystemBroadcastPickerView` is constructed at the displayed 52 by 52 point size instead of `.zero`.
- Added a focused app-owned factory characterization test. It creates the real `RPSystemBroadcastPickerView` before SwiftUI layout and verifies its public initial bounds and ReplayKit configuration. The earlier internal-button inspection is retained only as a historical ReplayKit diagnosis; the current test neither traverses nor invokes private subviews.

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

## Fix Round 2/5: constructor mutation evidence

To prove the current factory-focused test observes behavior rather than only the factory's presence, the production factory was temporarily changed from its 52 by 52 frame to `.zero` without staging or committing that state. The same focused test then failed with exit 65 at the constructor root-bounds assertion:

```text
XCTAssertEqual failed: ("(0.0, 0.0)") is not equal to ("(52.0, 52.0)")
```

This failure came directly from `BroadcastPickerView.makePicker()` before SwiftUI host layout, and the extension and microphone assertions remained available in the same test. The 52 by 52 constructor frame was then restored, and the identical focused test passed with exit 0. The final production picker file matches commit `498711b`; this round changes only this report.
