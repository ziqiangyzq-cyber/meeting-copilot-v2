# Meeting Copilot

一款面向 macOS 的本地优先会议助手：同时接住麦克风和电脑声音，分段转写、翻译、保存，并可基于当前会议生成纪要、行动项和问答草稿。

> 当前版本：**2.0.2** · 要求 macOS 14.2+ · 主要面向 Apple Silicon

## 为什么做它

会议工具通常只解决一个环节：录音、转写、翻译或总结。Meeting Copilot 把整条链路放在一个桌面 App 里，并尽量让用户自己决定数据去哪里：

- **本地优先**：转写可使用本机 Qwen3-ASR 或 Apple 离线语音；翻译可使用 macOS 已安装的翻译语言资源。
- **API 可选**：转写、翻译、纪要可以分别接入兼容 OpenAI 风格接口的局域网或在线服务。
- **两路声音**：麦克风、电脑声音，或两者同时采集。
- **结果留在本机**：会议记录按段增量写入本地，不依赖云端账户才能保存。
- **发送前确认**：网络模式必须显式允许发送；纪要生成前展示目标服务、模型和发送范围。

## 功能

### 采集与转写

- 仅麦克风、仅电脑声音、电脑声音 + 麦克风三种模式。
- 电脑声音使用 macOS Core Audio Tap，只申请“仅系统录音”权限，不读取屏幕画面。
- 约每 8 秒形成一个识别段，原文先保存，再生成译文；不是逐字实时字幕。
- 收到第一帧音频后才显示“正在采集”；8 秒内无首帧会明确报错。
- 停止时排空尾段；已确认的原文不会因为后续失败而被覆盖。

### 本机模型

- **Qwen3-ASR-1.7B**：MLX 格式，本地分段批处理，支持中英文自动识别。
- **Apple Speech**：系统本机离线识别，当前用于麦克风链路。
- **Apple 系统翻译**：使用 macOS 已安装的语言资源，不会自动下载或静默回退到云端。

Qwen 模型和 Python 运行环境体积较大，不随源码仓库分发。App 内可选择模型目录与运行目录，并在“测试配置”时真实加载验证。

### 网络 API

转写与翻译分别选择“本机”或“网络”，可以混合使用，例如：

- 局域网服务器转写 + 本机翻译
- 本机 Qwen 转写 + 在线模型翻译
- 两路都走自建兼容服务

网络转写要求服务支持：

```text
POST <baseURL>/audio/transcriptions
Content-Type: multipart/form-data

字段：file(WAV), model, response_format=json
可选：language, prompt
返回：{"text": "..."}
```

网络翻译要求服务支持：

```text
POST <baseURL>/chat/completions
返回：choices[0].message.content
```

`baseURL` 填服务根地址，通常以 `/v1` 结尾。支持 HTTP 或 HTTPS；跨网络使用时建议 HTTPS。API Key 存入 macOS 钥匙串，设置文件只保存引用。服务器明确无需鉴权时，可勾选“服务器无需 API Key”。

### 会议纪要与问答

- 使用独立的兼容 Chat Completions 接口。
- 支持生成会议纪要、提取行动项、对当前会议提问。
- 可选择性发送当前会话导入的 TXT / Markdown 资料。
- 生成的是**独立草稿**，不覆盖原始转写；草稿保留来源引用和版本绑定。
- 原文段号与带时间的随记会进入来源快照，帮助模型区分事实、提议和未确认事项。

### 资料与导出

- 可为会议指定资料文件夹，递归读取 TXT、Markdown 和可抽取文字的 PDF。
- 不修改原资料，不自动上传；扫描件、加密 PDF 和复杂格式暂不做 OCR。
- 当前会话可导出 Markdown 或 JSON，包含修订历史。
- 纪要草稿可复制或导出 Markdown。

## 安装

### 使用发布包

1. 下载 `Meeting-Copilot-2.0.2.zip` 并解压。
2. 将 `Meeting Copilot 2.app` 放入“应用程序”或你自己的工作目录。
3. 首次打开时按提示授予麦克风或“仅系统录音”权限。
4. 打开“设置”，选择转写、翻译和纪要服务；点击“测试配置”，通过后保存。

发布包当前使用本地 ad-hoc 签名，未做 Apple Developer ID 公证。若 macOS 阻止首次打开，可在“系统设置 → 隐私与安全性”中确认打开；正式分发建议补 Developer ID 签名和 notarization。

### 从源码构建

需要 Xcode Command Line Tools 与 Swift 6。使用 Xcode 的完整工具链；仅安装 Command Line Tools 时，部分 macOS SDK 缺少 SwiftUI 宏插件，无法构建客户端界面。先构建各本地 Swift 包，再构建客户端：

```bash
cd continuous-client
swift build \
  --configuration debug \
  --scratch-path .build \
  --cache-path .cache \
  -Xswiftc -module-cache-path \
  -Xswiftc .module-cache
```

构建产物为 `.build/debug/MeetingCopilot`。打包成 `.app` 时还需复制 `Info.plist`、`text-mode-config.json` 和图标资源，详见 [`README-源码与构建说明.md`](README-源码与构建说明.md)。

## 使用流程

1. **新建会议**，选择声音来源。
2. **首次使用电脑声音**：点击“请求授权并检测”，在“系统设置 → 隐私与安全性 → 仅系统录音”中允许 Meeting Copilot，然后返回重新检测。
3. **开始采集**，确认界面出现真实音频活动，而不是仅有“正在采集”状态。
4. **停止并保存**，等待尾段排空。
5. 如需纪要或问答，在“会议纪要”中选择目标模型并确认发送范围。

> 重启 App 后，本机 Qwen 不会自动加载。开始采集前先在设置中执行一次“测试配置”，确认引擎已加载。

## 隐私边界

- 屏幕画面不读取、不保存、不上传。
- 本机模式不上传音频或原文。
- 网络模式每次重新打开 App 后默认关闭发送授权；配置变化也会关闭。
- 测试网络转写只上传 1 秒静音 WAV；测试翻译只发送固定短句，不发送会议内容。
- 网络请求有大小、响应和超时限制，并拒绝重定向，避免凭据被转发到其他地址。
- 会议记录、设置和导入资料默认保存在本机。

## 当前验证范围

已完成的验证包括：

- 本机 Qwen 真实加载与短句转写。
- 麦克风与电脑声音双路采集。
- 电脑声音约 48 秒真实 GUI 采集，生成并持久化两段完整文字，重启后可回读。
- 本地与网络转写、翻译、纪要链路的隔离测试。
- 十项 Swift 回归检查：产品迁移、工作区、设置、纪要、集成客户端、增量客户端、网络服务、存储演进、音频输入、双路音频。

尚未覆盖：

- 长时间真实会议的识别质量和稳定性。
- 不同厂商服务的全部兼容性。
- 公网分发所需的 Developer ID 签名、公证和自动更新。
- 扫描 PDF / OCR、系统级逐字实时字幕。

## 技术结构

```text
continuous-client/        SwiftUI 客户端与运行时
speech-core/              语音识别核心与本地 Qwen/Apple 适配
audio-capture/            Core Audio / 麦克风采集
desktop-session/          分段识别与排空控制
rotating-speech-session/  轮转语音会话
canonical-audio-clock/    音频时钟与重排
incremental-archive/      增量持久化
client-incremental-bridge/客户端与归档桥接
local-translation/        Apple 本机翻译
api-intelligence/         兼容 Chat Completions 的纪要/问答
```

## 版本

### 2.0.2

- 将旧版兼容常量集中到只读迁移模块，公开产品身份只保留中性标识。
- 完善源码构建说明和公开仓库历史。

### 2.0.1

- 使用 MIT 许可证。
- 将 Bundle ID、应用数据目录和钥匙串服务改为中性的公开标识；旧版数据只复制迁移，不删除。
- 移除默认专业词库，术语提示仅使用用户填写的内容。

### 2.0.0

- 产品统一更名为 Meeting Copilot。
- 新增 Core Audio Tap 电脑声音采集，不再依赖屏幕录制权限。
- 修复交错双声道 Float32 到平面声道的转换。
- 扩大 PCM 缓冲，避免 8 秒分段前溢出。
- 修复保存设置后误卸载已加载的 Qwen 引擎。
- 新增双路音频、高密度缓冲和迁移回归检查。

## 说明

仓库中的 `Foresight Meeting` 字样仅用于旧数据、旧路径和钥匙串兼容迁移，不是当前产品名称。

## License

本仓库采用 [MIT License](LICENSE)。第三方模型、运行环境和依赖分别遵循其各自许可证，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
