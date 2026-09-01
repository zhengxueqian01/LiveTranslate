# LiveTranslate 真机 PoC

LiveTranslate 是一个仅在设备端运行的 iOS 26 PoC：用户手动选择英语或日语来源音频，系统广播扩展尝试捕获允许录制的其他 App 音频，生成原文字幕并翻译为简体中文，再通过画中画（PiP）显示最近的双语字幕。

此项目不上传、不保存原始音频，不使用服务器、第三方 SDK、分析或遥测。语言资源下载由苹果系统完成。

## 运行前准备

需要：Xcode 26.6、运行 iOS 26 的自有 iPhone、可用于本机签名的 Apple Team，以及一个无 DRM 的英语或日语媒体文件或允许录屏的网页媒体。完整的 ReplayKit、端侧 Speech、Translation 和 PiP 链路必须在真机验证，不能仅以模拟器结果代替。

1. 在 Xcode 打开 `ios/LiveTranslate/LiveTranslate.xcodeproj`。
2. 依次选择 `LiveTranslate` 与 `LiveTranslateBroadcast` Target，在 **Signing & Capabilities** 中启用 **Automatically manage signing**，并为两者选择同一个 Team。
3. 在两个 Target 的 **App Groups** 中确认都包含且只使用 `group.com.xueqianzheng.LiveTranslate`。不要为 App 与扩展分别创建不同的 App Group，否则无法共享字幕和语言选择。
4. 确认主 App 的 Bundle Identifier 为 `com.xueqianzheng.LiveTranslate`，广播扩展为 `com.xueqianzheng.LiveTranslate.BroadcastExtension`；若本机 Team 无法注册这些标识符，请在同一 Team 下统一改为可用的唯一标识符，并同步更新扩展配置与 App Group。
5. 用数据线连接 iPhone，在手机上选择“信任此电脑”；在 Xcode 的运行目标中选择该设备。若系统要求，请在手机的“设置”中信任对应开发者证书。
6. 先运行主 App 一次，并按系统提示完成签名信任和语言资源准备；本 PoC 不请求麦克风权限，因为它只处理系统广播提供的 App 音频。

## 准备语言模型

1. 打开 App，在“输入语言”选择 **英语** 或 **日语**；目标语言固定为“简体中文”。
2. 在“本地模型”检查“语音识别”和“翻译”状态。
3. 若语音识别显示“需要下载”，点击“下载语音模型”，等待状态变为“已安装”。
4. 保持 App 在前台，等待翻译显示“已准备”。翻译语言资源由系统的 Translation 框架准备；若准备失败，检查设备系统版本、可用存储和系统语言资源后重试。
5. 只在语音识别为“已安装”且翻译为“已准备”时启动系统广播。

## 启动字幕与系统广播

1. 在 App 的“字幕预览”中点“打开画中画字幕”。首次没有可渲染字幕时，界面会提示正在等待字幕画面；收到字幕后才可能启动 PiP。
2. 点击“系统广播”区域右侧的系统按钮。在 iOS 广播面板中选择 **LiveTranslateBroadcast**，确认麦克风开关保持关闭，然后点“开始直播”。这是由 iOS 显式授权的广播；停止也应通过系统广播控件完成。
3. 切换到“文件”App 播放本地无 DRM 视频，或在 Safari 播放允许录屏的网页媒体。先确认来源实际有声音，再观察 App 内“字幕预览”和 PiP 是否更新。
4. 回到 LiveTranslate 检查错误提示。连续约 3 秒没有有效 App 音频时，扩展会提示来源可能静音、受 DRM 保护或不允许捕获。
5. 测试结束时，在系统广播控件中停止直播，并关闭 PiP。

## 音频输出与来源边界

- 分别用耳机和外放重复测试。ReplayKit 捕获的是系统允许提供给广播扩展的 `.audioApp` 样本；不要假设某一种输出路线一定可被捕获。
- 优先使用“文件”中的本地无 DRM 视频，或 Safari 中明确允许录屏的音视频页面。开始前可用 iOS 原生录屏能力确认来源是否允许录制。
- DRM 流媒体、受保护内容、系统电话、FaceTime、会议应用或第三方通话音频可能静音、不可捕获或被系统限制；本 PoC 不承诺支持这些来源。
- 扩展忽略麦克风和屏幕视频样本，因此不会把说话人的麦克风输入当作字幕来源。

## 真机验收记录（待执行）

以下项目尚未由本 README 声称为已通过，须在已签名 iOS 26 真机上逐项记录实际结果：

| 场景 | 需要记录 |
| --- | --- |
| 英语本地无 DRM 视频 | 是否收到 App 音频、首条原文延迟、首条简体中文译文延迟、暂停/恢复结果 |
| 日语本地无 DRM 视频 | 是否收到 App 音频、首条原文延迟、首条简体中文译文延迟、暂停/恢复结果 |
| PiP | 切换到来源 App 后是否仍显示并更新双语字幕；若失败，保留 Xcode 控制台错误 |
| 耳机与外放 | 两种输出路线各自是否收到 `.audioApp` 样本及字幕结果 |
| 15 分钟连续运行 | 是否持续存活、延迟变化、发热/功耗，以及是否出现扩展退出 |
| 扩展资源压力 | 若扩展被系统终止，保留 Xcode 控制台的 jetsam、内存警告或其他系统证据；不要静默替换架构 |

## 自动验证

以下命令固定使用指定模拟器，并关闭并行测试以避免测试间资源竞争。DerivedData 放在 `/tmp`，不会写入工作树：

```bash
xcodebuild test -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslate \
  -destination 'id=7EC5843E-3F68-4EDF-874A-B87EFE0106B9' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/LiveTranslate-DerivedData

xcodebuild -project ios/LiveTranslate/LiveTranslate.xcodeproj \
  -scheme LiveTranslate \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath /tmp/LiveTranslate-DerivedData \
  build
```

自动测试只能覆盖共享状态、分句、转换与协调逻辑；语言资源准备、系统广播音频、英语/日语识别翻译、PiP 续显及 15 分钟稳定性仍以真机验收表为准。
