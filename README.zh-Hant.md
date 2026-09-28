<p align="center">
  <img src="docs/brand/forumind-banner-zh-Hant.png" alt="Forumind：秒懂任何 Discourse 論壇。AI 摘要、聊天，以及附上來源的回答，支援 iPhone 與 iPad。" width="100%">
</p>

<h3 align="center">為任何 Discourse 論壇打造的論壇瀏覽器，身旁還有一位 AI 助理。</h3>

<p align="center">
  <a href="https://apps.apple.com/app/id6816718686"><img src="https://img.shields.io/badge/App_Store-%E5%AF%A9%E6%A0%B8%E4%B8%AD-0D96F6?logo=appstore&logoColor=white" alt="App Store：審核中"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="授權條款：Apache-2.0"></a>
  <img src="https://img.shields.io/badge/iOS_%7C_iPadOS-17%2B-000000?logo=apple&logoColor=white" alt="iOS 與 iPadOS 17 或以上版本">
  <img src="https://img.shields.io/badge/Swift-F05138?logo=swift&logoColor=white" alt="Swift">
  <img src="https://img.shields.io/badge/Made_with-SwiftUI-2396F3?logo=swift&logoColor=white" alt="以 SwiftUI 打造">
  <a href="https://github.com/kccarlos/forumind/stargazers"><img src="https://img.shields.io/github/stars/kccarlos/forumind?style=social" alt="GitHub 星星"></a>
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.zh-Hans.md">简体中文</a> · <b>繁體中文</b>
</p>

**幾秒讀懂任何 Discourse 論壇。** 摘要長篇話題、追問細節，還能讓 AI
替你搜尋整個論壇，並附上它引用的貼文連結。Forumind 是一款免費、開放原始碼的
iPhone 與 iPad App，適用於任何以 [Discourse](https://www.discourse.org)
架設的論壇，例如 [meta.discourse.org](https://meta.discourse.org)，或你自己的社群。

> **App Store：** Forumind 已送交審核，目前審核中。Apple 核准後，
> [App Store 連結](https://apps.apple.com/app/id6816718686)即可使用。在此之前，
> 你可以[自行建置](#從原始碼建置)。

## 為什麼選擇 Forumind

- **少讀一點，多懂一些。** 不必逐篇閱讀，也能掌握 500 則回覆的話題重點。
- **直接問，不用翻。** 向論壇提問，得到附上編號來源的回答，點一下就能查看原文。
- **任何 Discourse 論壇。** 公開或私人、大型或小型，包括你自己的社群。
- **AI 由你選。** 免金鑰的 Apple Intelligence、你自己的 AI 供應商，或你自己電腦上的模型。
- **隱私從設計開始。** 沒有 Forumind 伺服器、帳號、分析、廣告或追蹤。
- **免費、開放原始碼。** 採用 Apache-2.0 授權，以 SwiftUI 為 iPhone 與 iPad 打造。

## 截圖

<p align="center">
  <img src="docs/screenshots/store/zh-Hant/iphone-69-1-summary.png" alt="長篇討論秒懂重點：長篇論壇話題的 AI 摘要" width="190">
  <img src="docs/screenshots/store/zh-Hant/iphone-69-2-ask.png" alt="問遍整個論壇：回答附上原文連結" width="190">
  <img src="docs/screenshots/store/zh-Hant/iphone-69-3-chat.png" alt="任何話題隨時追問：針對討論串追問細節" width="190">
  <img src="docs/screenshots/store/zh-Hant/iphone-69-4-forums.png" alt="所有論壇一個 App：釘選的論壇與從瀏覽器分享" width="190">
</p>
<p align="center">
  <img src="docs/screenshots/store/zh-Hant/ipad-13-1-summary.png" alt="在 iPad 上，論壇和助理並排顯示" width="560">
</p>

## 功能

### 讀懂任何話題

- **摘要。** 原文內容、大家怎麼說，以及討論串裡的建議。之後點 **檢查新回覆**，
  只讀取新增的內容。
- **聊天。** 針對正在閱讀的話題提問：「大家最後怎麼決定？」或「有沒有替代做法？」
- **問論壇。** 提出問題，助理會搜尋論壇、閱讀最相關的話題，並給出附上編號
  來源的回答，點一下即可開啟。

### 所有論壇集中一處

- **任何 Discourse 論壇。** 開啟論壇，App 就能辨識。在 **論壇** 首頁釘選常用
  論壇；造訪過的論壇會出現在「最近」中。
- **從 Safari 或 Chrome 分享。** 把任何論壇頁面分享到 Forumind，即可開啟、
  產生摘要、聊天或問論壇。
- **追蹤話題。** 話題有新回覆時收到通知。
- **iPhone 與 iPad。** 在 iPad 上，論壇和助理並排顯示。

### 每項工作都有合適的 AI

- **Apple Intelligence 或你自己的 AI 供應商。** 請參閱[選擇你的 AI](#選擇你的-ai)。
- **兩個預設模型。** 一個用於 **摘要與聊天**，一個用於 **問論壇**，讓每項工作
  都用上合適的模型。

### 隱私、同步與禮貌

- **iCloud 同步。** 論壇、摘要、聊天和設定會在你的 iPhone 與 iPad 之間自動
  同步，並以端對端加密的方式儲存在你自己的 iCloud 帳號中；API 金鑰透過
  iCloud 鑰匙圈同步。
- **對論壇伺服器保持禮貌。** 預設每秒讀取一頁話題內容（設定 › 摘要與聊天 ›
  論壇請求），每個論壇各自控制節奏。論壇要求放慢速度時，App 會等待後重試。
- **可選用的廣告與追蹤器阻擋**，用於內建瀏覽器，以 EasyList 與 EasyPrivacy 為基礎。
  出於對仰賴廣告的論壇站長的尊重，預設為關閉；可在 設定 › 瀏覽器 中開啟。
- **支援你的語言。** 英文、簡體中文和繁體中文。

## 選擇你的 AI

**Apple Intelligence** 是最簡單的選擇：在支援的裝置上，App 會使用 Apple 的
裝置端模型，並在可用時使用私密雲端運算，不需要帳號，也不需要 API 金鑰。
可用時會自動選用。

也可以 **使用你自己的 AI 供應商**。貼上一次 API 金鑰，App 就會推薦一個合適的模型：

| AI 供應商 | 你需要準備 | 說明 |
| --- | --- | --- |
| OpenRouter | API 金鑰 | 一組金鑰，多種模型 |
| OpenAI | API 金鑰 | GPT 模型 |
| Anthropic | API 金鑰 | Claude 模型 |
| Google Gemini | API 金鑰 | Gemini 模型 |
| Groq | API 金鑰 | 快速的開放模型 |
| xAI | API 金鑰 | Grok 模型 |
| DeepSeek | API 金鑰 | DeepSeek 模型 |
| NVIDIA NIM | 來自 build.nvidia.com 的 API 金鑰 | 開放模型，相容 OpenAI |
| Ollama | 在你區域網路內的電腦上執行 Ollama | 免費、私密、不需金鑰 |
| LM Studio | 在你區域網路內的電腦上執行 LM Studio | 免費、私密、不需金鑰 |

**拿不定主意？** 如果你的裝置支援，就用 Apple Intelligence。否則，如果你已經
在付費使用其中一家，就用那一家；想用一組金鑰試用多種模型，OpenRouter 是個
不錯的起點。使用 Ollama 或 LM Studio 時，把電腦的位址（例如
`http://192.168.1.20:11434`）填為基礎 URL。

**兩個模型，各司其職。** 設定 › AI 模型 中有一個用於 **摘要與聊天** 的預設
模型，還有一個用於 **問論壇** 的預設模型。摘要和聊天需要閱讀大量文字，快速、
低成本的模型就很合適；問論壇需要規劃搜尋並對讀到的內容進行推理，更強的模型
更值得。兩者一開始都是你在設定過程中選擇的模型；變更其中一個，或從助理的
選單中切換，另一個維持不變。金鑰屬於 AI 供應商，因此同一供應商的兩個模型
共用一組金鑰。

## 取得 Forumind

### App Store

Forumind 正在接受 App Store 審核。Apple 核准後，可在這裡下載：
**[App Store 上的 Forumind](https://apps.apple.com/app/id6816718686)**。

### 從原始碼建置

你需要一台裝有 Xcode 27 和 `xcodeproj` Ruby gem 的 Mac：

```sh
git clone https://github.com/kccarlos/forumind.git
cd forumind
gem install xcodeproj
ruby scripts/generate_project.rb
open Forumind.xcodeproj
```

可以直接在模擬器上執行。若要安裝到你自己的 iPhone 或 iPad，請先設定簽署團隊；
請參閱 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#signing)（英文）。

### 開始使用

1. **選擇你的 AI。** 首次啟動時會引導你完成。你也可以略過，稍後在設定中選擇。
2. **選擇你的論壇。** 釘選推薦的論壇，或依位址加入（`meta.discourse.org`，
   或子目錄論壇，例如 `example.com/forum`）。
3. **開啟一個話題，點一下「助理」。** 選擇 **摘要**、**聊天** 或 **問論壇**。

如果論壇需要登入，請在 App 的內建瀏覽器中登入。App 讀取論壇的方式與瀏覽器
相同，所以你看得到的內容，它也讀得到。

**iPhone 與 iPad 之間的同步** 是自動的：在兩台裝置上登入同一個 Apple 帳號，
你的論壇、摘要、聊天和設定就會跟著你走。可在 **設定 › iCloud 同步** 中查看或
關閉。（同步需要以付費團隊簽署的建置版本；請參閱
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#icloud-sync-cloudkit-and-signing)（英文）。）

## 用白話講隱私

- **沒有中間人。** 沒有 Forumind 伺服器、帳號、分析、廣告或追蹤。
- **論壇貼文只會傳送給你選擇的 AI**，直接從你的裝置送出。使用 Apple Intelligence
  時，貼文留在你的裝置上，或傳送到 Apple 的私密雲端運算。
- **你的金鑰保存在你的鑰匙圈中**（如果你同步金鑰，也會保存在 iCloud 鑰匙圈中）。
- **你的紀錄只屬於你：** 儲存在你的裝置上；開啟同步後，以端對端加密的方式
  儲存在你自己的 iCloud 帳號中，其他人都無法讀取。
- **每個論壇的登入只屬於該論壇。** Cookie 只會傳送給它所屬的論壇。

完整說明：[隱私權政策](PRIVACY.md)（英文）。

## 常見問題

<details>
<summary><b>需要付費嗎？</b></summary>

App 免費。使用 Apple Intelligence 和本機模型不需任何費用。其他 AI 供應商可能
依用量收費，通常每份摘要只需很少的費用。
</details>

<details>
<summary><b>這是 Discourse 官方推出的嗎？</b></summary>

不是。Forumind 是一款為 Discourse 論壇打造的獨立開放原始碼 App，與 Civilized
Discourse Construction Kit, Inc. 或任何論壇皆無關聯，也未獲得其背書。
</details>

<details>
<summary><b>哪些論壇可以用？</b></summary>

任何執行 Discourse 的論壇，無論公開或私人（在 App 內登入即可）。如果頁面
不是 Discourse 論壇，App 會告訴你。
</details>

<details>
<summary><b>我的紀錄會保留多久？</b></summary>

摘要會被保留（最近的 40 份，以及你 **保留** 的所有內容）。未保留的聊天和活動
會在一天後清除。**設定 › 資料與隱私** 可依論壇或一次刪除全部資料。
</details>

<details>
<summary><b>論壇要求我放慢速度。</b></summary>

當論壇限制請求頻率時，App 會自動等待並重試。
</details>

<details>
<summary><b>在背景也會繼續運作嗎？</b></summary>

在 App 中瀏覽其他話題時，工作會繼續進行。切換到其他 App 時，iOS 可能會暫停它；
回來後會繼續。
</details>

<details>
<summary><b>可以在桌面瀏覽器上使用嗎？</b></summary>

也有
[Chrome 擴充功能](https://github.com/kccarlos/DiscourseCopilot)可以使用。
</details>

## 開發者文件

以下文件為英文：

- [Development](docs/DEVELOPMENT.md)：環境設定、簽署、測試、DEBUG 啟動參數
- [Architecture](docs/ARCHITECTURE.md)：App 的整體架構
- [CI/CD](docs/CI.md)：GitHub Actions、TestFlight、發布
- [Ad blocking](docs/AD_BLOCKING.md)：過濾清單如何轉換與載入
- [iCloud sync](docs/SYNC.md)：CloudKit 同步、合併規則、加密
- [Apple Intelligence](docs/APPLE_INTELLIGENCE.md)：裝置端與私密雲端運算
- [App Store](docs/APP_STORE.md)：發布檢查清單

## 參與貢獻

歡迎各種形式的貢獻：問題回報、想法、翻譯、文件和程式碼。請參閱
[CONTRIBUTING.md](CONTRIBUTING.md) 和[行為準則](CODE_OF_CONDUCT.md)（英文）。
安全性問題請私下回報（[SECURITY.md](SECURITY.md)）。

如果 Forumind 幫你節省了時間，在 GitHub 上按個星星，能幫助更多人發現它。

## 授權條款

Forumind 採用 [Apache License 2.0](LICENSE) 授權。

Forumind 是一款獨立 App，與 Civilized Discourse Construction Kit, Inc.
無關聯，也未獲得其背書。Discourse 是其各自所有者的商標。

## 致謝

- 可選用的廣告與追蹤器阻擋使用了源自
  [EasyList 和 EasyPrivacy](https://easylist.to/) 的規則，採用 CC BY-SA 3.0
  授權；請參閱 [NOTICE](NOTICE)。
- 為 [Discourse](https://www.discourse.org) 社群而打造，正是它開放的平台讓這樣的論壇成為可能。
