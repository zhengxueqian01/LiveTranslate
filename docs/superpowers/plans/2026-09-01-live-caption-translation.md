# LiveTranslate iPhone PoC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个可由本地 Xcode 签名并安装到用户自有 iPhone 的 iOS 26 PoC，从 ReplayKit 系统广播读取英语或日语 App 音频，在设备端识别并翻译为简体中文，并通过画中画显示双语字幕。

**Architecture:** Broadcast Upload Extension 接收 `.audioApp`，在扩展内运行 `SpeechAnalyzer`、`SpeechTranscriber` 和 `TranslationSession`，只把低频字幕快照写入 App Group。主 App 负责语言选择、系统模型准备、广播入口、字幕预览以及基于 `AVSampleBufferDisplayLayer` 的 PiP 渲染。

**Tech Stack:** Xcode 26.6、Swift 6、SwiftUI、iOS 26、ReplayKit、Speech、Translation、AVKit、AVFoundation、XCTest。

**Spec:** `docs/superpowers/specs/2026-09-01-live-caption-translation-design.md`

## Global Constraints

- 部署目标固定为 iOS 26.0。
- 主 App Bundle Identifier：`com.xueqianzheng.LiveTranslate`。
- 广播扩展 Bundle Identifier：`com.xueqianzheng.LiveTranslate.BroadcastExtension`。
- App Group Identifier：`group.com.xueqianzheng.LiveTranslate`。
- 输入语言仅支持英语 `en-US` 和日语 `ja-JP`，由用户手动选择。
- 目标语言固定为简体中文 `zh-Hans`。
- 不保存原始音频，不添加服务器、API Key、第三方依赖、分析、遥测或广告。
- 广播扩展仅处理 `.audioApp`，忽略 `.audioMic` 和 `.video`。
- 自动测试使用 iPhone 17 Pro、iOS 26.5 模拟器；完整链路使用真机验证。
- 每个任务形成一个小而完整的 Git 提交。

---

## Planned File Structure

```text
ios/LiveTranslate/
├── LiveTranslate.xcodeproj/
├── LiveTranslate/
│   ├── LiveTranslateApp.swift
│   ├── ContentView.swift
│   ├── AppViewModel.swift
│   ├── ModelPreparationService.swift
│   ├── BroadcastPickerView.swift
│   ├── CaptionFrameRenderer.swift
│   ├── CaptionPiPController.swift
│   └── LiveTranslate.entitlements
├── LiveTranslateBroadcast/
│   ├── SampleHandler.swift
│   ├── SpeechPipeline.swift
│   ├── AppleTranslationClient.swift
│   └── LiveTranslateBroadcast.entitlements
├── Shared/
│   ├── LanguageSelection.swift
│   ├── SessionPhase.swift
│   ├── CaptionSnapshot.swift
│   ├── CaptionStore.swift
│   ├── CaptionSegmenter.swift
│   ├── AudioPCMConverter.swift
│   └── BroadcastCaptionCoordinator.swift
└── LiveTranslateTests/
    ├── LanguageSelectionTests.swift
    ├── CaptionStoreTests.swift
    ├── CaptionSegmenterTests.swift
    ├── AudioPCMConverterTests.swift
    ├── BroadcastCaptionCoordinatorTests.swift
    ├── CaptionFrameRendererTests.swift
    └── TestDoubles.swift
```

`Shared/` 文件加入 App 与广播扩展 Target；测试通过 `@testable import LiveTranslate` 访问 App Target 中的共享类型。`CaptionFrameRenderer.swift` 只加入 App Target，其余文件只加入所属 Target，避免同一类型在测试模块重复编译。

---

### Task 1: 使用本地 Xcode 创建工程、Target 和签名能力

**Files:**
- Create: `ios/LiveTranslate/LiveTranslate.xcodeproj/project.pbxproj`
- Create: `ios/LiveTranslate/LiveTranslate/LiveTranslateApp.swift`
- Create: `ios/LiveTranslate/LiveTranslate/ContentView.swift`
- Create: `ios/LiveTranslate/LiveTranslateBroadcast/SampleHandler.swift`
- Create: `ios/LiveTranslate/LiveTranslate/LiveTranslate.entitlements`
- Create: `ios/LiveTranslate/LiveTranslateBroadcast/LiveTranslateBroadcast.entitlements`
- Create: `ios/LiveTranslate/LiveTranslateTests/LiveTranslateTests.swift`

**Interfaces:**
- Produces: `LiveTranslate` App Target、`LiveTranslateBroadcast` Broadcast Upload Extension Target、`LiveTranslateTests` XCTest Target。
- Produces: App 与扩展共同持有 `group.com.xueqianzheng.LiveTranslate` entitlement。

- [ ] **Step 1: 用 Xcode 原生模板创建项目**

选择 `File > New > Project > iOS > App`：

```text
Product Name: LiveTranslate
Team: 用户本机已登录的 Personal Team 或开发者 Team
Organization Identifier: com.xueqianzheng
Interface: SwiftUI
Language: Swift
Testing System: XCTest
Storage: None
Include Tests: Yes
Create Git repository: No
Save parent directory: <repo>/ios
```

最终工程路径必须为 `ios/LiveTranslate/LiveTranslate.xcodeproj`。

- [ ] **Step 2: 添加 Broadcast Upload Extension**

选择 `File > New > Target > iOS > Broadcast Upload Extension`：

```text
Product Name: LiveTranslateBroadcast
Bundle Identifier: com.xueqianzheng.LiveTranslate.BroadcastExtension
Include UI Extension: No
Language: Swift
```

- [ ] **Step 3: 配置部署目标与能力**

App 和扩展 Deployment Target 均为 `iOS 26.0`。两个 Target 都启用：

```text
group.com.xueqianzheng.LiveTranslate
```

主 App 额外启用 `Audio, AirPlay, and Picture in Picture`。主 App Bundle Identifier 使用 `com.xueqianzheng.LiveTranslate`。使用 Automatic Signing，不把个人 Team ID 写入仓库。

- [ ] **Step 4: 验证工程**

```bash
xcodebuild -project ios/LiveTranslate/LiveTranslate.xcodeproj -list
xcodebuild -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslate \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: Scheme 与 Target 可见，模拟器构建成功。

- [ ] **Step 5: Commit**

```bash
git add ios/LiveTranslate
git commit -m "chore: scaffold LiveTranslate iOS project"
```

---

### Task 2: 建立共享语言、状态和字幕存储模型

**Files:**
- Create: `ios/LiveTranslate/Shared/LanguageSelection.swift`
- Create: `ios/LiveTranslate/Shared/SessionPhase.swift`
- Create: `ios/LiveTranslate/Shared/CaptionSnapshot.swift`
- Create: `ios/LiveTranslate/Shared/CaptionStore.swift`
- Create: `ios/LiveTranslate/LiveTranslateTests/LanguageSelectionTests.swift`
- Create: `ios/LiveTranslate/LiveTranslateTests/CaptionStoreTests.swift`
- Create: `ios/LiveTranslate/LiveTranslateTests/TestDoubles.swift`

**Interfaces:**
- Produces: `SourceLanguage`, `SessionPhase`, `CaptionSnapshot`。
- Produces: `CaptionStoreProtocol`，方法 `load()`, `save(_:)`, `clear()`。
- Produces: `CaptionStore`，默认使用 App Group UserDefaults。
- Produces: 测试用线程安全 `InMemoryCaptionStore`，实现同一个存储协议。

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import LiveTranslate

final class LanguageSelectionTests: XCTestCase {
    func testSupportedLanguagesMapToExpectedLocales() {
        XCTAssertEqual(SourceLanguage.english.speechLocale.identifier, "en-US")
        XCTAssertEqual(SourceLanguage.japanese.speechLocale.identifier, "ja-JP")
        XCTAssertEqual(SourceLanguage.english.translationSource.minimalIdentifier, "en")
        XCTAssertEqual(SourceLanguage.japanese.translationSource.minimalIdentifier, "ja")
        XCTAssertEqual(
            SourceLanguage.translationTarget,
            Locale.Language(identifier: "zh-Hans")
        )
    }
}

final class CaptionStoreTests: XCTestCase {
    func testSnapshotRoundTripsThroughIsolatedDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "CaptionStoreTests.\(UUID().uuidString)"))
        let store = CaptionStore(defaults: defaults)
        let snapshot = CaptionSnapshot(
            revision: 7,
            sourceText: "Hello",
            translatedText: "你好",
            phase: .translating,
            errorMessage: nil,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        try store.save(snapshot)
        XCTAssertEqual(try store.load(), snapshot)
        try store.clear()
        XCTAssertNil(try store.load())
    }
}
```

- [ ] **Step 2: 运行测试并确认失败**

```bash
xcodebuild test -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslate \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -only-testing:LiveTranslateTests/LanguageSelectionTests \
  -only-testing:LiveTranslateTests/CaptionStoreTests
```

Expected: FAIL，相关类型尚未定义。

- [ ] **Step 3: 实现最小共享模型**

```swift
enum SourceLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case english = "en-US"
    case japanese = "ja-JP"
    var id: String { rawValue }
    var speechLocale: Locale { Locale(identifier: rawValue) }
    var translationSource: Locale.Language {
        Locale.Language(identifier: self == .english ? "en" : "ja")
    }
    static let translationTarget = Locale.Language(identifier: "zh-Hans")
}

enum SessionPhase: String, Codable, Sendable {
    case idle, preparingModels, ready, broadcasting, recognizing, translating, stopped, failed
}

struct CaptionSnapshot: Codable, Equatable, Sendable {
    let revision: UInt64
    let sourceText: String
    let translatedText: String
    let phase: SessionPhase
    let errorMessage: String?
    let updatedAt: Date
}
```

`CaptionStore` 使用 `PropertyListEncoder/Decoder` 和键 `caption.snapshot`。默认初始化器必须打开 `group.com.xueqianzheng.LiveTranslate`；失败时抛出 `CaptionStoreError.appGroupUnavailable`，不得回退到 `.standard`。

`TestDoubles.swift` 提供同步协议可用的内存存储，使用 `NSLock` 保护快照：

```swift
final class InMemoryCaptionStore: CaptionStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: CaptionSnapshot?

    func load() throws -> CaptionSnapshot? {
        lock.withLock { snapshot }
    }

    func save(_ snapshot: CaptionSnapshot) throws {
        lock.withLock { self.snapshot = snapshot }
    }

    func clear() throws {
        lock.withLock { snapshot = nil }
    }
}
```

- [ ] **Step 4: 加入 Target 并运行测试**

Run: Step 2 命令。

Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add ios/LiveTranslate/Shared ios/LiveTranslate/LiveTranslateTests
git commit -m "feat: add shared caption session models"
```

---

### Task 3: 实现渐进字幕分句与翻译节流

**Files:**
- Create: `ios/LiveTranslate/Shared/CaptionSegmenter.swift`
- Create: `ios/LiveTranslate/LiveTranslateTests/CaptionSegmenterTests.swift`

**Interfaces:**
- Produces: `TranslationCandidate(revision:text:)`。
- Produces: `SegmentUpdate(displayText:translationCandidate:)`。
- Produces: `CaptionSegmenter.ingest(text:isFinal:timestampMilliseconds:)`。

- [ ] **Step 1: 写失败测试**

```swift
func testFinalResultImmediatelyCreatesTranslationCandidate() {
    var segmenter = CaptionSegmenter(minimumIntervalMilliseconds: 800)
    let update = segmenter.ingest(text: "Hello world.", isFinal: true, timestampMilliseconds: 100)
    XCTAssertEqual(update?.translationCandidate?.text, "Hello world.")
    XCTAssertEqual(update?.translationCandidate?.revision, 1)
}

func testGrowingPartialIsThrottledUntilIntervalExpires() {
    var segmenter = CaptionSegmenter(minimumIntervalMilliseconds: 800)
    _ = segmenter.ingest(text: "日本", isFinal: false, timestampMilliseconds: 0)
    let early = segmenter.ingest(text: "日本語の動画", isFinal: false, timestampMilliseconds: 300)
    let ready = segmenter.ingest(text: "日本語の動画です", isFinal: false, timestampMilliseconds: 900)
    XCTAssertNil(early?.translationCandidate)
    XCTAssertEqual(ready?.translationCandidate?.text, "日本語の動画です")
}
```

- [ ] **Step 2: 运行并确认失败**

```bash
xcodebuild test -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslate \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -only-testing:LiveTranslateTests/CaptionSegmenterTests
```

Expected: FAIL，`CaptionSegmenter` 未定义。

- [ ] **Step 3: 实现确定性规则**

```text
trim 后为空或与上次完全相同：忽略。
每次有效变化立即返回 displayText。
final 结果立即生成翻译候选。
partial 结果间隔不足 800ms 时仅更新显示。
partial 达到 800ms 且至少 4 个字符时生成候选。
候选 revision 严格递增。
```

- [ ] **Step 4: 运行测试并确认通过**

Run: Step 2 命令。

Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add ios/LiveTranslate/Shared/CaptionSegmenter.swift ios/LiveTranslate/LiveTranslateTests/CaptionSegmenterTests.swift
git commit -m "feat: segment progressive captions for translation"
```

---

### Task 4: 实现主 App 模型准备、语言选择和广播入口

**Files:**
- Modify: `ios/LiveTranslate/LiveTranslate/LiveTranslateApp.swift`
- Modify: `ios/LiveTranslate/LiveTranslate/ContentView.swift`
- Create: `ios/LiveTranslate/LiveTranslate/AppViewModel.swift`
- Create: `ios/LiveTranslate/LiveTranslate/ModelPreparationService.swift`
- Create: `ios/LiveTranslate/LiveTranslate/BroadcastPickerView.swift`
- Create: `ios/LiveTranslate/LiveTranslateTests/AppViewModelTests.swift`

**Interfaces:**
- Produces: `AppViewModel` 与可注入的 `ModelPreparing` 协议。
- Produces: `ModelPreparationService.speechStatus(for:)` 和 `installSpeechModel(for:)`。
- Produces: `BroadcastPickerView`，固定广播扩展标识。

- [ ] **Step 1: 写 ViewModel 失败测试**

```swift
func testBroadcastRequiresPreparedModels() async {
    let service = FakeModelPreparationService(status: .needsDownload)
    let viewModel = await AppViewModel(modelService: service, store: InMemoryCaptionStore())
    await viewModel.refreshModelStatus()
    let canStart = await viewModel.canStartBroadcast
    XCTAssertFalse(canStart)
}
```

- [ ] **Step 2: 运行测试并确认失败**

```bash
xcodebuild test -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslate \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -only-testing:LiveTranslateTests/AppViewModelTests
```

Expected: FAIL，ViewModel 与服务协议未定义。

- [ ] **Step 3: 实现 Speech 模型准备**

```swift
let transcriber = SpeechTranscriber(locale: source.speechLocale, preset: .progressiveTranscription)
let modules: [any SpeechModule] = [transcriber]
let status = await AssetInventory.status(forModules: modules)
let request = try await AssetInventory.assetInstallationRequest(supporting: modules)
try await request?.downloadAndInstall()
```

映射 `.unsupported/.supported/.downloading/.installed` 为 `ModelResourceStatus`。

- [ ] **Step 4: 使用 SwiftUI Translation task 准备翻译模型**

```swift
@State private var translationConfiguration: TranslationSession.Configuration?

.translationTask(translationConfiguration) { session in
    try await session.prepareTranslation()
    await viewModel.markTranslationReady()
}
```

Configuration 的 source 取用户选择，target 固定为 `zh-Hans`。

- [ ] **Step 5: 实现最小界面和广播按钮**

界面包含语言 Picker、两个模型状态、下载按钮、字幕预览和广播选择器。广播选择器设置：

```swift
picker.preferredExtension = "com.xueqianzheng.LiveTranslate.BroadcastExtension"
picker.showsMicrophoneButton = false
```

- [ ] **Step 6: 运行完整测试**

```bash
xcodebuild test -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslate \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'
```

Expected: PASS。

- [ ] **Step 7: Commit**

```bash
git add ios/LiveTranslate/LiveTranslate ios/LiveTranslate/LiveTranslateTests
git commit -m "feat: prepare local speech and translation models"
```

---

### Task 5: 在广播扩展接收 App 音频并运行 SpeechAnalyzer

**Files:**
- Modify: `ios/LiveTranslate/LiveTranslateBroadcast/SampleHandler.swift`
- Create: `ios/LiveTranslate/Shared/AudioPCMConverter.swift`
- Create: `ios/LiveTranslate/LiveTranslateBroadcast/SpeechPipeline.swift`
- Create: `ios/LiveTranslate/LiveTranslateTests/AudioPCMConverterTests.swift`

**Interfaces:**
- Produces: `AudioPCMConverter.convert(_:) -> AVAudioPCMBuffer`。
- Produces: `SpeechPipeline.start(source:onText:)`, `append(_:)`, `finish()`。
- Consumes: `SourceLanguage`。

- [ ] **Step 1: 写有效音量检测失败测试**

```swift
XCTAssertFalse(AudioPCMConverter.hasAudibleEnergy(silentBuffer, threshold: 0.001))
XCTAssertTrue(AudioPCMConverter.hasAudibleEnergy(toneBuffer, threshold: 0.001))
```

- [ ] **Step 2: 运行并确认失败**

```bash
xcodebuild test -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslate \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -only-testing:LiveTranslateTests/AudioPCMConverterTests
```

Expected: FAIL，转换器未定义。

- [ ] **Step 3: 实现音频转换**

使用 `CMSampleBufferGetFormatDescription`、`CMAudioFormatDescriptionGetStreamBasicDescription`、`CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer` 读取 PCM，并用 `AVAudioConverter` 转为：

```swift
await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
```

缺失格式、非 PCM、空 BufferList 或转换失败都抛出具名错误，不强制解包。

- [ ] **Step 4: 实现 SpeechPipeline**

```swift
let transcriber = SpeechTranscriber(locale: source.speechLocale, preset: .progressiveTranscription)
let analyzer = SpeechAnalyzer(modules: [transcriber])
```

通过 `AsyncStream<AnalyzerInput>` 输入 PCM，并消费：

```swift
for try await result in transcriber.results {
    await onText(String(result.text.characters))
}
```

`finish()` 结束输入、finalize analyzer 并取消结果 Task。

- [ ] **Step 5: 接入 SampleHandler**

`broadcastStarted` 读取共享语言并启动 pipeline；`processSampleBuffer` 只处理 `.audioApp`；连续 3 秒静音时写入提示状态；`broadcastFinished` 释放 pipeline 并写 `.stopped`。

- [ ] **Step 6: 运行测试和扩展构建**

```bash
xcodebuild test -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslate \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'
xcodebuild -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslateBroadcast \
  -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
```

Expected: 测试 PASS，扩展编译成功。

- [ ] **Step 7: Commit**

```bash
git add ios/LiveTranslate/Shared/AudioPCMConverter.swift ios/LiveTranslate/LiveTranslateBroadcast ios/LiveTranslate/LiveTranslateTests
git commit -m "feat: transcribe ReplayKit app audio on device"
```

---

### Task 6: 接入本地翻译并保护字幕版本顺序

**Files:**
- Create: `ios/LiveTranslate/LiveTranslateBroadcast/AppleTranslationClient.swift`
- Create: `ios/LiveTranslate/Shared/BroadcastCaptionCoordinator.swift`
- Create: `ios/LiveTranslate/LiveTranslateTests/BroadcastCaptionCoordinatorTests.swift`
- Modify: `ios/LiveTranslate/LiveTranslateBroadcast/SampleHandler.swift`

**Interfaces:**
- Produces: `CaptionTranslating.translate(_:)`。
- Produces: `AppleTranslationClient`。
- Produces: `BroadcastCaptionCoordinator.receiveRecognizedText(_:isFinal:timestampMilliseconds:)`。
- Consumes: `CaptionSegmenter` 与 `CaptionStoreProtocol`。

- [ ] **Step 1: 写旧翻译结果失败测试**

```swift
func testStaleTranslationCannotOverwriteNewerCaption() async throws {
    let translator = DelayedFakeTranslator(delays: ["first": 200_000_000, "second": 10_000_000])
    let store = InMemoryCaptionStore()
    let coordinator = BroadcastCaptionCoordinator(translator: translator, store: store)
    await coordinator.receiveRecognizedText("first", isFinal: true, timestampMilliseconds: 0)
    await coordinator.receiveRecognizedText("second", isFinal: true, timestampMilliseconds: 1)
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertEqual(try store.load()?.sourceText, "second")
    XCTAssertEqual(try store.load()?.translatedText, "译文:second")
}
```

- [ ] **Step 2: 运行并确认失败**

```bash
xcodebuild test -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslate \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -only-testing:LiveTranslateTests/BroadcastCaptionCoordinatorTests
```

Expected: FAIL，协调器与翻译协议未定义。

- [ ] **Step 3: 实现 Apple Translation 客户端**

```swift
if #available(iOS 26.4, *) {
    session = TranslationSession(
        installedSource: source.translationSource,
        target: SourceLanguage.translationTarget,
        preferredStrategy: .lowLatency
    )
} else {
    session = TranslationSession(
        installedSource: source.translationSource,
        target: SourceLanguage.translationTarget
    )
}
```

`translate(_:)` 返回 `try await session.translate(text).targetText`。语言资源未安装时写入明确错误，不在扩展内弹下载 UI。

- [ ] **Step 4: 实现 revision 保护**

每次原文变化先保存原文快照。翻译完成时，只有候选 revision 等于当前最新 revision 才保存译文；旧任务结果丢弃。

- [ ] **Step 5: 连接 SpeechPipeline**

Speech 结果以 partial 输入并按 800ms 节流；广播结束前把最后文本以 final 再提交一次。

- [ ] **Step 6: 运行完整测试和扩展构建**

Run: Task 5 Step 6 命令。

Expected: PASS。

- [ ] **Step 7: Commit**

```bash
git add ios/LiveTranslate/Shared/BroadcastCaptionCoordinator.swift ios/LiveTranslate/LiveTranslateBroadcast ios/LiveTranslate/LiveTranslateTests
git commit -m "feat: translate live captions to Simplified Chinese"
```

---

### Task 7: 实现字幕预览和最小画中画渲染

**Files:**
- Create: `ios/LiveTranslate/LiveTranslate/CaptionFrameRenderer.swift`
- Create: `ios/LiveTranslate/LiveTranslate/CaptionPiPController.swift`
- Create: `ios/LiveTranslate/LiveTranslateTests/CaptionFrameRendererTests.swift`
- Modify: `ios/LiveTranslate/LiveTranslate/AppViewModel.swift`
- Modify: `ios/LiveTranslate/LiveTranslate/ContentView.swift`

**Interfaces:**
- Produces: `CaptionFrameRenderer.makePixelBuffer(snapshot:size:)`。
- Produces: `CaptionPiPController.start()`, `stop()`, `render(_:)`。
- Consumes: `CaptionSnapshot` 与 `CaptionStoreProtocol`。

- [ ] **Step 1: 写像素缓冲失败测试**

```swift
func testRendererCreatesRequestedPixelBuffer() throws {
    let snapshot = CaptionSnapshot(
        revision: 1, sourceText: "Hello", translatedText: "你好",
        phase: .translating, errorMessage: nil, updatedAt: .now
    )
    let buffer = try CaptionFrameRenderer().makePixelBuffer(
        snapshot: snapshot,
        size: CGSize(width: 960, height: 320)
    )
    XCTAssertEqual(CVPixelBufferGetWidth(buffer), 960)
    XCTAssertEqual(CVPixelBufferGetHeight(buffer), 320)
}
```

- [ ] **Step 2: 运行并确认失败**

```bash
xcodebuild test -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslate \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -only-testing:LiveTranslateTests/CaptionFrameRendererTests
```

Expected: FAIL，渲染器未定义。

- [ ] **Step 3: 实现帧渲染**

创建 BGRA `CVPixelBuffer`，用 Core Graphics 绘制半透明深色背景、上方原文、下方中文译文；错误状态使用高对比提示色，不绘制交互按钮。

- [ ] **Step 4: 实现 PiP Controller**

```swift
let source = AVPictureInPictureController.ContentSource(
    sampleBufferDisplayLayer: displayLayer,
    playbackDelegate: self
)
pictureInPictureController = AVPictureInPictureController(contentSource: source)
```

实时内容返回无限播放范围；使用 `CMSampleBufferCreateReadyWithImageBuffer` 将帧提交给 `AVSampleBufferDisplayLayer`；只在 revision 增长时重绘。

- [ ] **Step 5: 观察共享字幕**

AppViewModel 启动可取消 Task，每 250ms 读取 `CaptionStore`，同时更新 SwiftUI 预览和 PiP；停止 PiP 或释放 ViewModel 时取消 Task。

- [ ] **Step 6: 运行完整测试**

```bash
xcodebuild test -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslate \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'
```

Expected: PASS。

- [ ] **Step 7: Commit**

```bash
git add ios/LiveTranslate/LiveTranslate ios/LiveTranslate/LiveTranslateTests
git commit -m "feat: render translated captions in Picture in Picture"
```

---

### Task 8: 完成构建验证、真机安装和运行说明

**Files:**
- Create: `README.md`
- Modify only when verified build errors require it: Tasks 1-7 created files。

**Interfaces:**
- Produces: 可由本地 Xcode 打开、签名和安装的工程。
- Produces: 真机操作与已知限制说明。

- [ ] **Step 1: 运行完整自动检查**

```bash
xcodebuild test -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslate \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'
xcodebuild -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslate \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: 测试与无签名 iPhone 编译均成功。

- [ ] **Step 2: 写 README 真机步骤**

README 必须覆盖：打开工程、给两个 Target 选择相同 Team、确认 App Group、连接并信任真机、下载语言模型、启动 PiP、启动广播、在“文件”或 Safari 播放无 DRM 内容，以及 DRM/电话/会议音频限制。

- [ ] **Step 3: 执行真机验收**

英语和日语各使用一个无 DRM 本地视频，记录首条原文延迟、首条译文延迟、PiP 更新和 15 分钟扩展存活情况。若扩展被系统终止，保留 Xcode 控制台的 jetsam 或内存证据，不静默更换架构。

- [ ] **Step 4: 检查工作区**

```bash
git status --short
git diff --check
git log --oneline --decorate -8
```

Expected: 无未解释生成文件或格式错误，每个任务有独立提交。

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: add LiveTranslate device test guide"
```

---

## Completion Gate

```text
所有 XCTest 在 iPhone 17 Pro / iOS 26.5 模拟器通过。
App 和 Broadcast Extension 的 generic iOS 无签名构建通过。
主 App 与扩展使用相同 App Group。
真机能够启动广播并收到至少一种非 DRM 来源的 AudioApp 样本。
英语和日语各完成一次端侧识别与简体中文翻译。
PiP 在切换到来源 App 后继续显示字幕。
没有音频上传、第三方依赖、分析或遥测。
README 记录真机操作和已知限制。
```
