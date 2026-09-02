# LiveTranslate 动态语言与按需模型下载设计

日期：2026-09-02

## 1. 目标

将 LiveTranslate 从“英语或日语翻译为简体中文”扩展为当前 iPhone 与 iOS 实际支持的动态输入、输出语言。App 不预下载任何语言资源，也不在启动或切换语言时自动下载；只有用户明确点击“下载所需模型”后，才准备当前语言组合所需的语音识别和翻译资源。

本设计保留现有 ReplayKit 广播、端侧语音识别、端侧翻译、App Group 字幕共享和画中画字幕架构，不引入服务器、账号、第三方 SDK、遥测或外部网络请求。

## 2. 成功标准

- 输入语言列表动态来自 `SpeechTranscriber.supportedLocales`。
- 输出语言列表动态来自 `LanguageAvailability.supportedLanguages`。
- 语言名称使用系统本地化名称，并按当前系统语言排序。
- iOS 后续新增受支持语言时，App 不需要更新硬编码枚举即可显示。
- 用户可以分别选择输入语言和输出语言。
- App 能够检查具体输入、输出语言对是已安装、可下载还是不支持。
- App 启动、语言列表加载和语言切换均不会触发模型下载。
- 只有用户点击一个明确的“下载所需模型”按钮后，App 才下载当前组合缺少的资源。
- Speech 和 Translation 资源均准备完成后，系统广播按钮才可用。
- 广播扩展读取完整语言配置，不再固定输出简体中文。
- 不保存翻译历史，字幕数据不会随使用时间持续增长。

“支持全部语言”在本文中指当前系统框架和设备返回的全部受支持语言，不承诺覆盖所有人类语言，也不承诺任意两个语言之间都存在可用翻译组合。

## 3. 范围

### 包含

- 动态输入语言和输出语言目录。
- 带搜索功能的系统原生可滚动语言选择界面，避免长列表难以使用。
- 具体翻译语言对可用性检查。
- Speech 与 Translation 的安装状态检查。
- 单一“下载所需模型”按钮。
- App Group 中完整语言配置的保存、读取和旧配置迁移。
- 广播扩展对任意已准备语言组合的识别与翻译。
- 已保留 Speech Locale 的查看与释放。
- 翻译资源由系统管理的明确说明。
- 最新字幕快照的覆盖式保存与新广播开始时清理。

### 不包含

- 自动识别输入语言。
- 同时识别多种输入语言。
- 云端翻译或云端语音识别回退。
- 翻译历史、收藏、搜索、导出或字幕文件。
- App 内强制卸载 Translation 语言资源；公开 Translation API 不提供该能力。
- 承诺 Speech 资源释放后立即回收磁盘空间；最终回收由 iOS 管理。

## 4. 方案选择

采用“系统动态目录 + 具体语言对校验”方案。

- 输入目录由 Speech 框架决定，确保每个输入项都对应可创建的语音识别 Locale。
- 输出目录由 Translation 框架决定，确保输出项属于系统端侧翻译支持范围。
- 输入 Locale 需要映射为 Translation 使用的源 `Locale.Language`，然后调用 `LanguageAvailability.status(from:to:)` 验证具体语言对。
- 不使用自维护的完整语言表，避免随系统更新过时。
- 不强行让输入列表与 Translation 语言列表完全相同，因为 Speech 可能提供英语、中文等语言的不同地区或脚本 Locale。

## 5. 语言领域模型

### 5.1 SpeechLanguageOption

表示用户可选择的音频语言：

- `localeIdentifier`：Speech 使用的精确 Locale，例如 `en-US`、`ja-JP`。
- `translationLanguageIdentifier`：与该 Speech Locale 匹配的 Translation 源语言标识，例如 `en`、`ja`、`zh-Hans`。
- `displayName`：系统当前界面语言下的本地化名称。

输入选项的稳定身份是 `localeIdentifier`，不使用本地化显示文字作为存储键。

### 5.2 TranslationLanguageOption

表示用户可选择的目标语言：

- `languageIdentifier`：Translation 使用的 `Locale.Language` 标识。
- `displayName`：系统当前界面语言下的本地化名称。

目标选项的稳定身份是 `languageIdentifier`。

### 5.3 LanguagePairConfiguration

主 App 与广播扩展共享的完整、可编码配置：

- `schemaVersion`
- `sourceSpeechLocaleIdentifier`
- `sourceTranslationLanguageIdentifier`
- `targetTranslationLanguageIdentifier`

同时存储 Speech Locale 和 Translation 源语言，避免广播扩展自行重复推断并产生不同结果。配置使用 Codable 编码后一次性写入 App Group，读取方不会观察到半更新状态。

## 6. 动态语言目录

新增 `LanguageCatalog` 抽象，负责：

1. 异步读取 `SpeechTranscriber.supportedLocales`。
2. 异步读取 `LanguageAvailability.supportedLanguages`。
3. 为每个 Speech Locale 寻找系统支持的等价 Locale，并映射到 Translation 源语言。
4. 生成本地化显示名称。
5. 对标识去重并按当前系统 Locale 排序。

Speech Locale 到 Translation 源语言的映射优先保留语言、脚本信息；若带地区的标识不被 Translation 目录接受，则回退到语言与脚本，再回退到基础语言代码。无法映射到 Translation 支持源语言的 Speech Locale 不进入可翻译输入列表。

语言目录加载失败时，界面显示错误和“重新加载”操作。已有有效配置仍可展示，但必须重新验证资源状态后才能启动广播。

## 7. 选择与兼容性

- App 首次运行时优先选择系统当前语言对应的 Speech Locale；若不可用，则选择排序后的第一个输入语言。
- 默认输出语言优先选择简体中文；若系统不支持，则选择系统当前语言或排序后的第一个目标语言。
- 用户改变输入或输出后，立即取消或忽略旧组合的异步状态结果，并检查新组合。
- `LanguageAvailability.status(from:to:)` 返回 `.unsupported` 时，显示“不支持此语言对”，禁止下载和广播。
- 返回 `.supported` 时，表示语言对可用但需要准备资源。
- 返回 `.installed` 时，表示翻译资源已经安装。
- 输入与输出是同一种 Translation 语言时，不创建或下载翻译会话；广播扩展将识别文本直接作为译文。Speech 模型仍需安装。

## 8. 模型状态与下载流程

### 8.1 状态模型

界面分别跟踪：

- Speech：检查中、不支持、需要下载、下载中、已安装、下载失败。
- Translation：检查中、不支持、需要下载、下载中、已安装、下载失败、不需要翻译。

广播可用条件为：

- App Group 可用；
- 当前配置有效；
- Speech 状态为已安装；
- Translation 状态为已安装或不需要翻译；
- 当前没有阻断性错误。

### 8.2 明确的用户触发

App 启动和语言切换只调用状态查询，不构造会请求下载的 Translation 配置，也不调用 `prepareTranslation()`。

当当前组合至少缺少一类可下载资源时，显示“下载所需模型”按钮，并列出将准备的项目。用户点击后：

1. 固定本次下载对应的语言配置，避免选择变化污染结果。
2. 下载缺少的 Speech 资源。
3. 通过前台 `translationTask` 获得对应 `TranslationSession`，仅在本次用户请求中调用 `prepareTranslation()`。
4. 下载完成后重新查询两类状态，不以调用成功直接推断最终状态。
5. 只有当前选择仍与本次配置一致时，才更新当前界面的可用状态。

Speech 和 Translation 可按实现安全性顺序执行；首版优先串行执行以提供明确状态和错误归因。某一资源已经安装时跳过该步骤。

### 8.3 下载错误

- 用户取消、网络中断、空间不足或系统拒绝时，保留可重试状态并展示系统错误说明。
- 部分资源下载成功、另一部分失败时，保留已成功资源的真实状态，下次只下载缺少部分。
- 不支持的语言组合不会进入下载流程。
- App 离开前台导致 Translation 准备中断时，不在后台继续伪装下载状态；返回 App 后重新检查。

## 9. App Group 配置与迁移

使用新的 `LanguageConfigurationStore` 替换只保存输入枚举的 `SourceLanguageStore`。

迁移规则：

- 新配置存在时直接读取。
- 新配置不存在但旧键为 `en-US` 时，迁移为 Speech `en-US`、Translation 源 `en`、目标 `zh-Hans`。
- 新配置不存在但旧键为 `ja-JP` 时，迁移为 Speech `ja-JP`、Translation 源 `ja`、目标 `zh-Hans`。
- 旧值无效或系统已不再支持时，不启动广播，由主 App 要求用户重新选择。
- 迁移成功后写入新配置；旧键可以保留一个版本周期，避免回滚旧构建时丢失选择。

广播扩展每次开始时读取一份完整配置快照，不在运行中的广播会话里响应语言切换。用户若要更换语言，需要停止当前广播、返回主 App 完成检查或下载，再重新开始。

## 10. 广播扩展

广播扩展启动时：

1. 读取 `LanguagePairConfiguration`。
2. 使用 `sourceSpeechLocaleIdentifier` 创建 Speech pipeline。
3. 若源、目标 Translation 语言相同，使用直通翻译器。
4. 否则使用 `installedSource:target:` 创建只使用已安装资源的 `TranslationSession`。
5. 再次调用可用性检查；资源缺失、语言对不支持或配置无效时立即结束广播并写入明确错误。

扩展永远不触发资源下载。Translation 客户端的错误信息包含当前源、目标语言的本地化名称或稳定标识，不再固定写“翻译为简体中文”。

## 11. 资源管理

### 11.1 Speech

App 可读取 `AssetInventory.reservedLocales`，在“管理语音模型”界面展示由 Speech 系统保留的 Locale。用户确认后调用 `AssetInventory.release(reservedLocale:)`。

“释放”表示 App 不再要求系统保留该 Locale，不承诺文件立即从磁盘消失。释放当前选择的 Speech Locale 后，重新查询状态并禁用广播，直到用户再次准备资源。

广播运行期间禁止释放当前使用的 Locale。

### 11.2 Translation

当前 Translation 公开 API 没有删除已下载语言资源的接口。App 只显示“翻译模型由系统管理，需要在 iPhone 的系统翻译语言管理界面删除”，不使用私有 API，也不伪造不能保证工作的设置深链。

Translation 资源由系统共享和管理，不写入 App bundle 或字幕存储，但多个已下载语言仍会占用设备存储空间。

## 12. 字幕与存储

- 不保存原始音频。
- 不保存字幕或翻译历史。
- `CaptionStore` 始终只保存一个最新 `CaptionSnapshot`，每次写入完整覆盖上一条。
- 新一轮广播开始时清除上一轮快照，避免显示旧内容。
- App Group 中只保留当前语言配置和最新字幕快照，存储量保持有界，不会随使用时间无限增长。
- 模型文件由 iOS 管理，不计入 App 自己不断累积的业务数据。

## 13. UI 设计

主界面包含：

- 输入语言选择行：显示本地化语言与地区名称。
- 输出语言选择行：显示本地化语言名称。
- 当前语言对支持状态。
- Speech 和 Translation 两项独立状态。
- 单一“下载所需模型”按钮，仅在需要且可下载时显示。
- 下载进度状态、失败说明和重试入口。
- “管理语音模型”入口和 Translation 系统管理说明。
- 只有当前资源就绪时可交互的系统广播按钮。

语言数量较多时，选择界面支持搜索。搜索匹配本地化名称和稳定语言标识，不在主表单内渲染超长 Picker 菜单。

## 14. 并发与状态一致性

- 每次语言选择变化生成新的请求标识或配置快照。
- 所有异步目录查询、状态查询和下载结果在写回 UI 前核对请求标识。
- 新选择使旧 Translation 配置失效，旧会话完成后不得把新组合标记为已安装。
- 同一时间只允许一个模型下载任务。
- 下载按钮在任务期间禁用；任务被系统或用户操作中断后，重新查询实际安装状态。
- App ViewModel 在 MainActor 更新可见状态，系统服务通过 Sendable 协议隔离，便于测试。

## 15. 错误处理

用户可见错误至少覆盖：

- 无法读取系统语言目录。
- Speech Locale 不受支持。
- Translation 源语言映射失败。
- 输入、输出语言对不受支持。
- Speech 或 Translation 资源尚未安装。
- 下载被取消、网络失败、空间不足或系统返回未知错误。
- App Group 配置缺失、损坏或版本不受支持。
- 广播启动时资源状态与主 App 检查结果不一致。
- 释放 Speech Locale 失败或仍被运行中的广播使用。

错误按来源分别保存，修复一个错误不会覆盖另一来源的阻断性错误。

## 16. 测试策略

### 16.1 单元测试

- 动态 Speech 和 Translation 目录转换、去重、本地化与排序。
- Speech Locale 到 Translation 源语言的脚本、地区和基础语言回退。
- 默认输入和输出选择。
- 支持、已安装、不支持和同语言直通的组合状态。
- 新 `LanguagePairConfiguration` 的 Codable 往返。
- `en-US`、`ja-JP` 旧键迁移和无效旧值处理。
- App 启动和语言切换不触发任何下载调用。
- 单按钮只下载缺少的资源。
- 部分成功、失败、取消、重试和选择变化后的过时结果抑制。
- 广播启用条件。
- 广播扩展使用配置中的任意目标语言。
- 同语言组合使用直通翻译器。
- Speech 资源释放和状态刷新。
- 新广播开始时字幕快照清理。
- `CaptionStore` 多次保存后仍只保留最新一条。

### 16.2 回归测试

- 现有 BroadcastCaptionCoordinator 的翻译排序和延迟策略。
- 长字幕自适应渲染。
- 画中画字幕方向、启动和持续更新。
- ReplayKit 广播音频队列与静音检测。

### 16.3 构建与真机验证

- 先运行最快的目标单元测试。
- 再执行无签名模拟器构建，验证主 App 与扩展编译。
- ReplayKit 音频、Speech 模型安装、Translation 资源准备和真实资源释放必须在已解锁 iPhone 上验证；模拟器只能覆盖界面、状态和部分 API 行为。
- 真机至少验证英语到中文、日语到中文，以及一个非中文目标语言组合。
- 验证未点击下载时无系统下载提示或模型准备行为。

## 17. 预期修改边界

预计修改或新增以下职责对应的文件，具体文件名在实施计划中以仓库实际结构为准：

- Shared：语言选项、完整语言配置、App Group 配置存储和迁移。
- 主 App：语言目录服务、模型准备服务、ViewModel、语言选择界面和资源管理界面。
- 广播扩展：Speech pipeline 参数、Translation client 和启动配置校验。
- Tests：语言目录、配置迁移、模型状态、下载触发、广播配置和缓存边界测试。

现有 App 图标、字幕延迟优化、长字幕渲染和其他未提交修改必须保留；本功能不进行无关重构。
