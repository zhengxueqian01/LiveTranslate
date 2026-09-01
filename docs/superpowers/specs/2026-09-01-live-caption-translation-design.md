# iPhone 跨 App 实时字幕翻译 PoC 设计

日期：2026-09-01

## 1. 目标

构建一个可通过本地 Xcode 签名并安装到用户自有 iPhone 的真机 PoC。用户手动选择英语或日语作为音频语言，App 读取其他 App 当前播放的、允许被系统捕获的音频，在设备端生成原文字幕并翻译为简体中文，最后通过画中画窗口跨 App 显示双语字幕。

PoC 不设置产品侧时长限制，不依赖服务器、账号、API Key 或第三方推理服务，也不保存原始音频。

## 2. 成功标准

- 在 iOS 26 真机上能够完成安装、启动和本地签名运行。
- 用户能够手动选择英语或日语，目标语言固定为简体中文。
- 对“文件”、Safari 或其他允许录屏的非 DRM 音频来源，ReplayKit 广播扩展能够收到 `RPSampleBufferTypeAudioApp`。
- 首次使用时能够检查并准备苹果语音识别与翻译语言资源。
- 广播开始后，能够产生渐进式原文字幕和对应的简体中文译文。
- 用户切换到音频来源 App 后，画中画窗口继续显示最近的双语字幕。
- 正常音频输入下，首条可读原文目标延迟不超过 3 秒；稳定句产生后，译文目标延迟不超过 2 秒。
- 连续运行 15 分钟不因未处理异常或资源泄漏主动退出。更长时间的热量、功耗和扩展内存稳定性作为后续耐久测试处理。

## 3. 首版范围

### 包含

- iOS 26、Swift 6、SwiftUI。
- 英语语音识别并翻译为简体中文。
- 日语语音识别并翻译为简体中文。
- 用户手动选择输入语言。
- ReplayKit Broadcast Upload Extension。
- 苹果 Speech 框架的 `SpeechAnalyzer` 与 `SpeechTranscriber`。
- 苹果 Translation 框架的 `TranslationSession`。
- App Group 共享字幕与运行状态。
- `AVPictureInPictureController`、`AVSampleBufferDisplayLayer` 驱动的最小字幕画中画。
- 主界面的模型状态、开始、停止、错误提示和字幕预览。
- 核心状态管理、分句节流与共享存储的单元测试。

### 不包含

- 自动语种检测。
- 导入本地视频并离线生成整段字幕。
- 云端语音识别或云端翻译。
- 字幕历史、搜索、导出或 SRT 文件。
- 用户账号、订阅、分析统计或遥测。
- App Store 提交材料和正式产品视觉设计。
- 对 DRM 流媒体、系统电话或第三方通话音频的兼容承诺。

## 4. 方案选择

PoC 采用“广播扩展内完成识别与翻译，主 App 只接收字幕文本”的方案。

选择原因：ReplayKit 音频天然进入广播扩展。只跨进程共享低频文本和状态，可以避免第一版实现高频 PCM 跨进程传输，减少故障点并最快验证端侧框架能否在广播扩展环境中持续运行。

主要风险：Broadcast Upload Extension 的可用内存与执行资源比主 App 紧张。苹果语音和翻译模型在扩展内加载后，可能触发资源压力或系统终止。若真机测试确认该风险不可接受，第二阶段改为“扩展只采集 PCM，主 App 在 PiP 后台完成识别和翻译”，但该回退方案不进入本次 PoC 的首轮实现。

## 5. 组件结构

### 5.1 主 App Target

职责：

- 展示英语、日语输入语言选择。
- 固定显示简体中文目标语言。
- 检查语音识别资源状态并触发模型安装。
- 准备 Translation 语言资源，确保广播扩展启动前模型已经可用。
- 创建并启动字幕画中画。
- 通过 `RPSystemBroadcastPickerView` 让用户显式启动广播扩展。
- 读取 App Group 中的字幕快照和运行状态。
- 在 App 内预览和 PiP 画面中渲染双语字幕。

### 5.2 Broadcast Upload Extension

职责：

- 在 `RPBroadcastSampleHandler` 中接收 ReplayKit 样本。
- 只处理 `RPSampleBufferTypeAudioApp`；首版忽略屏幕视频和麦克风音频。
- 将 `CMSampleBuffer` 转换为 Speech 框架需要的 `AVAudioPCMBuffer`。
- 根据用户预先保存的输入语言创建 `SpeechTranscriber`。
- 将音频持续输入 `SpeechAnalyzer` 并消费渐进式识别结果。
- 对稳定文本进行分句和去重，避免每个字都触发翻译。
- 使用已安装语言资源创建 `TranslationSession`，翻译为简体中文。
- 将最新原文、译文、时间和状态写入 App Group。
- 广播结束或发生不可恢复错误时释放识别、翻译和缓冲资源。

### 5.3 Shared Core

主 App、广播扩展和测试 Target 共享的纯 Swift 逻辑：

- `LanguageSelection`：限定英语、日语输入与简体中文输出。
- `CaptionSnapshot`：原文、译文、更新时间、稳定性和错误状态。
- `CaptionSegmenter`：合并渐进式文本，识别稳定句并实施翻译节流。
- `CaptionStore`：封装 App Group 读写，不让业务层直接操作共享偏好。
- `SessionState`：模型准备、待机、广播、识别、翻译、失败和停止状态。

## 6. 数据流

1. 用户打开主 App，选择英语或日语。
2. 主 App 检查相应 Speech 模型和翻译语言资源。
3. 资源未安装时，用户在主 App 前台完成系统资源下载。
4. 主 App 保存语言选择，启动最小字幕 PiP。
5. 用户通过系统广播选择器启动本 App 的 Broadcast Upload Extension。
6. 扩展收到 `.audioApp` 样本，转换为 PCM 并送入 `SpeechAnalyzer`。
7. `SpeechTranscriber` 输出渐进式文本；`CaptionSegmenter` 更新原文字幕。
8. 当文本稳定、出现语义停顿或达到节流条件时，扩展调用 `TranslationSession`。
9. 扩展将字幕快照写入 App Group。
10. 主 App 读取新快照，更新 App 内预览并生成新的 PiP 视频帧。

## 7. 识别与翻译策略

### 7.1 Speech

- 部署目标为 iOS 26，直接使用 `SpeechAnalyzer` 和 `SpeechTranscriber`。
- 使用渐进式转写支持实时原文显示。
- 使用 `AssetInventory` 检查目标语言模块是否支持、已安装或需要下载。
- 广播扩展不负责展示模型下载 UI；模型未准备好时立即写入明确错误并停止广播。

### 7.2 Translation

- 使用 `TranslationSession` 和系统已安装的语言包。
- iOS 26.4 及以后优先使用低延迟策略；较早的 iOS 26 版本使用默认策略。
- 不对每次渐进式变化立即翻译。
- 只有稳定句、检测到停顿，或距离上次翻译达到节流阈值时才提交。
- 新的稳定句使旧的过时翻译结果失效，避免译文回跳覆盖新字幕。

## 8. 画中画字幕

iOS 不提供普通 App 跨应用任意悬浮窗口，因此使用公开的画中画 API。

- 主 App 使用 `AVSampleBufferDisplayLayer` 作为 PiP 内容源。
- 字幕渲染器把原文和译文绘制到固定尺寸的 `CVPixelBuffer`。
- 每次字幕变化时生成新的 `CMSampleBuffer` 并提交给显示层。
- PiP 只呈现媒体字幕，不承载通用按钮或伪造系统界面。
- 字幕为空时显示等待音频、模型未就绪或来源可能受保护等简短状态。

## 9. App Group 与共享状态

- 主 App 与扩展通过同一个 App Group 容器共享配置和字幕快照。
- 首版共享内容体积很小，使用封装后的共享偏好存储即可。
- 写入采用完整快照替换，不暴露半写入状态。
- 快照包含递增版本号，主 App 只渲染比当前版本更新的数据。
- 不在共享容器写入原始 PCM 或视频帧。
- 签名 Team、Bundle Identifier 和 App Group Identifier 通过本地 Xcode Automatic Signing 配置，源码中不硬编码个人 Team 标识。

## 10. 状态与错误处理

用户可见错误至少覆盖：

- 当前设备或系统版本不支持所需 API。
- 所选输入语言不受 Speech 模型支持。
- Speech 模型尚未安装。
- Translation 语言资源尚未准备好。
- 广播启动失败或被用户停止。
- 收到广播但连续数秒没有有效 `.audioApp` 能量，提示来源可能静音、受 DRM 保护或不允许捕获。
- Speech 或 Translation 返回不可恢复错误。
- 广播扩展即将因资源压力无法继续时，尽可能写入最后错误状态并停止。

可恢复错误不让界面崩溃；用户能够停止当前会话、返回模型准备页并重新开始。

## 11. 隐私与权限

- 广播由用户通过 iOS 系统界面显式启动和停止。
- 不请求麦克风权限，因为首版不采集 `.audioMic`。
- 不保存、上传或分析音频。
- 不添加第三方 SDK、广告、分析、遥测或外部网络请求。
- 网络仅由苹果系统在用户准备语言资源时用于下载系统模型。

## 12. 测试策略

### 自动化测试

- `LanguageSelection` 只接受英语、日语输入和简体中文输出。
- `CaptionSegmenter` 正确处理重复 partial、文本增长、稳定结果和翻译节流。
- 旧翻译响应不会覆盖更新版本的字幕。
- `CaptionStore` 能够完整往返编码、版本递增和错误状态。
- 会话状态转换不允许从失败状态直接进入广播状态。

### 真机测试

ReplayKit、端侧 Speech、Translation 和 PiP 的完整行为不能只依赖模拟器验证，必须在用户已签名的 iOS 26 真机测试：

- “文件”App 播放本地无 DRM 英语视频。
- “文件”App 播放本地无 DRM 日语视频。
- Safari 播放允许录屏的英语或日语网页视频。
- 戴耳机和外放两种音频输出。
- 开始、暂停、切换来源 App 和停止广播。
- 来源无声音、模型缺失和 DRM 静音路径。
- 连续 15 分钟运行期间观察扩展退出、内存压力、发热和字幕延迟。

## 13. 实施顺序

1. 创建 Xcode 工程、主 App、Broadcast Upload Extension、共享 Core 和测试 Target。
2. 配置本地 Automatic Signing、App Group 和必要的后台画中画能力。
3. 先测试 `CaptionSegmenter`、`CaptionStore` 和状态机。
4. 实现模型状态检查和语言资源准备。
5. 实现 ReplayKit 音频接收和 PCM 转换。
6. 接入 SpeechAnalyzer 并完成原文字幕共享。
7. 接入 TranslationSession 并完成简体中文译文共享。
8. 实现 App 内预览和最小 PiP 字幕渲染。
9. 完成构建检查和真机安装说明。
10. 真机验证扩展资源稳定性；若扩展被系统终止，记录证据后转入主 App 处理架构。
