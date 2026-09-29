<p align="center">
  <img src="docs/brand/forumind-banner-zh-Hans.png" alt="Forumind：秒懂任何 Discourse 论坛。AI 摘要、聊天，以及附带来源的回答，支持 iPhone 与 iPad。" width="100%">
</p>

<h3 align="center">为任何 Discourse 论坛打造的论坛浏览器，身边还有一位 AI 助手。</h3>

<p align="center">
  <a href="https://apps.apple.com/app/id6816718686"><img src="https://img.shields.io/badge/App_Store-%E5%AE%A1%E6%A0%B8%E4%B8%AD-0D96F6?logo=appstore&logoColor=white" alt="App Store：审核中"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="许可证：Apache-2.0"></a>
  <img src="https://img.shields.io/badge/iOS_%7C_iPadOS-17%2B-000000?logo=apple&logoColor=white" alt="iOS 与 iPadOS 17 或更高版本">
  <img src="https://img.shields.io/badge/Swift-F05138?logo=swift&logoColor=white" alt="Swift">
  <img src="https://img.shields.io/badge/Made_with-SwiftUI-2396F3?logo=swift&logoColor=white" alt="使用 SwiftUI 构建">
  <a href="https://github.com/kccarlos/forumind/stargazers"><img src="https://img.shields.io/github/stars/kccarlos/forumind?style=social" alt="GitHub 星标"></a>
</p>

<p align="center">
  <a href="README.md">English</a> · <b>简体中文</b> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

**几秒读懂任何 Discourse 论坛。** 总结长篇话题、追问细节，还能让 AI
替你搜索整个论坛，并附上它引用的帖子链接。Forumind 是一款免费开源的
iPhone 与 iPad App，适用于任何基于 [Discourse](https://www.discourse.org)
搭建的论坛，例如 [meta.discourse.org](https://meta.discourse.org)，或你自己的社区。

> **App Store：** Forumind 已提交审核，正在审核中。Apple 审核通过后，
> [App Store 链接](https://apps.apple.com/app/id6816718686)即可使用。在此之前，
> 你可以[自行构建](#从源代码构建)。

**想在电脑浏览器上使用？** 也可以试试 Chrome 扩展版本：[DiscourseCopilot](https://github.com/kccarlos/DiscourseCopilot)。

## 为什么选择 Forumind

- **少读一点，多懂一些。** 不必逐条阅读，也能掌握 500 条回复的话题重点。
- **直接问，不用翻。** 向论坛提问，得到附带编号来源的回答，点一下就能查看原帖。
- **任何 Discourse 论坛。** 公开或私有、大型或小型，包括你自己的社区。
- **AI 由你选。** 免密钥的 Apple 智能、你自己的 AI 提供方，或你自己电脑上的模型。
- **隐私从设计开始。** 没有 Forumind 服务器、账户、分析、广告或跟踪。
- **免费开源。** 采用 Apache-2.0 许可，使用 SwiftUI 为 iPhone 与 iPad 打造。

## 截图

<p align="center">
  <img src="docs/screenshots/store/zh-Hans/iphone-69-1-summary.png" alt="长篇讨论秒懂重点：长篇论坛话题的 AI 摘要" width="190">
  <img src="docs/screenshots/store/zh-Hans/iphone-69-2-ask.png" alt="问遍整个论坛：回答附带原帖链接" width="190">
  <img src="docs/screenshots/store/zh-Hans/iphone-69-3-chat.png" alt="任何话题随时追问：针对讨论串追问细节" width="190">
  <img src="docs/screenshots/store/zh-Hans/iphone-69-4-forums.png" alt="所有论坛一个 App：置顶的论坛与从浏览器分享" width="190">
</p>
<p align="center">
  <img src="docs/screenshots/store/zh-Hans/ipad-13-1-summary.png" alt="在 iPad 上，论坛和助手并排显示" width="560">
</p>

## 功能

### 读懂任何话题

- **摘要。** 原帖内容、大家怎么说，以及帖子里的建议。之后点 **检查新回复**，
  只读取新增的内容。
- **聊天。** 针对正在阅读的话题提问：“大家最后怎么决定的？”或“有没有变通办法？”
- **问论坛。** 提出问题，助手会搜索论坛、阅读最相关的话题，并给出附带编号
  来源的回答，点一下即可打开。

### 所有论坛集中一处

- **任何 Discourse 论坛。** 打开论坛，App 就能识别。在 **论坛** 主页置顶常用
  论坛；访问过的论坛会出现在“最近”中。
- **从 Safari 或 Chrome 分享。** 把任何论坛页面分享到 Forumind，即可打开、
  生成摘要、聊天或问论坛。
- **关注话题。** 话题有新回复时收到通知。
- **iPhone 与 iPad。** 在 iPad 上，论坛和助手并排显示。

### 每项工作都有合适的 AI

- **Apple 智能或你自己的 AI 提供方。** 请参阅[选择你的 AI](#选择你的-ai)。
- **两个默认模型。** 一个用于 **摘要与聊天**，一个用于 **问论坛**，让每项工作
  都用上合适的模型。

### 隐私、同步与礼貌

- **iCloud 同步。** 论坛、摘要、聊天和设置会在你的 iPhone 与 iPad 之间自动
  同步，并以端到端加密的方式保存在你自己的 iCloud 账户中；API 密钥通过
  iCloud 钥匙串同步。
- **对论坛服务器保持礼貌。** 默认每秒读取一页话题内容（设置 › 摘要与聊天 ›
  论坛请求），每个论坛单独控制节奏。论坛要求放慢速度时，App 会等待后重试。
- **可选的广告与跟踪器拦截**，用于内置浏览器，基于 EasyList 与 EasyPrivacy。
  出于对依赖广告的论坛站长的尊重，默认关闭；可在 设置 › 浏览器 中开启。
- **支持你的语言。** 英文、简体中文和繁体中文。

## 选择你的 AI

**Apple 智能** 是最简单的选择：在支持的设备上，App 会使用 Apple 的设备端
模型，并在可用时使用私密云计算，无需账户，也无需 API 密钥。可用时会自动选用。

也可以 **使用你自己的 AI 提供方**。粘贴一次 API 密钥，App 就会推荐一个合适的模型：

| AI 提供方 | 你需要准备 | 说明 |
| --- | --- | --- |
| OpenRouter | API 密钥 | 一个密钥，多种模型 |
| OpenAI | API 密钥 | GPT 模型 |
| Anthropic | API 密钥 | Claude 模型 |
| Google Gemini | API 密钥 | Gemini 模型 |
| Google Vertex AI | 来自 Google Cloud 的 Vertex AI API 密钥 | Gemini 模型，费用计入你的 Cloud 项目 |
| Groq | API 密钥 | 快速的开源模型 |
| xAI | API 密钥 | Grok 模型 |
| DeepSeek | API 密钥 | DeepSeek 模型 |
| NVIDIA NIM | 来自 build.nvidia.com 的 API 密钥 | 开源模型，兼容 OpenAI |
| Ollama | 在你局域网内的电脑上运行 Ollama | 免费、私密、无需密钥 |
| LM Studio | 在你局域网内的电脑上运行 LM Studio | 免费、私密、无需密钥 |

**拿不定主意？** 如果你的设备支持，就用 Apple 智能。否则，如果你已经在为
其中某一家付费，就用那一家；想用一个密钥试用多种模型，OpenRouter 是个不错的
起点。使用 Ollama 或 LM Studio 时，把电脑的地址（例如
`http://192.168.1.20:11434`）填为基础 URL。

**两个模型，各司其职。** 设置 › AI 模型 中有一个用于 **摘要与聊天** 的默认
模型，还有一个用于 **问论坛** 的默认模型。摘要和聊天需要阅读大量文字，快速、
低成本的模型就很合适；问论坛需要规划搜索并对读到的内容进行推理，更强的模型
更值得。两者一开始都是你在设置过程中选择的模型；更改其中一个，或从助手的
菜单中切换，另一个保持不变。密钥属于 AI 提供方，因此同一提供方的两个模型
共用一个密钥。

## 获取 Forumind

### App Store

Forumind 正在接受 App Store 审核。Apple 审核通过后，可在这里下载：
**[App Store 上的 Forumind](https://apps.apple.com/app/id6816718686)**。

### 从源代码构建

你需要一台装有 Xcode 27 和 `xcodeproj` Ruby gem 的 Mac：

```sh
git clone https://github.com/kccarlos/forumind.git
cd forumind
gem install xcodeproj
ruby scripts/generate_project.rb
open Forumind.xcodeproj
```

可以直接在模拟器上运行。若要安装到你自己的 iPhone 或 iPad，请先设置签名团队；
请参阅 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#signing)（英文）。

### 开始使用

1. **选择你的 AI。** 首次启动时会引导你完成。你也可以跳过，稍后在设置中选择。
2. **选择你的论坛。** 置顶推荐的论坛，或按地址添加（`meta.discourse.org`，
   或子目录论坛，例如 `example.com/forum`）。
3. **打开一个话题，点按“助手”。** 选择 **摘要**、**聊天** 或 **问论坛**。

如果论坛需要登录，请在 App 的内置浏览器中登录。App 读取论坛的方式与浏览器
相同，所以你能看到的内容，它也能读取。

**iPhone 与 iPad 之间的同步** 是自动的：在两台设备上登录同一个 Apple 账户，
你的论坛、摘要、聊天和设置就会跟着你走。可在 **设置 › iCloud 同步** 中查看或
关闭。（同步需要使用付费团队签名的构建版本；请参阅
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#icloud-sync-cloudkit-and-signing)（英文）。）

## 用大白话讲隐私

- **没有中间人。** 没有 Forumind 服务器、账户、分析、广告或跟踪。
- **论坛帖子只会发送给你选择的 AI**，直接从你的设备发出。使用 Apple 智能时，
  帖子留在你的设备上，或发送到 Apple 的私密云计算。
- **你的密钥保存在你的钥匙串中**（如果你同步密钥，也会保存在 iCloud 钥匙串中）。
- **你的记录只属于你：** 保存在你的设备上；开启同步后，以端到端加密的方式
  保存在你自己的 iCloud 账户中，其他人都无法读取。
- **每个论坛的登录只属于该论坛。** Cookie 只会发送给它所属的论坛。

完整说明：[隐私政策](PRIVACY.md)（英文）。

## 常见问题

<details>
<summary><b>需要付费吗？</b></summary>

App 免费。使用 Apple 智能和本地模型不产生任何费用。其他 AI 提供方可能按用量
收费，通常每份摘要只需很少的费用。
</details>

<details>
<summary><b>这是 Discourse 官方出品的吗？</b></summary>

不是。Forumind 是一款面向 Discourse 论坛的独立开源 App，与 Civilized
Discourse Construction Kit, Inc. 或任何论坛均无关联，也未获得其认可。
</details>

<details>
<summary><b>哪些论坛可以用？</b></summary>

任何运行 Discourse 的论坛，无论公开还是私有（在 App 内登录即可）。如果页面
不是 Discourse 论坛，App 会告诉你。
</details>

<details>
<summary><b>我的记录会保留多久？</b></summary>

摘要会被保留（最近的 40 份，以及你 **保留** 的所有内容）。未保留的聊天和活动
会在一天后清除。**设置 › 数据与隐私** 可按论坛或一次性删除全部数据。
</details>

<details>
<summary><b>论坛要求我放慢速度。</b></summary>

当论坛限制请求频率时，App 会自动等待并重试。
</details>

<details>
<summary><b>在后台也会继续工作吗？</b></summary>

在 App 中浏览其他话题时，工作会继续进行。切换到其他 App 时，iOS 可能会暂停它；
回来后会继续。
</details>

<details>
<summary><b>可以在桌面浏览器上使用吗？</b></summary>

也有
[Chrome 扩展](https://github.com/kccarlos/DiscourseCopilot)可用。
</details>

## 开发者文档

以下文档为英文：

- [Development](docs/DEVELOPMENT.md)：环境配置、签名、测试、DEBUG 启动参数
- [Architecture](docs/ARCHITECTURE.md)：App 的整体结构
- [CI/CD](docs/CI.md)：GitHub Actions、TestFlight、发布
- [Ad blocking](docs/AD_BLOCKING.md)：过滤列表如何转换和加载
- [iCloud sync](docs/SYNC.md)：CloudKit 同步、合并规则、加密
- [Apple Intelligence](docs/APPLE_INTELLIGENCE.md)：设备端与私密云计算
- [App Store](docs/APP_STORE.md)：发布检查清单

## 参与贡献

欢迎各种形式的贡献：问题反馈、想法、翻译、文档和代码。请参阅
[CONTRIBUTING.md](CONTRIBUTING.md) 和[行为准则](CODE_OF_CONDUCT.md)（英文）。
安全问题请私下报告（[SECURITY.md](SECURITY.md)）。

如果 Forumind 帮你节省了时间，在 GitHub 上点个星标，能帮助更多人发现它。

## 许可证

Forumind 采用 [Apache License 2.0](LICENSE) 许可。

Forumind 是一款独立 App，与 Civilized Discourse Construction Kit, Inc.
无关联，也未获得其认可。Discourse 是其各自所有者的商标。

## 致谢

- 可选的广告与跟踪器拦截使用了源自
  [EasyList 和 EasyPrivacy](https://easylist.to/) 的规则，采用 CC BY-SA 3.0
  许可；请参阅 [NOTICE](NOTICE)。
- 为 [Discourse](https://www.discourse.org) 社区而打造，正是它开放的平台让这样的论坛成为可能。
