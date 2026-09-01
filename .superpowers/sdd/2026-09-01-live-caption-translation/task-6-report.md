# Task 6 Report: 端侧翻译与 revision 顺序保护

## 实现

- 新增 `CaptionTranslating` 与独立的 `BroadcastCaptionCoordinator`，把 Task 5 的同名 coordinator 从 `BroadcastAudioSupport.swift` 迁出，保留 `begin`、`markRecognizing`、`updateText`、`reportSilence`、`clearSilenceWarning`、`fail`、`stop` 行为。
- coordinator 使用同一 `NSLock` 串行化所有 `CaptionStoreProtocol` 读写；原文变化先保存，翻译候选通过 generation 绑定当前原文，迟到成功或失败均不能覆盖新 revision 或终态。
- 翻译任务均为内部捕获错误的 `Task<Void, Never>`，由 coordinator 跟踪；`flushPendingTranslations()` 等待当前候选，取消并观察过时候选，并在当前翻译失败时抛出明确错误。
- 新增 actor `AppleTranslationClient`，仅使用系统 `Translation`：`installedSource` 初始化、固定 `zh-Hans`，iOS 26.4+ 使用 `.lowLatency`，更早版本使用默认策略；未安装、语言对不支持及 translate 失败均映射为明确中文错误，不展示下载 UI。
- `SampleHandler` 将 SpeechPipeline 文本作为 partial，以 `ContinuousClock` 单调时间换算毫秒输入 coordinator；结束时重提最后非空文本为 final，await flush 后才写 `.stopped`。翻译错误通过 coordinator 的 `onFailure` 回调进入 `failBroadcast`。
- Task 5 的有界音频队列、silence monitor、SpeechPipeline 清理与终态保护未改语义。

## RED / GREEN

### RED

命令：

```bash
xcodebuild test -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslate \
  -destination 'platform=iOS Simulator,id=7EC5843E-3F68-4EDF-874A-B87EFE0106B9' \
  -only-testing:LiveTranslateTests/BroadcastCaptionCoordinatorTests \
  -parallel-testing-enabled NO
```

首次结果：exit 65，符合预期；错误为 `Cannot find type 'CaptionTranslating' in scope` 与 `Extra argument 'translator' in call`。补齐其余契约测试后仍以缺失协议失败。

### GREEN

- `BroadcastCaptionCoordinatorTests`：6 tests，0 failures。
- `BroadcastAudioSupportTests`：8 tests，0 failures，确认 Task 5 回归通过。
- 完整 `LiveTranslateTests`：33 tests，0 failures；最终 fresh run exit 0。
- iphoneos 构建：

```bash
xcodebuild build -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslateBroadcast \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO
```

结果：`BUILD SUCCEEDED`，exit 0。修复本任务引入的 `withLock` 返回值 warning 后再次构建成功。

## 改动文件

- `ios/LiveTranslate/Shared/BroadcastCaptionCoordinator.swift`（新增）
- `ios/LiveTranslate/Shared/BroadcastAudioSupport.swift`
- `ios/LiveTranslate/LiveTranslateBroadcast/AppleTranslationClient.swift`（新增）
- `ios/LiveTranslate/LiveTranslateBroadcast/SampleHandler.swift`
- `ios/LiveTranslate/LiveTranslateTests/BroadcastCaptionCoordinatorTests.swift`（新增）

## 自查

- 覆盖原文先保存、旧翻译丢弃、当前翻译失败进入 `.failed`、迟到任务不回退、final 与最后 partial 同文本产生候选、flush 在 stop 前完成、翻译不清除静音警告。
- 所有测试使用可控 fake translator，不依赖真实系统翻译模型。
- `project.pbxproj` 仅保留任务开始前已有的 Shared group 排序差异，未纳入本任务改动或提交。
- `git diff --check` 通过；提交前另对 staged diff 执行检查。

## 疑虑

- Simulator 输出包含系统级 Translation 不支持提示及 iOS 26.5 runtime 的重复 Accessibility class 提示；测试仍全部通过，真机 SDK 构建成功。
- 无法在自动化测试中验证真实设备已安装翻译资源后的模型输出；客户端通过 `LanguageAvailability` 和 `TranslationError.notInstalled` 明确处理未安装状态。

## Fix Round 1：latest-work 生命周期与 Translation 串行边界

### 根因与修复

- 原文更新使用通用 `write` 继承旧译文，导致新原文出现后仍短暂显示上一条翻译；现在原文真正变化时显式写入空译文，同时保留 `.recognizing` 与已有静音 warning。
- coordinator 原先按 generation 保存多个 Task，只在 flush 时处理旧任务；generation 前进、`fail`、`stop` 或内部存储错误现在都会在锁内取消并解除当前 pending translation，迟到成功或失败只能完成自身，不能覆盖新 generation 或外部终态。
- 翻译 Task 在 `translator.translate` 的 await 期间不再强持有 coordinator；完成后按 generation 自移除。`flushPendingTranslations()` 只在锁外等待调用时的 current work，终态不再等待不响应 cancellation 的旧任务。
- `CaptionSegmenter` 记录上一候选是否为 final；同文本 partial 已产生候选后，final 仍会生成新的候选并替换 partial，而重复 final 继续被忽略。
- 新增 `AsyncSerialExecutor`。调用方 Task 被取消也不会释放队列，只有当前异步 operation 实际返回后下一项才会开始；`AppleTranslationClient` 将资源检查与 `TranslationSession.translate` 整体放入该串行边界，避免 actor 在框架 await 期间可重入而重叠使用同一 session。
- 测试 fake 改为 request-ID 驱动并记录 cancellation/return；检查与 waiter 登记在同一把锁内完成，避免测试自身的 check-then-wait 竞态。

### RED

Coordinator 行为 RED 使用全新 DerivedData：

```bash
xcodebuild test -quiet \
  -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslate \
  -destination 'platform=iOS Simulator,id=7EC5843E-3F68-4EDF-874A-B87EFE0106B9' \
  -derivedDataPath /tmp/LiveTranslateTask6Red-01a05bb0 \
  -only-testing:LiveTranslateTests/BroadcastCaptionCoordinatorTests \
  -parallel-testing-enabled NO
```

结果：9 tests 中 5 failures，均为预期缺失行为：旧译文未清空、旧 generation 未取消、same-text final 只有 1 个请求、`stop` 未取消 pending、`fail` 未取消 pending。

Translation 串行边界 RED：

```bash
xcodebuild test -quiet \
  -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslate \
  -destination 'platform=iOS Simulator,id=7EC5843E-3F68-4EDF-874A-B87EFE0106B9' \
  -derivedDataPath /tmp/LiveTranslateTask6SerialRed-01a05bb0 \
  -only-testing:LiveTranslateTests/AsyncSerialExecutorTests \
  -parallel-testing-enabled NO
```

结果：exit 65，唯一生产缺口为 `Cannot find 'AsyncSerialExecutor' in scope`。

### GREEN / 最终验证

先编译全部测试源码：

```bash
xcodebuild build-for-testing -quiet \
  -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslate \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/LiveTranslateTask6BuildForTesting2-01a05bb0
```

结果：exit 0。

随后基于同一构建产物运行：

```bash
xcodebuild test-without-building -quiet \
  -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslate \
  -destination 'platform=iOS Simulator,id=7EC5843E-3F68-4EDF-874A-B87EFE0106B9' \
  -derivedDataPath /tmp/LiveTranslateTask6BuildForTesting2-01a05bb0 \
  -only-testing:LiveTranslateTests/AsyncSerialExecutorTests \
  -only-testing:LiveTranslateTests/BroadcastCaptionCoordinatorTests \
  -parallel-testing-enabled NO
```

结果：10 tests，0 failures。

```bash
xcodebuild test-without-building -quiet \
  -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslate \
  -destination 'platform=iOS Simulator,id=7EC5843E-3F68-4EDF-874A-B87EFE0106B9' \
  -derivedDataPath /tmp/LiveTranslateTask6BuildForTesting2-01a05bb0 \
  -only-testing:LiveTranslateTests/BroadcastAudioSupportTests \
  -parallel-testing-enabled NO
```

结果：8 tests，0 failures。

```bash
xcodebuild test-without-building -quiet \
  -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslate \
  -destination 'platform=iOS Simulator,id=7EC5843E-3F68-4EDF-874A-B87EFE0106B9' \
  -derivedDataPath /tmp/LiveTranslateTask6BuildForTesting2-01a05bb0 \
  -only-testing:LiveTranslateTests \
  -parallel-testing-enabled NO
```

结果：37 tests，0 failures。

iphoneos Broadcast 构建：

```bash
xcodebuild build -quiet \
  -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslateBroadcast \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/LiveTranslateTask6DeviceBuild4-01a05bb0 \
  CODE_SIGNING_ALLOWED=NO
```

结果：exit 0。

### 兼容性与提交边界

- 尝试普通 `import Translation` 时，Swift 6 报 `sending 'self.session' risks causing data races`；保留 `@preconcurrency import Translation` 以兼容当前框架注解，运行时互斥由 `AsyncSerialExecutor` 保证。
- 备用 simulator 会因系统 Translation “deviceSupportsTranslation: NO” 用户操作 UI 阻塞 test host；原 iPhone 17 Pro simulator 的相同测试全部通过。
- `project.pbxproj` 的 Team/Shared group 差异及 AppIcon 的 `Contents.json`、`AppIcon.png` 均为用户改动，本轮未修改、未暂存、未提交。

## Fix Round 2：取消传播与强终态回归

### RED

先只修改测试，并使用全新 DerivedData 运行 executor 与 coordinator 聚焦测试：

```bash
xcodebuild test -quiet \
  -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslate \
  -destination 'platform=iOS Simulator,id=7EC5843E-3F68-4EDF-874A-B87EFE0106B9' \
  -derivedDataPath /tmp/LiveTranslateTask6Round2Red \
  -only-testing:LiveTranslateTests/AsyncSerialExecutorTests \
  -only-testing:LiveTranslateTests/BroadcastCaptionCoordinatorTests \
  -parallel-testing-enabled NO
```

结果：exit 65；12 tests 中 10 passed、2 failed。失败均为预期行为缺口：

- cancelled queued operation 未抛 `CancellationError`，并实际进入 operation。
- 已启动 operation 在 caller 取消后观察到 `Task.isCancelled == false`。

### 修复

- `AsyncSerialExecutor` 使用 task cancellation handler 将 caller 取消转发给内部 `operationTask`。
- 内部任务等待 predecessor 真实完成后执行 `Task.checkCancellation()`，因此已取消的排队 operation 不会开始。
- `tail` 继续等待 `operationTask.value`；若 operation 已启动且忽略取消，后继仍只能在它真实返回后开始，同一 `TranslationSession` 不会重叠。
- stale-success 测试改用 `ControlledTranslator(honorsCancellation: false)`，显式让旧 generation 在新 generation 成功后迟到成功；新增当前 generation 失败的 `.failed`、错误传播与迟到成功不可恢复终态测试。

### GREEN / 最终验证

使用 fresh DerivedData 重跑相同聚焦范围：

```bash
xcodebuild test -quiet \
  -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslate \
  -destination 'platform=iOS Simulator,id=7EC5843E-3F68-4EDF-874A-B87EFE0106B9' \
  -derivedDataPath /tmp/LiveTranslateTask6Round2Green \
  -only-testing:LiveTranslateTests/AsyncSerialExecutorTests \
  -only-testing:LiveTranslateTests/BroadcastCaptionCoordinatorTests \
  -parallel-testing-enabled NO
```

结果：12 tests，0 failures。

随后使用 `/tmp/LiveTranslateTask6Round2Verify` 串行执行 `build-for-testing` 与 `test-without-building`：

- `build-for-testing`：exit 0。
- `BroadcastAudioSupportTests`：8 tests，0 failures。
- 完整 `LiveTranslateTests`：39 tests，0 failures。

iphoneos Broadcast 无签名构建：

```bash
xcodebuild build -quiet \
  -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslateBroadcast \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/LiveTranslateTask6Round2Device \
  CODE_SIGNING_ALLOWED=NO
```

结果：exit 0。

本轮未修改 coordinator 生产代码；Round 1 的 generation/terminal guard 已满足恢复后的强 stale-success 与失败终态契约。本轮仍未修改或暂存 Team/AppIcon 用户改动及 `BroadcastPickerView.swift`。
