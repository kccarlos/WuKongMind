import Foundation

#if DEBUG
/// Localized, completely invented non-forum web pages and Agent copy for
/// `AppStoreScreenshotTests` (en-US, zh-Hans, zh-Hant).
///
/// Every site, author, title, and body is fictional; no real people, real
/// brands, or forum content appear anywhere in this file.
struct StoreScreenshotContent {
    struct TabPage {
        let url: URL
        let html: String
    }

    let languageCode: String
    let articleURL: URL
    let articleHTML: String
    let extraTabs: [TabPage]

    let darkPrompt: String
    let darkReply: String
    let saveScriptPrompt: String
    let saveScriptName: String
    let saveScriptReply: String
    let summarizePrompt: String
    let summarizeReadAloudText: String
    let summarizeReply: String

    static var current: StoreScreenshotContent {
        switch AppLanguage.current {
        case "zh-Hans": simplifiedChinese
        case "zh-Hant": traditionalChinese
        default: english
        }
    }

    private static func makeArticleHTML(
        lang: String,
        masthead: String,
        section: String,
        headline: String,
        byline: String,
        lead: String,
        paragraphs: [String],
        pullQuote: String,
        sidebarTitle: String,
        sidebarBody: String,
        sidebarCTA: String
    ) -> String {
        let bodyHTML = paragraphs.map { "<p>\($0)</p>" }.joined(separator: "\n")
        return """
        <!doctype html>
        <html lang="\(lang)">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(headline)</title>
          <style>
            * { box-sizing: border-box; }
            body {
              margin: 0;
              font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "PingFang TC", sans-serif;
              background: #fafaf8;
              color: #1c1917;
              line-height: 1.6;
            }
            header.masthead {
              display: flex;
              align-items: baseline;
              justify-content: space-between;
              padding: 14px 20px;
              border-bottom: 2px solid #1c1917;
              background: #ffffff;
            }
            .brand {
              font-size: 20px;
              font-weight: 800;
              letter-spacing: -0.02em;
            }
            .section-tag {
              font-size: 12px;
              font-weight: 700;
              text-transform: uppercase;
              letter-spacing: 0.08em;
              color: #0d9488;
            }
            .layout {
              display: flex;
              flex-wrap: wrap;
              gap: 20px;
              padding: 20px;
              max-width: 920px;
              margin: 0 auto;
            }
            article {
              flex: 2 1 300px;
            }
            h1 {
              margin: 0 0 8px;
              font-size: 26px;
              line-height: 1.22;
              letter-spacing: -0.02em;
            }
            .byline {
              font-size: 13px;
              color: #57534e;
              margin-bottom: 16px;
            }
            .lead {
              font-size: 17px;
              font-weight: 500;
              color: #292524;
              margin-bottom: 14px;
            }
            p {
              font-size: 16px;
              margin: 0 0 14px;
            }
            blockquote {
              margin: 16px 0;
              padding: 10px 16px;
              border-left: 3px solid #0d9488;
              background: #f0fdfa;
              color: #134e4a;
              font-size: 15px;
              border-radius: 0 8px 8px 0;
            }
            aside.sidebar {
              flex: 1 1 200px;
              align-self: flex-start;
              padding: 16px;
              border-radius: 14px;
              background: #fff7ed;
              border: 1.5px solid #fdba74;
            }
            aside.sidebar h3 {
              margin: 0 0 6px;
              font-size: 15px;
              color: #9a3412;
            }
            aside.sidebar p {
              font-size: 14px;
              color: #7c2d12;
              margin: 0 0 12px;
            }
            .cta {
              display: inline-block;
              padding: 8px 14px;
              border-radius: 999px;
              background: #ea580c;
              color: #ffffff;
              font-size: 13px;
              font-weight: 600;
              text-decoration: none;
            }
          </style>
        </head>
        <body>
          <header class="masthead">
            <span class="brand">\(masthead)</span>
            <span class="section-tag">\(section)</span>
          </header>
          <div class="layout">
            <article id="main-article">
              <h1>\(headline)</h1>
              <div class="byline">\(byline)</div>
              <p class="lead">\(lead)</p>
              \(bodyHTML)
              <blockquote>\(pullQuote)</blockquote>
            </article>
            <aside class="sidebar" id="newsletter-aside">
              <h3>\(sidebarTitle)</h3>
              <p>\(sidebarBody)</p>
              <span class="cta">\(sidebarCTA)</span>
            </aside>
          </div>
        </body>
        </html>
        """
    }

    private static func makeCardPageHTML(
        lang: String,
        title: String,
        kicker: String,
        accent: String,
        tint: String,
        summary: String,
        rows: [(String, String)]
    ) -> String {
        let rowsHTML = rows.map { key, value in
            "<div class=\"row\"><span class=\"k\">\(key)</span><span class=\"v\">\(value)</span></div>"
        }.joined(separator: "\n")
        return """
        <!doctype html>
        <html lang="\(lang)">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(title)</title>
          <style>
            body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "PingFang TC", sans-serif; background: #ffffff; color: #1e293b; }
            .hero { padding: 28px 20px 22px; background: \(tint); border-bottom: 3px solid \(accent); }
            .kicker { font-size: 12px; font-weight: 700; letter-spacing: 0.08em; text-transform: uppercase; color: \(accent); margin-bottom: 8px; }
            h1 { margin: 0 0 10px; font-size: 26px; line-height: 1.2; color: #0f172a; }
            .summary { margin: 0; font-size: 16px; line-height: 1.5; color: #334155; }
            main { padding: 18px 20px; }
            .row { display: flex; justify-content: space-between; padding: 12px 0; border-bottom: 1px solid #e2e8f0; font-size: 15px; }
            .k { color: #64748b; }
            .v { font-weight: 600; color: #0f172a; }
          </style>
        </head>
        <body>
          <div class="hero">
            <div class="kicker">\(kicker)</div>
            <h1>\(title)</h1>
            <p class="summary">\(summary)</p>
          </div>
          <main>\(rowsHTML)</main>
        </body>
        </html>
        """
    }
}

extension StoreScreenshotContent {
    static let english = StoreScreenshotContent(
        languageCode: "en",
        articleURL: URL(string: "https://chronicle.example.org/story/quiet-grids")!,
        articleHTML: makeArticleHTML(
            lang: "en",
            masthead: "Harborline Chronicle",
            section: "Cities & Energy",
            headline: "How Neighborhood Microgrids Keep Lights On After Storms",
            byline: "By Clara Lin · 5 min read",
            lead: "Across three coastal towns, shared rooftop batteries and block-level inverters kept clinics, bakeries, and transit shelters running through last winter's outages.",
            paragraphs: [
                "When transmission lines drop during a gale, conventional solar panels shut down for safety. A neighborhood microgrid isolates itself cleanly in milliseconds, balancing rooftop generation with a shared battery cabinet at the corner substation.",
                "Engineers in Harborview measured a 94 percent uptime rate across fourteen blocks during two consecutive storm nights, while cutting peak evening demand on the regional grid by nearly a third."
            ],
            pullQuote: "“The best resilience upgrade is the one residents barely notice until the streetlamps stay bright.”",
            sidebarTitle: "Daily Briefing & Partner Offers",
            sidebarBody: "Subscribe for breaking alerts, sponsored webinars, and weekly city policy digests.",
            sidebarCTA: "Sign up free"
        ),
        extraTabs: [
            TabPage(
                url: URL(string: "https://trails.example.org/guides/coastal-ridge")!,
                html: makeCardPageHTML(
                    lang: "en",
                    title: "Coastal Ridge Loop",
                    kicker: "Trail Guide",
                    accent: "#15803d",
                    tint: "#f0fdf4",
                    summary: "A windswept bluff path overlooking cedar coves, tide pools, and the old stone lighthouse.",
                    rows: [("Distance", "8.4 km"), ("Elevation", "+310 m"), ("Season", "Spring – Autumn"), ("Surface", "Packed gravel")]
                )
            ),
            TabPage(
                url: URL(string: "https://atlas.example.org/plants/alpine-ferns")!,
                html: makeCardPageHTML(
                    lang: "en",
                    title: "Botanical Field Atlas",
                    kicker: "Flora Notes",
                    accent: "#b45309",
                    tint: "#fffbeb",
                    summary: "Illustrated leaf keys for coastal ferns, moss cushions, and shaded granite ravines.",
                    rows: [("Family", "Polypodiaceae"), ("Habitat", "Damp shade"), ("Frond length", "25 – 60 cm"), ("Distribution", "Temperate coast")]
                )
            ),
            TabPage(
                url: URL(string: "https://ferries.example.org/schedule/harbor-line")!,
                html: makeCardPageHTML(
                    lang: "en",
                    title: "Harbor Ferry Timetable",
                    kicker: "Transit",
                    accent: "#1d4ed8",
                    tint: "#eff6ff",
                    summary: "Direct passenger crossings between Pier 4 and North Cove with bike racks on every deck.",
                    rows: [("First boat", "06:15"), ("Peak headway", "15 min"), ("Crossing time", "18 min"), ("Last boat", "22:45")]
                )
            )
        ],
        darkPrompt: "Make it dark and hide the sidebar",
        darkReply: "Applied a dark reading palette (`#0f172a` background, `#e2e8f0` text) and hid the newsletter sidebar.",
        saveScriptPrompt: "Keep this dark theme and clean layout on every visit",
        saveScriptName: "Dark reader & clean layout",
        saveScriptReply: "Saved **Dark reader & clean layout** for `chronicle.example.org`.",
        summarizePrompt: "Summarize this page and read it aloud",
        summarizeReadAloudText: "How Neighborhood Microgrids Keep Lights On After Storms. Three coastal towns paired rooftop solar with shared block batteries so clinics and transit shelters stay powered during outages. Harborview recorded 94 percent uptime across fourteen blocks during winter storms and cut peak evening grid demand by nearly a third.",
        summarizeReply: """
        ## Summary
        - **Islanding in milliseconds:** Neighborhood microgrids disconnect safely during storms so rooftop solar and shared block batteries keep clinics, bakeries, and transit shelters running.
        - **Measured results:** Harborview saw **94% uptime** across 14 blocks over two storm nights.
        - **Everyday benefit:** Shared corner storage also reduced peak evening demand on the regional grid by nearly a third.
        """
    )

    static let simplifiedChinese = StoreScreenshotContent(
        languageCode: "zh-Hans",
        articleURL: URL(string: "https://chronicle.example.org/story/quiet-grids")!,
        articleHTML: makeArticleHTML(
            lang: "zh-Hans",
            masthead: "海港纪事 · 城市",
            section: "能源与设计",
            headline: "社区微电网如何在风暴后保持供电",
            byline: "林清禾 · 阅读约 5 分钟",
            lead: "在三座沿海小镇，共享屋顶储能电池与街区级逆变器让诊所、面包店和候车亭在去冬停电期间照常运转。",
            paragraphs: [
                "大风导致主干线路断电时，传统屋顶光伏会出于安全自动停机。社区微电网能在毫秒内平稳切换为孤岛运行，将屋顶发电与街角变电站的共享储能柜动态平衡。",
                "海湾镇工程师在连续两夜风暴中测得 14 个街区的供电可用率达到 94%，同时将区域电网晚高峰负荷降低了近三分之一。"
            ],
            pullQuote: "“最好的韧性升级，是居民平时几乎察觉不到，直到风暴夜里路灯依然明亮。”",
            sidebarTitle: "每日早报与合作推荐",
            sidebarBody: "订阅即时快讯、合作线上讲座以及每周城市政策精选。",
            sidebarCTA: "免费订阅"
        ),
        extraTabs: [
            TabPage(
                url: URL(string: "https://trails.example.org/guides/coastal-ridge")!,
                html: makeCardPageHTML(
                    lang: "zh-Hans",
                    title: "海岸山脊环线",
                    kicker: "徒步指南",
                    accent: "#15803d",
                    tint: "#f0fdf4",
                    summary: "沿着海风轻拂的悬崖步道前行，俯瞰雪松海湾、潮汐池与老石灯塔。",
                    rows: [("全程距离", "8.4 公里"), ("累计爬升", "+310 米"), ("推荐季节", "春季至秋季"), ("路面类型", "压实碎石")]
                )
            ),
            TabPage(
                url: URL(string: "https://atlas.example.org/plants/alpine-ferns")!,
                html: makeCardPageHTML(
                    lang: "zh-Hans",
                    title: "植物野外图鉴",
                    kicker: "植物笔记",
                    accent: "#b45309",
                    tint: "#fffbeb",
                    summary: "沿海蕨类、苔藓垫与阴湿花岗岩峡谷植物的叶形检索说明。",
                    rows: [("所属科", "水龙骨科"), ("生境", "阴湿林下"), ("叶片长度", "25 – 60 厘米"), ("分布", "温带海岸")]
                )
            ),
            TabPage(
                url: URL(string: "https://ferries.example.org/schedule/harbor-line")!,
                html: makeCardPageHTML(
                    lang: "zh-Hans",
                    title: "海湾渡轮时刻表",
                    kicker: "公共交通",
                    accent: "#1d4ed8",
                    tint: "#eff6ff",
                    summary: "4 号码头直达北湾的客运渡轮，每班甲板均配有自行车架。",
                    rows: [("首班船", "06:15"), ("高峰间隔", "15 分钟"), ("航行时间", "18 分钟"), ("末班船", "22:45")]
                )
            )
        ],
        darkPrompt: "改成深色模式并隐藏侧边栏",
        darkReply: "已应用深色阅读配色（`#0f172a` 背景、`#e2e8f0` 文字），并隐藏了侧边栏订阅卡片。",
        saveScriptPrompt: "每次访问都保持深色主题和精简布局",
        saveScriptName: "深色阅读与精简布局",
        saveScriptReply: "已为 `chronicle.example.org` 保存 **深色阅读与精简布局**。",
        summarizePrompt: "总结这个页面并朗读给我听",
        summarizeReadAloudText: "社区微电网如何在风暴后保持供电。三座沿海小镇将屋顶光伏与街区共享储能电池结合，让诊所和候车亭在停电期间持续供电。海湾镇在连续两夜风暴中实现 94% 供电可用率，并将晚高峰负荷降低近三分之一。",
        summarizeReply: """
        ## 摘要
        - **毫秒级切换：** 社区微电网在风暴停电时平稳进入孤岛运行，让屋顶光伏与街区共享电池持续为诊所、面包店和候车亭供电。
        - **实测表现：** 海湾镇 14 个街区在连续两夜风暴中达到 **94% 可用率**。
        - **日常收益：** 街角共享储能还将区域电网晚高峰负荷降低了近三分之一。
        """
    )

    static let traditionalChinese = StoreScreenshotContent(
        languageCode: "zh-Hant",
        articleURL: URL(string: "https://chronicle.example.org/story/quiet-grids")!,
        articleHTML: makeArticleHTML(
            lang: "zh-Hant",
            masthead: "海港紀事 · 城市",
            section: "能源與設計",
            headline: "社區微電網如何在風暴後維持供電",
            byline: "林清禾 · 閱讀約 5 分鐘",
            lead: "在三座沿海小鎮，共享屋頂儲能電池與街區級逆變器讓診所、麵包店與候車亭在去冬停電期間照常運作。",
            paragraphs: [
                "強風導致主幹線路斷電時，傳統屋頂光電會基於安全自動停機。社區微電網能在毫秒內平穩切換為孤島運轉，將屋頂發電與街角變電站的共享儲能櫃動態平衡。",
                "海灣鎮工程師在連續兩夜風暴中測得 14 個街區的供電可用率達 94%，同時將區域電網晚間尖峰負載降低了近三分之一。"
            ],
            pullQuote: "「最好的韌性升級，是居民平時幾乎察覺不到，直到風暴夜裡路燈依然明亮。」",
            sidebarTitle: "每日早報與合作推薦",
            sidebarBody: "訂閱即時快訊、合作線上講座與每週城市政策精選。",
            sidebarCTA: "免費訂閱"
        ),
        extraTabs: [
            TabPage(
                url: URL(string: "https://trails.example.org/guides/coastal-ridge")!,
                html: makeCardPageHTML(
                    lang: "zh-Hant",
                    title: "海岸山脊環線",
                    kicker: "健行指南",
                    accent: "#15803d",
                    tint: "#f0fdf4",
                    summary: "沿著海風輕拂的懸崖步道前行，俯瞰雪松海灣、潮汐池與老石燈塔。",
                    rows: [("全程距離", "8.4 公里"), ("累計爬升", "+310 公尺"), ("推薦季節", "春季至秋季"), ("路面類型", "壓實碎石")]
                )
            ),
            TabPage(
                url: URL(string: "https://atlas.example.org/plants/alpine-ferns")!,
                html: makeCardPageHTML(
                    lang: "zh-Hant",
                    title: "植物野外圖鑑",
                    kicker: "植物筆記",
                    accent: "#b45309",
                    tint: "#fffbeb",
                    summary: "沿海蕨類、苔蘚墊與陰濕花崗岩峽谷植物的葉形檢索說明。",
                    rows: [("所屬科", "水龍骨科"), ("生境", "陰濕林下"), ("葉片長度", "25 – 60 公分"), ("分布", "溫帶海岸")]
                )
            ),
            TabPage(
                url: URL(string: "https://ferries.example.org/schedule/harbor-line")!,
                html: makeCardPageHTML(
                    lang: "zh-Hant",
                    title: "海灣渡輪時刻表",
                    kicker: "大眾運輸",
                    accent: "#1d4ed8",
                    tint: "#eff6ff",
                    summary: "4 號碼頭直達北灣的客運渡輪，每班甲板均配有自行車架。",
                    rows: [("首班船", "06:15"), ("尖峰間隔", "15 分鐘"), ("航行時間", "18 分鐘"), ("末班船", "22:45")]
                )
            )
        ],
        darkPrompt: "改成深色模式並隱藏側邊欄",
        darkReply: "已套用深色閱讀配色（`#0f172a` 背景、`#e2e8f0` 文字），並隱藏了側邊欄訂閱卡片。",
        saveScriptPrompt: "每次造訪都保持深色主題與精簡版面",
        saveScriptName: "深色閱讀與精簡版面",
        saveScriptReply: "已為 `chronicle.example.org` 儲存 **深色閱讀與精簡版面**。",
        summarizePrompt: "摘要這個頁面並朗讀給我聽",
        summarizeReadAloudText: "社區微電網如何在風暴後維持供電。三座沿海小鎮將屋頂光電與街區共享儲能電池結合，讓診所與候車亭在停電期間持續供電。海灣鎮在連續兩夜風暴中實現 94% 供電可用率，並將晚間尖峰負載降低近三分之一。",
        summarizeReply: """
        ## 摘要
        - **毫秒級切換：** 社區微電網在風暴停電時平穩進入孤島運轉，讓屋頂光電與街區共享電池持續為診所、麵包店與候車亭供電。
        - **實測表現：** 海灣鎮 14 個街區在連續兩夜風暴中達到 **94% 可用率**。
        - **日常收益：** 街角共享儲能也將區域電網晚間尖峰負載降低了近三分之一。
        """
    )
}
#endif
