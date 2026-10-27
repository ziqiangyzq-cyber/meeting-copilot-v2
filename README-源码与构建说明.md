# Meeting Copilot 源码与构建

版本 2.0.2。产品目录中的 `Meeting Copilot.app` 与 `Meeting-Copilot-2.0.2.zip` 使用同一最终构建。

`continuous-client` 是 SwiftUI 客户端。其他同级目录是本地 Swift 包依赖，全部保留。`continuous-client/Sources/ClientRuntime/SpeechServices.swift` 实现独立转写 / 翻译设置、钥匙串引用、网络协议、同意发送与网络分段转写后端。复用 DesktopSessionController 的分段 PCM / 排空 / durable final 链路，网络引擎身份为 network-audio-api，不冒充本机 Qwen。

进入 continuous-client 构建：

```sh
swift build --configuration debug --scratch-path /tmp/meeting-copilot-build \
 --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
 --cache-path .cache -Xswiftc -module-cache-path -Xswiftc .module-cache
```

内部 executable 名为 `MeetingCopilot`，bundle identifier 为 `io.github.ziqiangyzq-cyber.meeting-copilot`，用户可见名称是 Meeting Copilot。首次启动会从旧 Foresight 与 pre-public v2 数据目录只复制迁移，不删除来源。

在仓库根目录执行 `python3 continuous-client/scripts/package-meeting.py --binary /tmp/meeting-copilot-build/debug/MeetingCopilot`。脚本会生成 `dist/Meeting Copilot.app` 与 `dist/Meeting-Copilot-2.0.2.zip`，不需要仓库外的私有产品目录。

App 图标源文件保存在 `assets/icon.png`，构建时使用 macOS `sips` 与 `iconutil` 生成完整 iconset（16–1024 px）和 `.icns`。

系统声音使用 macOS 14.2+ Core Audio process tap：`CATapDescription` → `AudioHardwareCreateProcessTap` → 私有 aggregate device → `AudioDeviceCreateIOProcIDWithBlock` → `AudioDeviceStart`。不使用 ScreenCaptureKit 实采，也不要求屏幕录制权限。`NSAudioCaptureUsageDescription` 用于“仅系统录音”授权说明。系统没有公开的 preflight API，因此 App 内“请求授权并检测”会真实创建一次最小 tap；只有收到第一帧才报告 running，8 秒内没有首帧会报 `noAudioFrames`。`SystemAudioInput.swift` 和 `DualAudioInput.swift` 都传入 `noDataTimeout: 8`。

检查可执行程序：NetworkServiceChecks、WorkspaceFeatureChecks、SettingsChecks、MeetingIntelligenceChecks、IntegratedClientChecks、IncrementalClientChecks、AudioInputChecks、DualAudioChecks、StorageEvolutionChecks、ProductMigrationChecks。后两种存储 / 设置测试分别需要 STORAGE_CHECK_ROOT、SETTINGS_CHECK_ROOT 指向新的独立临时目录。

NetworkServiceChecks 默认使用注入 transport 和临时钥匙串替身，不访问真实服务器。NETWORK_TEST_URL 仅用于可控的回环测试服务；VERIFY_LOCAL_MODELS=1 可真实加载产品目录旁的 Qwen 并测试安装的系统翻译。不要把真实会议内容用于固定协议验收。

运行依赖目录包含模型、Python 环境与参考推理代码，不在源码 ZIP 中。移动整个产品目录时保留其相对位置；启动时会幂等修正旧产品绝对路径，仍可在设置中手动重新选择。网络客户端不包含公司服务端部署程序。
