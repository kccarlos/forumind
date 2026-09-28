import Foundation

#if DEBUG
/// The words of the DEBUG sample data (`-dc-sample`, `-dc-seed-forums`) in
/// the app's language, so screenshots in Simplified or Traditional Chinese
/// show Chinese forums, topics, summaries, chats and answers too.
///
/// English keeps Discourse Meta as the first forum (the real page can load
/// behind the sample). The Chinese sets use only fictional communities on
/// reserved example domains, so use them with `-dc-forums-home`. No real
/// people or companies appear in any set. Debug-only: not in the String
/// Catalog.
struct SampleContent {
    struct ForumText {
        var siteURL: String
        var name: String
    }

    // Forums (`-dc-sample`).
    var meta: ForumText
    var makers: ForumText
    var homeLab: ForumText
    // Extra forums (`-dc-seed-forums`) and suggestions.
    var trailRunners: ForumText
    var bakers: ForumText
    var boardGames: ForumText
    var boardGamesDescription: String
    var gardeners: ForumText
    var gardenersDescription: String

    // Topic titles.
    var unifiedNewTitle: String
    var markdownEndpointsTitle: String
    var sidebarTitle: String
    var layerShiftsTitle: String
    var stepperHeatTitle: String
    var slicerPresetsTitle: String
    var fanAfterPrintTitle: String
    var lowPowerNASTitle: String

    // Summaries and chats.
    var metaSummary: String
    var metaChat: [(ChatRole, String)]
    var markdownEndpointsSummary: String
    var sidebarSummary: String
    var streamSummary: String
    var streamChat: [(ChatRole, String)]
    var stepperHeatSummary: String
    var slicerPresetsSummary: String
    var lowPowerNASSummary: String

    // Ask the forum (on the makers forum).
    var agentGoal: String
    var agentSearchQuery: String
    var agentSecondSearchQuery: String
    var agentThoughts: [String]
    var agentRunningStatus: String
    /// `%1$@` … `%3$@`: the URLs of the layer-shift, stepper and fan topics.
    var agentAnswer: (_ layerShifts: String, _ stepperHeat: String, _ fan: String) -> String
    var agentFollowUpQuestion: String
    var agentFollowUpAnswer: String
    // The older run (on the first forum).
    var olderGoal: String
    var olderSearchQuery: String
    var olderAnswer: String

    // Work in progress.
    var summaryRunningStatus: String
    var summaryStream: String
    var chatStreamingQuestion: String
    var chatStreamingAnswer: String

    /// The set for the app's language.
    static var current: SampleContent {
        switch AppLanguage.current {
        case "zh-Hans": simplifiedChinese
        case "zh-Hant": traditionalChinese
        default: english
        }
    }
}

// MARK: - English

extension SampleContent {
    static let english = SampleContent(
        meta: ForumText(siteURL: "https://meta.discourse.org", name: "Discourse Meta"),
        makers: ForumText(siteURL: "https://community.example.org", name: "Maker Space Community"),
        homeLab: ForumText(siteURL: "https://forum.example.net", name: "Home Lab Forum"),
        trailRunners: ForumText(siteURL: "https://talk.example.com", name: "Trail Runners Club"),
        bakers: ForumText(siteURL: "https://bakers.example.org", name: "Sourdough Bakers"),
        boardGames: ForumText(siteURL: "https://games.example.com", name: "Board Game Guild"),
        boardGamesDescription: "Rules questions, reviews, and game night meetups.",
        gardeners: ForumText(siteURL: "https://garden.example.net", name: "Community Gardeners"),
        gardenersDescription: "Seed swaps, raised beds, and plot planning.",
        unifiedNewTitle: "Introducing the unified new view for the topic list",
        markdownEndpointsTitle: "Discourse core now includes Markdown endpoints for topic lists and views",
        sidebarTitle: "Experimental user sidebar navigation",
        layerShiftsTitle: "Layer shifts on long prints after the 2.4 firmware update",
        stepperHeatTitle: "Stepper drivers overheating in enclosed printers",
        slicerPresetsTitle: "Sharing slicer presets between machines",
        fanAfterPrintTitle: "Cooling fan keeps running after a print finishes",
        lowPowerNASTitle: "Low-power NAS build for 2026",
        metaSummary: """
        ## Original post
        The Discourse team merged the separate **New** and **Unread** lists into one *unified new view*, \
        with tabs to narrow it to new topics or new replies. It is on by default for new sites and \
        opt-in for existing ones.

        ## What people are saying
        - **Most like it**: one place to catch up, and the counts in the sidebar finally match.
        - **Keyboard users** asked for a shortcut to switch tabs; `g n` still opens the view.
        - **Admins** want a per-group default so staff can keep the old lists for a while.

        ## Tips from the thread
        1. Enable it under *Admin → Settings → experimental new new view groups* first.
        2. Tell members that “Dismiss” now clears both topics and replies.

        > “It took a day to get used to, now I can’t go back.” — a site admin

        Settings keys mentioned:

        ```text
        experimental_new_new_view_groups
        ```

        See the [announcement](https://meta.discourse.org/t/introducing-the-unified-new-view-for-the-topic-list/404728) for screenshots.
        """,
        metaChat: [
            (.user, "Can I roll it out to staff first?"),
            (.assistant, "Yes. Add your **staff** group to `experimental_new_new_view_groups`; everyone else keeps the separate New and Unread lists until you add more groups.")
        ],
        markdownEndpointsSummary: "## Summary\nAppending `.md` to topic list and topic URLs now returns Markdown — handy for tools and AI assistants.",
        sidebarSummary: "## Summary\nAn experimental sidebar lets each user choose sections and links.",
        streamSummary: """
        ## Problem
        Since the **2.4 firmware update**, prints longer than about six hours show *layer shifts* \
        partway up, while short prints come out fine.

        ## Workarounds reported
        - Lower the **travel speed** by 20–30%.
        - Re-tension the belts, then re-run the calibration.
        - Rolling back to 2.3 helps some, but not everyone.

        ## Status
        The firmware maintainers confirmed the report; no fix date yet.
        """,
        streamChat: [
            (.user, "Which workaround works most often?"),
            (.assistant, "Lowering the travel speed is the one most people confirm. Re-tensioning the belts helped in **about a third** of replies."),
            (.user, "Did anyone hear back from the firmware maintainers?"),
            (.assistant, "Yes — a maintainer asked for print logs and said a fix is being tested. There is no release date in the thread yet.")
        ],
        stepperHeatSummary: "## Summary\nDrivers in enclosed printers hit thermal shutdown on long prints; a small fan on the board fixes it.",
        slicerPresetsSummary: "## Summary\nMembers keep their slicer presets in a shared folder so every machine prints the same way.",
        lowPowerNASSummary: "## Summary\nMembers compare low-power storage builds; most idle under 15 W with the disks spun down.",
        agentGoal: "What are people saying about layer shifts after the 2.4 firmware update?",
        agentSearchQuery: "layer shift firmware 2.4",
        agentSecondSearchQuery: "layer shift travel speed workaround",
        agentThoughts: [
            "Search for reports of the layer shifts.",
            "The main report thread.",
            "Overheating drivers can also skip steps.",
            "Look for confirmed workarounds.",
            "Check whether the other 2.4 change is related.",
            "Enough to answer."
        ],
        agentRunningStatus: "Searching “layer shift travel speed workaround”…",
        agentAnswer: { layerShifts, stepperHeat, fan in
            """
            People report the shifts mostly on **prints longer than six hours**, while short prints \
            come out fine ([Layer shifts after 2.4](\(layerShifts))). \
            The most confirmed workaround is to **lower the travel speed**; re-tensioning the belts \
            helps some members.

            A few replies link it to drivers overheating in enclosures \
            ([Stepper drivers overheating](\(stepperHeat))), but the fan that keeps \
            running after a print looks like a separate bug ([Cooling fan](\(fan))).

            - The maintainers asked for print logs; no fix date yet.
            - Rolling back to 2.3 does **not** reliably help.
            """
        },
        agentFollowUpQuestion: "Is it only on the larger printers?",
        agentFollowUpAnswer: "No — reports cover both the small and the large beds. Nobody reports it on resin printers.",
        olderGoal: "How do I roll out the unified new view gradually?",
        olderSearchQuery: "unified new view groups",
        olderAnswer: "Add groups to `experimental_new_new_view_groups` one at a time, starting with staff.",
        summaryRunningStatus: "Summarizing posts 41–60 of 68…",
        summaryStream: """
        ## Original post
        The Discourse team merged the separate **New** and **Unread** lists into one *unified new view*.

        ## What people are saying
        - **Most like it**: one place to catch up
        """,
        chatStreamingQuestion: "Does it change the keyboard shortcuts?",
        chatStreamingAnswer: "Only one: `g n` now opens the unified view, and"
    )
}

// MARK: - Simplified Chinese

extension SampleContent {
    static let simplifiedChinese = SampleContent(
        meta: ForumText(siteURL: "https://devs.example.com", name: "独立开发者社区"),
        makers: ForumText(siteURL: "https://community.example.org", name: "创客空间社区"),
        homeLab: ForumText(siteURL: "https://forum.example.net", name: "家庭实验室论坛"),
        trailRunners: ForumText(siteURL: "https://talk.example.com", name: "越野跑俱乐部"),
        bakers: ForumText(siteURL: "https://bakers.example.org", name: "酸种面包烘焙坊"),
        boardGames: ForumText(siteURL: "https://games.example.com", name: "桌游同好会"),
        boardGamesDescription: "规则答疑、新游测评和线下桌游聚会。",
        gardeners: ForumText(siteURL: "https://garden.example.net", name: "社区园丁"),
        gardenersDescription: "交换种子、搭建种植箱和规划菜地。",
        unifiedNewTitle: "话题列表推出统一的“新内容”视图",
        markdownEndpointsTitle: "论坛现在可以用 Markdown 格式获取话题列表和话题",
        sidebarTitle: "实验功能：可自定义的用户侧边栏",
        layerShiftsTitle: "2.4 固件更新后，长时间打印出现错层",
        stepperHeatTitle: "封闭式打印机的步进驱动过热",
        slicerPresetsTitle: "在多台打印机之间共享切片预设",
        fanAfterPrintTitle: "打印结束后散热风扇一直不停",
        lowPowerNASTitle: "2026 年低功耗 NAS 装机分享",
        metaSummary: """
        ## 原帖概要
        管理团队把原来分开的**新话题**和**未读**两个列表合并成一个*统一的“新内容”视图*，\
        并提供标签页，可以只看新话题或只看新回复。新站点默认开启，老站点可以自行选择开启。

        ## 大家怎么说
        - **多数人喜欢**：一个地方就能跟上所有进度，侧边栏的计数也终于对得上了。
        - **键盘用户**希望有切换标签页的快捷键；`g n` 仍然可以打开这个视图。
        - **管理员**希望能按用户组设置默认值，让工作人员先继续用旧列表一段时间。

        ## 帖子里的建议
        1. 先在*管理 → 设置 → experimental new new view groups* 中为部分用户组开启。
        2. 提醒成员：“忽略”现在会同时清除新话题和新回复。

        > “适应了一天，现在已经回不去了。” — 一位站点管理员

        帖子中提到的设置项：

        ```text
        experimental_new_new_view_groups
        ```

        截图见[公告帖](https://devs.example.com/t/introducing-the-unified-new-view-for-the-topic-list/404728)。
        """,
        metaChat: [
            (.user, "可以先只对工作人员开放吗？"),
            (.assistant, "可以。把 **staff** 用户组加到 `experimental_new_new_view_groups` 里即可；在你添加更多用户组之前，其他人仍然使用分开的“新话题”和“未读”列表。")
        ],
        markdownEndpointsSummary: "## 摘要\n在话题列表和话题的网址后面加上 `.md`，就会返回 Markdown 格式的内容，方便各类工具和 AI 助手读取。",
        sidebarSummary: "## 摘要\n一个实验性的侧边栏，每位用户都可以自己选择要显示的版块和链接。",
        streamSummary: """
        ## 问题
        自从 **2.4 固件更新**以后，打印时间超过六小时左右的模型会在中途出现*错层*，\
        而短时间的打印一切正常。

        ## 大家报告的解决办法
        - 把**空驶速度**降低 20–30%。
        - 重新张紧皮带，然后重新校准。
        - 回退到 2.3 对部分人有效，但并非所有人。

        ## 当前进展
        固件维护者已确认该问题，暂无修复时间。
        """,
        streamChat: [
            (.user, "哪种解决办法最管用？"),
            (.assistant, "降低空驶速度是最多人确认有效的办法。重新张紧皮带在**大约三分之一**的回复里有帮助。"),
            (.user, "固件维护者那边有回复吗？"),
            (.assistant, "有。一位维护者请大家提供打印日志，并表示修复正在测试中。帖子里目前还没有发布日期。")
        ],
        stepperHeatSummary: "## 摘要\n封闭式打印机长时间打印时，驱动芯片会因过热而保护性关断；在主板上加一个小风扇就能解决。",
        slicerPresetsSummary: "## 摘要\n成员们把切片预设放在共享文件夹里，让每台打印机的打印效果保持一致。",
        lowPowerNASSummary: "## 摘要\n成员们比较各自的低功耗存储方案；硬盘休眠时，多数机器的待机功耗低于 15 W。",
        agentGoal: "2.4 固件更新后出现错层，大家都怎么说？",
        agentSearchQuery: "错层 固件 2.4",
        agentSecondSearchQuery: "错层 空驶速度 解决办法",
        agentThoughts: [
            "先搜索关于错层的报告。",
            "这是主要的问题反馈帖。",
            "驱动过热也可能导致丢步。",
            "找找已经确认有效的解决办法。",
            "看看 2.4 的另一处改动是否相关。",
            "信息已经足够回答了。"
        ],
        agentRunningStatus: "正在搜索“错层 空驶速度 解决办法”…",
        agentAnswer: { layerShifts, stepperHeat, fan in
            """
            大家报告的错层主要出现在**打印时间超过六小时**的模型上，短时间打印则一切正常\
            （[2.4 更新后的错层问题](\(layerShifts))）。\
            被确认最多的解决办法是**降低空驶速度**；重新张紧皮带对部分成员也有帮助。

            有几条回复认为这与封闭机箱内的驱动过热有关\
            （[步进驱动过热](\(stepperHeat))），而打印结束后风扇一直转\
            看起来是另一个独立的问题（[散热风扇不停](\(fan))）。

            - 维护者已请大家提供打印日志，暂无修复时间。
            - 回退到 2.3 **并不能**稳定解决问题。
            """
        },
        agentFollowUpQuestion: "只有大尺寸的打印机会这样吗？",
        agentFollowUpAnswer: "不是。小尺寸和大尺寸热床的机型都有人报告。光固化打印机则没有人遇到。",
        olderGoal: "怎样逐步推出统一的“新内容”视图？",
        olderSearchQuery: "统一 新内容 视图 用户组",
        olderAnswer: "从工作人员开始，一次一个地把用户组加到 `experimental_new_new_view_groups` 中。",
        summaryRunningStatus: "正在总结第 41–60 楼（共 68 楼）…",
        summaryStream: """
        ## 原帖概要
        管理团队把原来分开的**新话题**和**未读**两个列表合并成一个*统一的“新内容”视图*。

        ## 大家怎么说
        - **多数人喜欢**：一个地方就能跟上
        """,
        chatStreamingQuestion: "这会改变键盘快捷键吗？",
        chatStreamingAnswer: "只改了一个：`g n` 现在会打开统一视图，而且"
    )
}

// MARK: - Traditional Chinese

extension SampleContent {
    static let traditionalChinese = SampleContent(
        meta: ForumText(siteURL: "https://devs.example.com", name: "獨立開發者社群"),
        makers: ForumText(siteURL: "https://community.example.org", name: "創客空間社群"),
        homeLab: ForumText(siteURL: "https://forum.example.net", name: "居家實驗室論壇"),
        trailRunners: ForumText(siteURL: "https://talk.example.com", name: "越野跑俱樂部"),
        bakers: ForumText(siteURL: "https://bakers.example.org", name: "酸種麵包烘焙社"),
        boardGames: ForumText(siteURL: "https://games.example.com", name: "桌遊同好會"),
        boardGamesDescription: "規則問答、新遊戲評測和桌遊聚會。",
        gardeners: ForumText(siteURL: "https://garden.example.net", name: "社區園丁"),
        gardenersDescription: "交換種子、架設種植箱和規劃菜園。",
        unifiedNewTitle: "話題列表推出統一的「新內容」檢視",
        markdownEndpointsTitle: "論壇現在可以用 Markdown 格式取得話題列表和話題",
        sidebarTitle: "實驗功能：可自訂的使用者側邊欄",
        layerShiftsTitle: "2.4 韌體更新後，長時間列印出現層偏移",
        stepperHeatTitle: "封閉式 3D 印表機的步進驅動器過熱",
        slicerPresetsTitle: "在多台印表機之間共用切片設定檔",
        fanAfterPrintTitle: "列印結束後散熱風扇一直轉個不停",
        lowPowerNASTitle: "2026 年低功耗 NAS 組裝分享",
        metaSummary: """
        ## 原文重點
        管理團隊把原本分開的**新話題**和**未讀**兩個列表合併成一個*統一的「新內容」檢視*，\
        並提供分頁，可以只看新話題或只看新回覆。新網站預設開啟，既有網站可以自行選擇開啟。

        ## 大家怎麼說
        - **多數人喜歡**：一個地方就能掌握所有進度，側邊欄的數字也終於對得上了。
        - **鍵盤使用者**希望有切換分頁的快速鍵；`g n` 仍然可以打開這個檢視。
        - **管理員**希望能依群組設定預設值，讓工作人員先繼續用舊列表一段時間。

        ## 討論串裡的建議
        1. 先在*管理 → 設定 → experimental new new view groups* 中為部分群組開啟。
        2. 提醒成員：「略過」現在會同時清除新話題和新回覆。

        > 「適應了一天，現在已經回不去了。」— 一位網站管理員

        討論中提到的設定項目：

        ```text
        experimental_new_new_view_groups
        ```

        截圖請見[公告](https://devs.example.com/t/introducing-the-unified-new-view-for-the-topic-list/404728)。
        """,
        metaChat: [
            (.user, "可以先只對工作人員開放嗎？"),
            (.assistant, "可以。把 **staff** 群組加到 `experimental_new_new_view_groups` 裡就行了；在你加入更多群組之前，其他人仍然使用分開的「新話題」和「未讀」列表。")
        ],
        markdownEndpointsSummary: "## 摘要\n在話題列表和話題的網址後面加上 `.md`，就會傳回 Markdown 格式的內容，方便各種工具和 AI 助理讀取。",
        sidebarSummary: "## 摘要\n一個實驗性的側邊欄，每位使用者都可以自行選擇要顯示的分類和連結。",
        streamSummary: """
        ## 問題
        自從 **2.4 韌體更新**之後，列印時間超過大約六小時的模型會在中途出現*層偏移*，\
        而短時間的列印一切正常。

        ## 大家回報的解決方法
        - 把**空移速度**降低 20–30%。
        - 重新調整皮帶張力，然後重新校正。
        - 退回 2.3 版對部分人有效，但並非每個人都適用。

        ## 目前進度
        韌體維護者已確認這個問題，尚未公布修正時間。
        """,
        streamChat: [
            (.user, "哪一種解決方法最有效？"),
            (.assistant, "降低空移速度是最多人確認有效的方法。重新調整皮帶張力在**大約三分之一**的回覆中有幫助。"),
            (.user, "韌體維護者那邊有回應嗎？"),
            (.assistant, "有。一位維護者請大家提供列印記錄，並表示修正正在測試中。討論串裡目前還沒有釋出日期。")
        ],
        stepperHeatSummary: "## 摘要\n封閉式印表機長時間列印時，驅動晶片會因過熱而觸發保護關閉；在主機板上加一顆小風扇就能解決。",
        slicerPresetsSummary: "## 摘要\n成員們把切片設定檔放在共用資料夾裡，讓每台印表機的列印結果保持一致。",
        lowPowerNASSummary: "## 摘要\n成員們比較各自的低功耗儲存方案；硬碟休眠時，多數機器的待機功耗低於 15 W。",
        agentGoal: "2.4 韌體更新後出現層偏移，大家怎麼說？",
        agentSearchQuery: "層偏移 韌體 2.4",
        agentSecondSearchQuery: "層偏移 空移速度 解決方法",
        agentThoughts: [
            "先搜尋關於層偏移的回報。",
            "這是主要的問題回報討論串。",
            "驅動器過熱也可能造成失步。",
            "找找已經確認有效的解決方法。",
            "看看 2.4 的另一項變更是否有關。",
            "資訊已經足夠回答了。"
        ],
        agentRunningStatus: "正在搜尋「層偏移 空移速度 解決方法」…",
        agentAnswer: { layerShifts, stepperHeat, fan in
            """
            大家回報的層偏移主要出現在**列印時間超過六小時**的模型上，短時間列印則一切正常\
            （[2.4 更新後的層偏移](\(layerShifts))）。\
            最多人確認有效的解決方法是**降低空移速度**；重新調整皮帶張力對部分成員也有幫助。

            有幾則回覆認為這和封閉機殼內的驅動器過熱有關\
            （[步進驅動器過熱](\(stepperHeat))），而列印結束後風扇一直轉，\
            看起來是另一個獨立的問題（[散熱風扇不停](\(fan))）。

            - 維護者已請大家提供列印記錄，尚未公布修正時間。
            - 退回 2.3 版**並不能**穩定解決問題。
            """
        },
        agentFollowUpQuestion: "只有大尺寸的印表機會這樣嗎？",
        agentFollowUpAnswer: "不是。小尺寸和大尺寸熱床的機型都有人回報。光固化印表機則沒有人遇到。",
        olderGoal: "要怎麼逐步推出統一的「新內容」檢視？",
        olderSearchQuery: "統一 新內容 檢視 群組",
        olderAnswer: "從工作人員開始，一次一個地把群組加到 `experimental_new_new_view_groups` 中。",
        summaryRunningStatus: "正在摘要第 41–60 則貼文（共 68 則）…",
        summaryStream: """
        ## 原文重點
        管理團隊把原本分開的**新話題**和**未讀**兩個列表合併成一個*統一的「新內容」檢視*。

        ## 大家怎麼說
        - **多數人喜歡**：一個地方就能掌握
        """,
        chatStreamingQuestion: "這會改變鍵盤快速鍵嗎？",
        chatStreamingAnswer: "只改了一個：`g n` 現在會打開統一檢視，而且"
    )
}
#endif
