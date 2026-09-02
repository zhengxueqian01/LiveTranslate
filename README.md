# LiveTranslate

[English](README.md) | [简体中文](README.zh-CN.md)

<p align="center">
  <img src="ios/LiveTranslate/LiveTranslate/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="128" alt="LiveTranslate app icon">
</p>

LiveTranslate is a privacy-first iOS 26 proof of concept that turns audio from supported apps into live bilingual captions. It captures system-provided app audio through ReplayKit, performs speech recognition and translation on the device, and keeps the latest captions visible in a Picture in Picture (PiP) window while you use another app.

> [!IMPORTANT]
> LiveTranslate is a personal proof of concept, not a production or App Store release. The complete ReplayKit, Speech, Translation, and PiP workflow must be validated on a physical iPhone. Simulator builds and unit tests cannot verify system-audio capture or model behavior on a real device.

## Highlights

- Cross-app captions for audio sources that iOS allows ReplayKit to capture.
- Original and translated text displayed together in a PiP overlay.
- On-device speech recognition with `SpeechAnalyzer` and `SpeechTranscriber`.
- On-device translation with `TranslationSession`.
- Input and output language lists discovered dynamically from the current device and iOS version.
- Explicit, on-demand model downloads; switching languages does not silently download resources.
- No server, account, third-party SDK, analytics, or telemetry.
- Raw audio is neither uploaded nor stored.
- Only the latest caption snapshot is retained; there is no transcript history.

## How It Works

```text
Audio from another app
        │
        ▼
ReplayKit Broadcast Upload Extension
        │  .audioApp samples
        ▼
SpeechAnalyzer + SpeechTranscriber
        │  progressive transcript
        ▼
Caption segmentation and translation scheduling
        │
        ▼
TranslationSession
        │  original + translated text
        ▼
App Group shared snapshot
        │
        ▼
In-app preview + Picture in Picture captions
```

The broadcast extension performs recognition and translation, then writes a bounded caption snapshot to the shared App Group. The main app observes that snapshot and renders it both in the app and in the PiP window.

## Requirements

- macOS with Xcode 26.6 or later.
- A physical iPhone running iOS 26 or later.
- An Apple development team for local code signing.
- A non-DRM media source, such as a local video in Files or a web page that permits screen recording.
- An internet connection when downloading a language model for the first time. Prepared models can subsequently be used on device.

## Build and Install

1. Clone the repository and open the Xcode project:

   ```bash
   git clone https://github.com/zhengxueqian01/LiveTranslate.git
   cd LiveTranslate
   open ios/LiveTranslate/LiveTranslate.xcodeproj
   ```

2. Select the `LiveTranslate` and `LiveTranslateBroadcast` targets in Xcode.
3. Enable **Automatically manage signing** and select the same Apple development team for both targets.
4. Confirm that both targets use the same App Group:

   ```text
   group.com.xueqianzheng.LiveTranslate
   ```

5. Confirm the default bundle identifiers, or replace them consistently if they are unavailable for your team:

   ```text
   App:       com.xueqianzheng.LiveTranslate
   Extension: com.xueqianzheng.LiveTranslate.BroadcastExtension
   ```

6. Select your connected iPhone as the run destination and run the `LiveTranslate` scheme.

## Usage

1. Open LiveTranslate and choose the audio language and target language.
2. Review the Speech and Translation resource status.
3. Tap **下载所需模型** (Download Required Models) if the selected language pair is not ready.
4. Open the PiP caption window from the caption preview section.
5. Tap the system broadcast picker, select `LiveTranslateBroadcast`, keep the microphone disabled, and start the broadcast.
6. Switch to a supported source app and play non-DRM audio or video.
7. Stop the broadcast from the system broadcast controls when finished.

## Privacy

LiveTranslate is designed to keep the caption pipeline on the device:

- Captured audio is processed inside the broadcast extension.
- Raw audio is not uploaded or persisted.
- Speech and translation models are provided and managed by iOS.
- The App Group stores only the selected language configuration and the latest caption snapshot.
- The project contains no account system, application server, analytics, advertising, or telemetry.

## Known Limitations

- ReplayKit decides whether a source app exposes capturable audio. Compatibility cannot be guaranteed for every app.
- DRM-protected media, system calls, FaceTime, conferencing apps, and third-party calls may provide silent or unavailable audio.
- The broadcast extension processes `.audioApp` samples only. Microphone samples and video frames are ignored.
- The user must explicitly start and stop the ReplayKit broadcast through the iOS system interface.
- Available languages and language-pair support depend on the current device, iOS version, and installed system resources.
- Automatic language detection, transcript history, search, export, cloud fallback, and account sync are not included.
- Device-level latency, thermal behavior, PiP continuity, and long-session stability still require physical-device acceptance testing.

## Project Structure

```text
ios/LiveTranslate/
├── LiveTranslate/             Main SwiftUI app and PiP renderer
├── LiveTranslateBroadcast/    ReplayKit broadcast upload extension
├── Shared/                    Language, caption, audio, and coordination models
├── LiveTranslateTests/        Unit and regression tests
└── LiveTranslate.xcodeproj/   Xcode project
```

Design notes and implementation plans are available under [`docs/superpowers`](docs/superpowers/).

## Verification

Build without code signing:

```bash
xcodebuild \
  -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslate \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath /tmp/LiveTranslate-DerivedData \
  build
```

Run the test suite on an available simulator:

```bash
xcodebuild test \
  -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslate \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  -only-testing:LiveTranslateTests \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/LiveTranslate-DerivedData
```

Automated checks cover state management, language configuration, model preparation, caption segmentation, audio conversion, translation ordering, and PiP rendering logic. A signed physical-device test remains required for the end-to-end workflow.

## License

LiveTranslate is available under the [MIT License](LICENSE).
