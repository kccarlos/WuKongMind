# One loop comparison

Old Research and the new Agent on the confirmed question set ([one-loop-questions.md](one-loop-questions.md)), recorded by `OneLoopComparisonTests` ([design](design-one-loop.md#comparison-test)). Token counts the provider didn't report show "n/a".

| | |
|---|---|
| Date | 2026-11-14 |
| Agent model (both loops) | Anthropic claude-haiku-5-5 |
| Summary model (both sides) | Anthropic claude-haiku-5-5 |
| App commit | 3623857 |
| Fixture forums | discourse: https://meta.appinn.net<br>hackernews: https://news.ycombinator.com<br>wordpress: https://www.doctorofcredit.com |
| Snapshot misses | D1: 9, D2: 0, D3: 0, D4: 0, D5: 10, H1: 0, H2: 0, H3: 0, H4: 0, H5: 1, W1: 2, W2: 3, W3: 30, W4: 3, W5: 8 |
| Text Agent's tools on forum pages | 25 tools, 6626 tokens of definitions |

**Model rule.** The owner's standing rule allows one Anthropic model only: `claude-haiku-5-5`. So the design's default ("the owner's current Agent model") is replaced here: **both loops and the summaries on both sides ran on `claude-haiku-5-5`**, the same model on each side. The owner's own Agent model may behave differently (see Not proven).

## Totals

| Kind | Side | Loop tokens in | Loop tokens out | Summary tokens in | Summary tokens out | Tool calls | Topics read | Median time |
|---|---|---|---|---|---|---|---|---|
| discourse | Old Research | 144164 | 17117 | 17761 | 4239 | 17 | 8 | 31.0 s |
| discourse | New Agent | 194251 | 11618 | 38304 | 20793 | 25 | 14 | 63.3 s |
| hackernews | Old Research | 142072 | 14344 | 0 | 0 | 12 | 6 | 16.9 s |
| hackernews | New Agent | 184583 | 9176 | 29434 | 9966 | 16 | 7 | 17.3 s |
| wordpress | Old Research | 309014 | 17599 | 16733 | 2443 | 22 | 7 | 43.3 s |
| wordpress | New Agent | 531876 | 15961 | 0 | 0 | 33 | 10 | 30.4 s |
| All | Old Research | 595250 | 49060 | 34494 | 6682 | 51 | 21 | 25.2 s |
| All | New Agent | 910710 | 36755 | 67738 | 30759 | 74 | 31 | 28.3 s |

## Questions

### D1

**Question:** 这里的网友怎么看家用 NAS（比如群晖）值不值得买？

**Starting page:** https://meta.appinn.net/

**Snapshot misses:** https://meta.appinn.net/search.json?q=NAS%20Synology, https://meta.appinn.net/t/7930.json, https://meta.appinn.net/raw/7930?page=1, https://meta.appinn.net/t/70196.json, https://meta.appinn.net/raw/70196?page=1, https://meta.appinn.net/t/75519.json, https://meta.appinn.net/raw/75519?page=1, https://meta.appinn.net/t/87972.json, https://meta.appinn.net/raw/87972?page=1

#### Old Research

**Tool calls:**

1. `search_forum` query=NAS 群晖 值得买 → 2 topics
1. `search_forum` query=NAS 家用 值不值 → 0 topics
1. `search_forum` query=NAS → 50 topics
1. `read_topic` topic_id=47457 → Read 15 posts
1. `summarize_topic` topic_id=48996 → Summarized 111 posts

**Answer:**

## 结论

论坛没有一致的结论，但讨论大致指向：**NAS 值不值，取决于你是否有明确的用途，并愿意持续维护。** 很多人买了之后用几天就闲置。

## 支持的观点

- **有实际用途时价值明显。** 一位用户把 NAS 用作家庭媒体中心（Plex 看 4K/杜比影片）、照片备份（配合 Pho、PhotoPrism）、NextCloud 工作网盘、Home Assistant 智能家居和虚拟机，并称它“不只是一个玩具”。[我的NAS在生活中的"重要"作用](https://meta.appinn.net/t/topic/47457)
- **照片备份是最常见的入门理由。** 有用户因为小米云同步删除导致本地照片被连带删除，于是想自建存储。[有什么比较低成本的NAS？](https://meta.appinn.net/t/topic/48996)
- **便宜的入门方案也能用。** 同一讨论里的分层建议：约 150 元以内的盒子（如斐讯 N1）适合约 1T 数据；150–1000 元的二手电脑、工控机或软路由适合 1–4T；1000 元以上可考虑成品 NAS 或 DIY。（来源为论坛摘要，见下文）

## 怀疑或反对的观点

- **时间成本高。** 有用户认为，真正的前提是“有时间看电影”，并且很多人并不需要创造这种需求。[我的NAS在生活中的"重要"作用 #4](https://meta.appinn.net/t/topic/47457/4)
- **流媒体替代了部分用途。** 有用户认为现在看影视多用在线平台，NAS 的家用场景越来越少，主要剩下照片存储，而存照片的人通常用 iCloud 之类的服务就够了，因此 NAS 注定是小众领域。[我的NAS在生活中的"重要"作用 #15](https://meta.appinn.net/t/topic/47457/15)
- **同步不等于备份。** 云同步会传播删除操作。[有什么比较低成本的NAS？](https://meta.appinn.net/t/topic/48996)的摘要建议，重要照片应使用单向或只读同步，或带版本保留的备份工具。
- **隐性成本不低。** 电费、发热、噪音和占地都要算。有用户实测 J4125 待机约 8W，而老电脑待机超过 100W，但也有人认为每年几十到一百元电费对多数人可以忽略。（同上，摘要）
- **单盘外接方案风险较大。** 讨论中提到，外接硬盘如果供电不足或数据线松动，可能出现数据错误。分享者回应说，应通过带外接供电的 USB HUB 和合理备份来规避。（同上，摘要）

## 远程访问与安全

- 出门访问家中设备，不一定需要公网 IP。有用户建议用 Tailscale 或 ZeroTier。[我的NAS在生活中的"重要"作用 #6](https://meta.appinn.net/t/topic/47457/6)
- 论坛对 frp 的安全性有争议，有人推荐 WireGuard 配合 VPS。（来源：有什么比较低成本的NAS？摘要）

## 需要注意

- 我只读取了 47457 的全文，48996 的内容来自论坛的 AI 摘要，没有逐条核对原帖。
- 47457 的楼主是 Pho 的开发者，文章带有推广性质，作者本人也在首段说明这一点。
- 论坛没有给出黑群晖与正版群晖之间的明确比较，也没有给出统一的购买建议。
- 小米云删除同步是设计还是 Bug，论坛没有统一结论。

## 参考主题

- [我的NAS在生活中的"重要"作用](https://meta.appinn.net/t/topic/47457)
- [有什么比较低成本的NAS？](https://meta.appinn.net/t/topic/48996)

**Citations:** 5, 5 a thread in the snapshot

- https://meta.appinn.net/t/topic/47457: thread in the snapshot
- https://meta.appinn.net/t/topic/48996: thread in the snapshot
- https://meta.appinn.net/t/topic/47457/4: thread in the snapshot
- https://meta.appinn.net/t/topic/47457/15: thread in the snapshot
- https://meta.appinn.net/t/topic/47457/6: thread in the snapshot

**Tokens:** loop 32319 in / 2938 out · summary 17761 in / 4239 out

#### New Agent

**Tool calls:**

1. `search_forum` "NAS 群晖 值得买" → 2 threads
1. `search_forum` "NAS Synology" → 38 threads
1. `summarize_topic` topic 7930 → 我折腾过的群晖总结
1. `summarize_topic` topic 70196 → 离了个大谱：群晖，只有自家硬盘才能兼容并提供全方位的功能和支持
1. `summarize_topic` topic 75519 → 群晖认怂！用户狂喷半年后，最新 DSM 7.3 终于低头：取消专用硬盘限制
1. `summarize_topic` topic 87972 → 最纯粹的 NAS：直接上 ZFS

**Answer:**

论坛里的看法比较分化，没有一边倒的结论。大致可以归纳成下面几点。

**支持买群晖的理由**
- **稳定、省心、省电。** 有网友认为官方机型稳定、功耗低，更新及时，还有厂商支持。[群晖 vs 黑群总结](https://meta.appinn.net/t/topic/7930)
- **适合不想折腾的人。** 有用户说自己买群晖就是因为不想折腾。同一篇帖子里也提到，黑群性能同价位可能更好，但需要破解，升级慢，功耗也可能更高。
- **企业和专业场景。** 有人认为群晖在文件管理、数据同步、安全和稳定性方面仍然专业，企业用户可能仍会选择它。[DSM 7.3 取消硬盘限制](https://meta.appinn.net/t/topic/75519)

**对群晖的担忧**
- **硬盘限制。** 2025 年起的 Plus 新机型，对非群晖认证硬盘只给有限支持。自动固件更新、寿命分析、卷级去重等功能只对群晖硬盘开放。已有机型和迁移硬盘不受影响。网友也讨论了绕过方法，但没有确认长期是否可行。[群晖上线 Plus 限制](https://meta.appinn.net/t/topic/70196)
- **DSM 7.3 取消了专用硬盘限制。** 但 SSD 存储池仍需专用或认证盘。帖子里有人说，新版本也可能砍掉驱动或功能，比如网卡和硬件解码，所以升级前要看更新说明。[DSM 7.3 取消硬盘限制](https://meta.appinn.net/t/topic/75519)
- **家庭用户体验。** 原帖作者认为群晖对家庭用户重视不足，Video Station 被砍，相册功能也落后于飞牛相册和 Immich 等产品。[DSM 7.3 取消硬盘限制](https://meta.appinn.net/t/topic/75519)
- **价格。** 有用户认为群晖价格高、生态绑定强，并提到硬盘涨价让入门门槛更高。

**替代方案**
- 飞牛 OS、绿联、OpenMediaVault（OMV）、TrueNAS 都有人提到。有人用飞牛做影视 NAS，但认为其他功能还不成熟，也有人换用绿联做媒体播放。
- 另一派认为，家用不一定需要 NAS 系统，可以用 Debian + OpenZFS + Samba 自己搭，配置存在硬盘上，重装系统后还能恢复。但这需要一定动手能力。[最纯粹的 NAS：直接上 ZFS](https://meta.appinn.net/t/topic/87972)

**关于 RAID 和备份**
- 论坛里的共识是，RAID 不能替代备份。RAID 防的是硬盘故障和停机，防不了误删、勒索软件或整机事故。至少要留一份异地或离线备份。[最纯粹的 NAS：直接上 ZFS](https://meta.appinn.net/t/topic/87972)

**我的判断（基于以上讨论）**
- 如果你想省心、稳定，又主要存照片、视频和文件，群晖仍然是论坛里较稳妥的选择，但要接受硬盘限制和较高价格。
- 如果你愿意折腾，或主要看重影视和媒体功能，可以考虑飞牛、绿联或自建方案。
- 无论买哪个，都要做好备份，不要把 NAS 当成唯一的数据副本。

需要说明的是，这些讨论的时间跨度从 2019 年到 2026 年，很多是个人经验，不能代表所有人的情况。论坛也没有确认硬盘限制绕过方法是否长期有效，以及 DSM 7.3 实际发布后的兼容性。如果你告诉我预算、用途（比如影视、照片还是数据备份）和硬盘数量，我可以再帮你查更有针对性的讨论。

**Citations:** 4, 4 a thread in the snapshot

- https://meta.appinn.net/t/topic/7930: thread in the snapshot
- https://meta.appinn.net/t/topic/75519: thread in the snapshot
- https://meta.appinn.net/t/topic/70196: thread in the snapshot
- https://meta.appinn.net/t/topic/87972: thread in the snapshot

**Tokens:** loop 40798 in / 2016 out · summary 13872 in / 8553 out

| Owner verdict | |
|---|---|
| New better, same, or worse | same |
| Note | About equal; new drifts to Synology disk-policy news. |

### D2

**Question:** 在帖子「SumatraPDF Plus 增强版：完美中文排版、全渲染暗黑模式、双击查词、大文件加速」（https://meta.appinn.net/t/87128）里，有网友建议作者参考哪个暗黑主题，另一位网友更喜欢哪种黑色，作者又是怎么回应的？

**Starting page:** https://meta.appinn.net/t/87128

#### Old Research

**Tool calls:**

1. `read_topic` topic_id=87128 → Read 352 posts

**Answer:**

## 结论

1. **建议的暗黑主题：Darcula（Dracula）。** 网友 VictoryRoad 认为纯黑背景“还是有点费眼”，建议参考 Darcula 主题，称其“暗灰/深紫色”比单纯黑色更舒服、更美观，并附上 draculatheme.com 链接（[帖子 #13](https://meta.appinn.net/t/topic/87128/13)）。

2. **另一位网友偏好的黑色：纯黑 #000000。** Phosphorite 表示 Dracula 对自己“太亮了”，更喜欢最初版本那种 #000000 纯黑，在 OLED 屏幕上几乎不发光（[帖子 #16](https://meta.appinn.net/t/topic/87128/16)）。

3. **作者的回应：**
   - 作者先表示“从善如流，已经改得差不多了”，并问“搞多个暗黑主题？会不会太臃肿？”（[帖子 #18](https://meta.appinn.net/t/topic/87128/18)）。
   - Phosphorite 建议：若只做一个暗色模式就定死，不必为了个别用户反复调整；若要调整，就要做好维护多个版本的准备（[帖子 #22](https://meta.appinn.net/t/topic/87128/22)）。
   - 作者随后表示“哪我追随我心，搞我认为合适的”（[帖子 #23](https://meta.appinn.net/t/topic/87128/23)），Phosphorite 回以“我辈一人，定则定矣”（[帖子 #24](https://meta.appinn.net/t/topic/87128/24)）。
   - 从帖子首楼的当前版本介绍看，最终提供了四种界面主题：Light-Warm、Light-White、Dark-Dracula 和 Dark-Black（[首楼](https://meta.appinn.net/t/topic/87128/1)）。这说明作者保留了 Dracula 风格，同时也有更深的黑色选项。

## 说明

- 论坛里没有明确写出作者“采纳了 Darcula 建议”或“为 Phosphorite 改成纯黑”。上述关于最终主题的结论，只能依据首楼的主题列表推断。
- 我只读取了该帖的部分内容（开头和较新的回复），未逐条核对中间的所有回复。

**Citations:** 7, 7 a thread in the snapshot

- https://meta.appinn.net/t/topic/87128/13: thread in the snapshot
- https://meta.appinn.net/t/topic/87128/16: thread in the snapshot
- https://meta.appinn.net/t/topic/87128/18: thread in the snapshot
- https://meta.appinn.net/t/topic/87128/22: thread in the snapshot
- https://meta.appinn.net/t/topic/87128/23: thread in the snapshot
- https://meta.appinn.net/t/topic/87128/24: thread in the snapshot
- https://meta.appinn.net/t/topic/87128/1: thread in the snapshot

**Tokens:** loop 27529 in / 1667 out · summary 0 in / 0 out

#### New Agent

**Tool calls:**

1. `read_topic` #87128 → saved to results/EF66B961-B04E-4A63-ABB1-97A79872F492/01-read_topic.txt

**Answer:**

**建议参考的暗黑主题：** Darcula。网友 VictoryRoad 在 [#13](https://meta.appinn.net/t/topic/87128/13) 说，纯黑背景还是有点费眼，建议参考 Darcula（链接为 draculatheme.com），认为它的暗灰或深紫色比单纯的黑更舒服、更美观。

**另一位网友的偏好：** Phosphorite 在 [#16](https://meta.appinn.net/t/topic/87128/16) 表示，Darcula 对他来说太亮了，他更喜欢一开始的那种 #000000 纯黑，在 OLED 屏幕上甚至不发光。

**作者的回应：**
- 在 [#18](https://meta.appinn.net/t/topic/87128/18) 中，作者说自己“从善如流”，已经改得差不多了，并问要不要做多个暗黑主题，会不会太臃肿。
- 在 [#21](https://meta.appinn.net/t/topic/87128/21) 中，作者提议改回去，或把暗黑调得柔和一点。
- Phosphorite 在 [#22](https://meta.appinn.net/t/topic/87128/22) 建议：如果只做一个暗色模式，就定死，不必为了个别用户调整；如果要调整，就要准备好工作量增加、做多个版本。
- 作者在 [#23](https://meta.appinn.net/t/topic/87128/23) 中表示，那就“追随我心，搞我认为合适的”。

按照这个讨论的走向，作者最终没有完全采用 Darcula 或纯黑之一。不过，首帖现在的主题表格里同时列出了 Dark-Dracula（偏紫灰）和 Dark-Black（更深的黑），说明后来还是保留了两种深色主题。帖子里没有明确写出作者为什么这样定，我只能依据首帖的现行说明来判断。

**Citations:** 6, 6 a thread in the snapshot

- https://meta.appinn.net/t/topic/87128/13: thread in the snapshot
- https://meta.appinn.net/t/topic/87128/16: thread in the snapshot
- https://meta.appinn.net/t/topic/87128/18: thread in the snapshot
- https://meta.appinn.net/t/topic/87128/21: thread in the snapshot
- https://meta.appinn.net/t/topic/87128/22: thread in the snapshot
- https://meta.appinn.net/t/topic/87128/23: thread in the snapshot

**Tokens:** loop 33825 in / 1351 out · summary 0 in / 0 out

| Owner verdict | |
|---|---|
| New better, same, or worse | same |
| Note | About equal. |

### D3

**Question:** 请总结帖子「全平台剪贴板推送与同步方案合集」（https://meta.appinn.net/t/18527），然后找找这里其他人怎么看第 2 点。

**Starting page:** https://meta.appinn.net/t/18527

#### Old Research

**Tool calls:**

1. `read_topic` topic_id=18527 → Read 40 posts

**Answer:**

## 帖子摘要：全平台剪贴板推送与同步方案合集

这是一个 wiki 帖（任何注册用户可编辑），整理了跨设备剪贴板方案 [全平台剪贴板推送与同步方案合集](https://meta.appinn.net/t/topic/18527)。

**概念划分**
- **推送**：主动发送文本，移动端无需打开客户端即可收到（iOS 受权限限制，需手动复制）。
- **同步**：无需主动发送，Android 常驻后台耗电，iOS 必须打开 App 才能复制。
- **获取**：需主动发送，且不支持后台推送。

**结构**
1. 剪贴板推送工具：Bark、Pushover、AnPush、ntfy.sh、Pushbullet、Join、PushDeer、BlueSend 等。
2. 剪贴板同步工具：快贴、CrossPaste、Octoclip、Pushbullet、Join、KDE Connect、FnSync、SyncClipboard（Windows↔Android）、微信输入法、手心输入法、Edgepad、微软方案、三星/联想/moto 厂商方案、文件同步软件等。
3. 剪贴板获取工具：SyncClipboard（Jeric-X）、Clipboard-online、AirDroid、Feem、SnapDrop、LocalSend、Clipboard Beam 等。

## 其他人怎么看第 2 点（剪贴板同步工具）

第 2 点下的讨论较少，多数回复更偏向第 1 点的推送或整体需求。与第 2 点直接相关的回复如下：

- **快贴**：有用户测试发现，从 Android 同步到 Windows 不通。 [见 #31](https://meta.appinn.net/t/topic/18527/31)
- **CopyQ 与文件夹同步**：有用户指出 CopyQ 可把剪贴板同步到文件夹，能衔接第 2 点末尾的“借助文件同步软件”，但它不支持 Android。作者认为桌面与安卓之间用聊天工具传文本和图片可能更好。 [见 #32](https://meta.appinn.net/t/topic/18527/32)
- **KDE Connect**：有用户推荐它，因为剪贴板还能传文件，但客户端较大。 [见 #35](https://meta.appinn.net/t/topic/18527/35)
- **分类调整**：楼主在 2024 年新增了“既不推送也不同步”的第三类，并收录 ntfy.sh、PushDeer、KDE Connect、SyncClipboard、LocalSend。KDE Connect 的 iOS 端因此被归入这一类。 [见 #37](https://meta.appinn.net/t/topic/18527/37)
- **SyncClipboard 同名问题**：有用户补充说 SyncClipboard（Jeric-X）支持 Linux、macOS 多端同步，WebDAV 或自建服务器均可作为服务端。随后该用户承认自己误把它和另一款同名工具混淆了。 [见 #38](https://meta.appinn.net/t/topic/18527/38)、[见 #40](https://meta.appinn.net/t/topic/18527/40)
- **同步延迟与省电**：楼主在 2020 年提到，Windows 端同步是实时的，但 Android 端因文件同步软件休眠而有延迟，加快扫描间隔会更费电。 [见 #3](https://meta.appinn.net/t/topic/18527/3)
- **速度问题**：有用户问同步速度能否近乎实时，但帖子中没有直接回答。 [见 #2](https://meta.appinn.net/t/topic/18527/2)
- **Windows 单行限制**：有用户反映向 PC 发送时只能是单行，多行失败。这条回复没有明确指向某个具体工具，因此无法确定是哪个方案。 [见 #36](https://meta.appinn.net/t/topic/18527/36)

**小结**：讨论的共识是，跨平台同步在 Android 后台、iOS 权限和厂商生态上受限明显。对第 2 点的具体工具，评论主要是补充、纠错和推荐，没有系统性的横向评测。帖子中的讨论大多写于 2020 至 2024 年，结论未必适用于当前版本，例如 CrossPaste 的 iOS 状态在正文中就标注为 2026 年 5 月的内测信息。

**Citations:** 10, 10 a thread in the snapshot

- https://meta.appinn.net/t/topic/18527: thread in the snapshot
- https://meta.appinn.net/t/topic/18527/31: thread in the snapshot
- https://meta.appinn.net/t/topic/18527/32: thread in the snapshot
- https://meta.appinn.net/t/topic/18527/35: thread in the snapshot
- https://meta.appinn.net/t/topic/18527/37: thread in the snapshot
- https://meta.appinn.net/t/topic/18527/38: thread in the snapshot
- https://meta.appinn.net/t/topic/18527/40: thread in the snapshot
- https://meta.appinn.net/t/topic/18527/3: thread in the snapshot
- https://meta.appinn.net/t/topic/18527/2: thread in the snapshot
- https://meta.appinn.net/t/topic/18527/36: thread in the snapshot

**Tokens:** loop 11613 in / 2857 out · summary 0 in / 0 out

#### New Agent

**Tool calls:**

1. `read_topic` #18527 → 40 posts

**Answer:**

## 帖子总结

[全平台剪贴板推送与同步方案合集](https://meta.appinn.net/t/18527) 是一个 wiki 帖，由 feeshy 维护，按下面的结构整理工具：

- **概念区分**：推送是主动发送文本，移动端不用打开客户端也能收到；同步是无需主动发送，但 Android 常驻后台耗电，iOS 必须打开 App 才能复制；获取是主动拉取，不支持后台推送。
- **1. 剪贴板推送工具**：Bark、Pushover、AnPush、ntfy.sh、Pushbullet、Join、PushDeer、BlueSend 等。Bark 在 iOS 14.5 之后无法自动复制推送内容，需要手动操作。
- **2. 剪贴板同步工具**：快贴、CrossPaste（iOS 仍在 TestFlight 内测）、Octoclip、Pushbullet（付费）、Join、KDE Connect、FnSync、SyncClipboard（hgoldfish 版）、微信输入法、手心输入法、Edgepad、微软方案、三星和联想/moto 厂商方案，以及借助文件同步软件的做法。
- **3. 剪贴板获取工具**：SyncClipboard（Jeric-X 版）、clipboard-online、AirDroid、Feem、SnapDrop、LocalSend、Clipboard Beam 等。

帖子里的信息大多来自 2020 年前后的讨论，部分工具状态可能已经变化，使用前最好核对官方说明。

## 其他人怎么看第 2 点（同步工具）

我把"第 2 点"理解为"2. 剪贴板同步工具"这一节。回复里直接讨论这一节的内容不多，主要有这些观点：

- **快贴**：有人测试过，[快贴 从安卓到 Windows 不能用](https://meta.appinn.net/t/18527/31)（2021）。
- **微软方案**：feeshy 说自己一直开着 Windows 的剪贴板同步，但从没和安卓成功同步过，有时两台 Win10 也不通（[#23](https://meta.appinn.net/t/18527/23)）。另有人提到 [需要 Win10 的剪贴板设备同步功能](https://meta.appinn.net/t/18527/22)。
- **KDE Connect**：[有人认为跨平台工具不能没有它，而且还能传文件，缺点是客户端偏大](https://meta.appinn.net/t/18527/35)（2023）。帖子作者后来在 [#37](https://meta.appinn.net/t/18527/37) 把 KDE Connect 等归入"既不推送也不同步"的新分类。
- **文件同步 + CopyQ**：CopyQ 可以把剪贴板同步到文件夹，能和文件同步方案衔接，但不支持安卓。有人认为桌面和手机之间用聊天工具传文本、图片更合适（[#32](https://meta.appinn.net/t/18527/32)）。
- **输入法方案**：有人指出，只同步文本时可以用一个特定输入法，在 PC 上打开网页，文本框内容就会实时同步（[#12](https://meta.appinn.net/t/18527/12)）。
- **实时性和耗电**：有人问同步速度能否接近实时。feeshy 回答 Windows 端是实时的，Android 端因文件同步软件休眠而有延迟。提高扫描频率能改善，但更费电（[#2](https://meta.appinn.net/t/18527/2)、[#3](https://meta.appinn.net/t/18527/3)）。
- **Android 权限限制**：hgoldfish 说 Android 10 之后后台服务不能再操作剪贴板，必须是前台应用，他至今没有想到解决办法（[#28](https://meta.appinn.net/t/18527/28)）。
- **Pushbullet 与 GMS**：有人推荐安卓直接用 Pushbullet，但有用户指出它依赖 GMS，想找不依赖 GMS 的方案（[#7](https://meta.appinn.net/t/18527/7)、[#8](https://meta.appinn.net/t/18527/8)）。
- **使用反馈**：有人反映，向 PC 发送时只能发单行文本，多行会失败（[#36](https://meta.appinn.net/t/18527/36)）。

整体来看，讨论里对 iOS 的同步支持几乎没有涉及，主要集中在 Windows 和 Android 之间的同步。论坛里没有对第 2 节工具做出统一的推荐或结论。

**Citations:** 14, 14 a thread in the snapshot

- https://meta.appinn.net/t/18527: thread in the snapshot
- https://meta.appinn.net/t/18527/31: thread in the snapshot
- https://meta.appinn.net/t/18527/23: thread in the snapshot
- https://meta.appinn.net/t/18527/22: thread in the snapshot
- https://meta.appinn.net/t/18527/35: thread in the snapshot
- https://meta.appinn.net/t/18527/37: thread in the snapshot
- https://meta.appinn.net/t/18527/32: thread in the snapshot
- https://meta.appinn.net/t/18527/12: thread in the snapshot
- https://meta.appinn.net/t/18527/2: thread in the snapshot
- https://meta.appinn.net/t/18527/3: thread in the snapshot
- https://meta.appinn.net/t/18527/28: thread in the snapshot
- https://meta.appinn.net/t/18527/7: thread in the snapshot
- https://meta.appinn.net/t/18527/8: thread in the snapshot
- https://meta.appinn.net/t/18527/36: thread in the snapshot

**Tokens:** loop 25967 in / 3604 out · summary 0 in / 0 out

| Owner verdict | |
|---|---|
| New better, same, or worse | new slightly better |
| Note | Neither side ran the search step. |

### D4

**Question:** 今天论坛里有什么值得一读的？

**Starting page:** https://meta.appinn.net/

#### Old Research

**Tool calls:**

1. `list_latest`  → 30 topics
1. `read_topic` topic_id=95371 → Read 48 posts
1. `read_topic` topic_id=95841 → Read 12 posts

**Answer:**

## 今天值得一读的帖子

我先看了今天最活跃的主题列表，然后细读了两个讨论较充分的主题。

### 1. Argus：Windows 任务管理器替代品（48 楼）
[快速、现代、美观、信息丰富的 Windows 任务管理器Argus](https://meta.appinn.net/t/topic/95371)

- **主要内容：** 开发者介绍的免费开源任务管理器，使用 Rust + Direct3D 11 绘制。功能包括按文件查占用进程、按端口查杀连接、查看最近 7 天的高占用进程、硬盘 SMART 信息，以及服务和启动项备注。
- **用户反馈：**
  - 好评：多位用户表示已替换系统任务管理器，认为功能接近或超过原生版本。有人称赞“查找占用文件进程”功能（[#36](https://meta.appinn.net/t/topic/95371/36)）。
  - 批评：布局偏乱、信息密度高，视觉重点不足（[#6](https://meta.appinn.net/t/topic/95371/6)）；窗口最小尺寸偏大，小屏幕难以使用（[#20](https://meta.appinn.net/t/topic/95371/20)）；管理员模式下 CPU 数据仍有偏差（[#40](https://meta.appinn.net/t/topic/95371/40)）。
  - 其他诉求：希望能与系统任务管理器共存或快速打开（[#9](https://meta.appinn.net/t/topic/95371/9)），希望支持 TrustedInstaller 等权限运行（[#44](https://meta.appinn.net/t/topic/95371/44)）。
- **作者回应：** v0.5.0 已发布，并优化了后台内存占用（[#38](https://meta.appinn.net/t/topic/95371/38)、[#37](https://meta.appinn.net/t/topic/95371/37)）。

### 2. Windows 11 启动项变慢：两个注册表参数（12 楼）
[微软故意让 Windows 11 启动项变慢：只需修改两个参数，启动时间从 150 秒降到 30 秒](https://meta.appinn.net/t/topic/95841)

- **主要内容：** 转载的新闻称，Windows 11 会延迟自启动程序。修改 `StartupDelayInMSec` 和 `WaitForIdleState` 两个值后，一个案例的启动时间从约 150 秒降到约 30 秒。原文给出了 `reg add` 命令（[#1](https://meta.appinn.net/t/topic/95841/1)）。
- **需要注意的点：**
  - 有人指出这是新增原本不存在的键，而不是修改（[#9](https://meta.appinn.net/t/topic/95841/9)）。
  - 有人提醒命令格式可能有问题（[#6](https://meta.appinn.net/t/topic/95841/6)）。
  - 有用户试过后反映启动确实变快，但过快会造成拥堵，给 AHK 脚本加 3 秒延迟更合适（[#12](https://meta.appinn.net/t/topic/95841/12)）。
  - 原文也认为，启动项不多的电脑不必折腾。
- **证据局限：** 效果数据来自原文引用的个别案例，论坛中只有少量用户实测反馈。

## 其他活跃主题（仅看到列表信息，未细读）

以下只根据标题和回复数判断，未核实内容：

- [SumatraPDF Plus 增强版](https://meta.appinn.net/t/topic/87128)（338 楼）
- [【开源自荐】SnowAir 轻雪](https://meta.appinn.net/t/topic/95048)（64 楼）
- [【开源自荐】Modu 默读](https://meta.appinn.net/t/topic/93226)（20 楼）
- [〖开源自荐〗SpaceKnife 硬盘空间分析](https://meta.appinn.net/t/topic/93965)（31 楼）
- [机械革命的笔记本电脑千万不要买！](https://meta.appinn.net/t/topic/95682)（32 楼）
- [黄仁勋辞去英伟达CEO职务](https://meta.appinn.net/t/topic/95798)（17 楼）
- [微软出了一个新的中文输入法](https://meta.appinn.net/t/topic/95914)（5 楼）

**总结：** 今天的热门话题以开源工具和 Windows 系统优化为主。Argus 讨论最充分，用户反馈具体；启动延迟话题也值得读，但修改注册表前应先确认效果和风险。

**Citations:** 21, 21 a thread in the snapshot

- https://meta.appinn.net/t/topic/95371: thread in the snapshot
- https://meta.appinn.net/t/topic/95371/36: thread in the snapshot
- https://meta.appinn.net/t/topic/95371/6: thread in the snapshot
- https://meta.appinn.net/t/topic/95371/20: thread in the snapshot
- https://meta.appinn.net/t/topic/95371/40: thread in the snapshot
- https://meta.appinn.net/t/topic/95371/9: thread in the snapshot
- https://meta.appinn.net/t/topic/95371/44: thread in the snapshot
- https://meta.appinn.net/t/topic/95371/38: thread in the snapshot
- https://meta.appinn.net/t/topic/95371/37: thread in the snapshot
- https://meta.appinn.net/t/topic/95841: thread in the snapshot
- https://meta.appinn.net/t/topic/95841/1: thread in the snapshot
- https://meta.appinn.net/t/topic/95841/9: thread in the snapshot
- https://meta.appinn.net/t/topic/95841/6: thread in the snapshot
- https://meta.appinn.net/t/topic/95841/12: thread in the snapshot
- https://meta.appinn.net/t/topic/87128: thread in the snapshot
- https://meta.appinn.net/t/topic/95048: thread in the snapshot
- https://meta.appinn.net/t/topic/93226: thread in the snapshot
- https://meta.appinn.net/t/topic/93965: thread in the snapshot
- https://meta.appinn.net/t/topic/95682: thread in the snapshot
- https://meta.appinn.net/t/topic/95798: thread in the snapshot
- https://meta.appinn.net/t/topic/95914: thread in the snapshot

**Tokens:** loop 40143 in / 4813 out · summary 0 in / 0 out

#### New Agent

**Tool calls:**

1. `list_latest`  → 30 threads
1. `summarize_topic` topic 95048 → 【开源自荐】SnowAir 轻雪 - 轻量化效率工具，截图，录屏，演示，贴图，OCR，翻译，晾衣架，单文件便携仅4mb
1. `summarize_topic` topic 95371 → 快速、现代、美观、信息丰富的 Windows 任务管理器Argus
1. `summarize_topic` topic 95682 → 机械革命的笔记本电脑千万不要买！
1. `summarize_topic` topic 95798 → 黄仁勋辞去英伟达CEO职务

**Answer:**

今天论坛里有几个值得一读的讨论。我看了四个比较热的帖子，列在下面。

**1. [【开源自荐】SnowAir 轻雪](https://meta.appinn.net/t/topic/95048)**（64 楼）
一款约 4MB 的 Windows 便携截图工具，集成截图标注、长截图、录屏、OCR 翻译、剪贴板历史等功能。评价总体正面，不少用户已把它当主力工具。讨论也很具体：OCR 独立快捷键、便携模式的配置位置、Defender 误报、托盘内存占用等问题，作者大多已在 v0.1.19 到 v0.1.21 中修复。适合在意截图工具或正在找替代品的人。

**2. [快速、现代、美观的 Windows 任务管理器 Argus](https://meta.appinn.net/t/topic/95371)**（48 楼）
免费的任务管理器替代品，用 Rust + Direct3D 绘制，信息密度高。多位用户表示已经替换了系统自带的任务管理器。争议主要在界面太密、小屏窗口无法缩小、CPU 数值偏差和启动速度。如果你在找任务管理器替代品，这个帖子的反馈很有参考价值。

**3. [机械革命的笔记本电脑千万不要买！](https://meta.appinn.net/t/topic/95682)**（32 楼）
楼主称公司两年内买了十多台机械革命笔记本，都出现了电池鼓包或充电问题，并批评售后。回复中有人质疑样本没有型号和批次信息，也有人提到自己的机器用得很好。帖子里有一个实用建议：把充电上限设到约 80%，以减少电池损耗。如果你在考虑购买这个品牌，可以对照这个帖子的讨论来判断。

**4. [黄仁勋辞去英伟达 CEO 职务](https://meta.appinn.net/t/topic/95798)**（17 楼）
楼主转发了一条消息，称黄仁勋辞去英伟达 CEO 职务，由 CFO Colette Kress 代理。帖子本身只附了一个链接，讨论里没有核实这条消息。回复里有不少玩笑、梗图，甚至有明显是讽刺的编造内容，要分开看。比较有价值的是 #17 楼 Duah 的长回复，它讨论了显卡的显存档位和型号命名误导，对选购显卡的人有参考价值。

**其他值得留意的：**
- [弈步四国：网页四国军棋](https://meta.appinn.net/t/topic/95879)：不需要四人同时在线，适合想玩点轻松游戏的人。
- [全平台剪贴板推送与同步方案合集](https://meta.appinn.net/t/topic/18527)（40 楼）：虽然最后活跃是 2024 年，但如果你在找跨设备剪贴板同步，它是一份现成的方案汇总。

如果你关心某个方向（比如截图工具、显卡选购，或者电脑故障排查），我可以再深入读其中一个帖子。

**Citations:** 6, 6 a thread in the snapshot

- https://meta.appinn.net/t/topic/95048: thread in the snapshot
- https://meta.appinn.net/t/topic/95371: thread in the snapshot
- https://meta.appinn.net/t/topic/95682: thread in the snapshot
- https://meta.appinn.net/t/topic/95798: thread in the snapshot
- https://meta.appinn.net/t/topic/95879: thread in the snapshot
- https://meta.appinn.net/t/topic/18527: thread in the snapshot

**Tokens:** loop 38679 in / 1729 out · summary 24432 in / 12240 out

| Owner verdict | |
|---|---|
| New better, same, or worse | same |
| Note | About equal. |

### D5

**Question:** 在「问题求助」分类里，2026-01-01 以来已解决的帖子中，群晖 NAS 用户遇到过哪些问题，是怎么解决的？

**Starting page:** https://meta.appinn.net/

**Snapshot misses:** https://meta.appinn.net/search.json?q=%E7%BE%A4%E6%99%96%20after:2026-01-01%20status:solved, https://meta.appinn.net/search.json?q=Synology%20after:2026-01-01%20status:solved, https://meta.appinn.net/search.json?q=%E7%BE%A4%E6%99%96%20NAS%20%E5%B7%B2%E8%A7%A3%E5%86%B3%20%23%E9%97%AE%E9%A2%98%E6%B1%82%E5%8A%A9%20after:2026-01-01, https://meta.appinn.net/search.json?q=NAS%20%E7%BE%A4%E6%99%96%20%E8%A7%A3%E5%86%B3%20order:latest%20after:2026-01-01, https://meta.appinn.net/search.json?q=%E7%BE%A4%E6%99%96%20%E7%A1%AC%E7%9B%98%20%E6%95%85%E9%9A%9C%20OR%20%E6%97%A0%E6%B3%95%20OR%20%E6%8A%A5%E9%94%99%20after:2026-01-01, https://meta.appinn.net/search.json?q=%E7%BE%A4%E6%99%96%20%E6%B1%82%E5%8A%A9%20after:2026-01-01, https://meta.appinn.net/search.json?q=%23%E9%97%AE%E9%A2%98%E6%B1%82%E5%8A%A9%20%E7%BE%A4%E6%99%96%20solved, https://meta.appinn.net/search.json?q=DSM%20%E6%B1%82%E5%8A%A9%20%E8%A7%A3%E5%86%B3%20after:2026-01-01, https://meta.appinn.net/t/88526.json, https://meta.appinn.net/raw/88526?page=1

#### Old Research

**Tool calls:**

1. `search_forum` query=群晖 NAS after:2026-01-01 status:solved → 1 topic
1. `search_forum` query=#问题求助 群晖 NAS status:solved after:2026-01-01 → 0 topics
1. `search_forum` query=群晖 解决 after:2026-01-01 → 8 topics
1. `read_topic` topic_id=88672 → Read 4 posts
1. `search_forum` query=群晖 NAS 求助 after:2026-01-01 → 3 topics
1. `read_topic` topic_id=90860 → Read 2 posts
1. `search_forum` query=群晖 DSM 已解决 after:2026-01-01 → 5 topics

**Answer:**

## 结论

在我能检索到的结果中，没有找到符合条件的「问题求助」分类、2026-01-01 以来已明确标记为解决的群晖 NAS 帖子。分类过滤搜索没有返回结果，我只能手动筛选，因此可能有遗漏。

## 相关内容

**1. 启动不了：清灰后拆开清理，问题消失（最接近已解决的案例）**
- [求助！群晖NAS DS920+启动不了](https://meta.appinn.net/t/topic/88672)（2026-07-23）
- 问题：移动 NAS 并断电清灰后重新上电无法启动，硬盘灯闪烁后自动断电。
- 处理经过：
  - 版主 Qingwa 建议检查是否接触不良，清灰时多半碰到了哪里（[#2](https://meta.appinn.net/t/topic/88672/2)）。
  - TecNico 分享经验，称轻敲主板等部位有时能修好（[#3](https://meta.appinn.net/t/topic/88672/3)）。这是个人经验，不一定适用于其他情况。
  - 楼主反馈：全部拆开清理一遍，通电正常，装回即可（[#4](https://meta.appinn.net/t/topic/88672/4)）。
- 注意：帖子没有明确标记为已解决，但楼主的最后回复说明问题已恢复。

**2. 安装蒲公英提示「部份设置错误」：暂无确认的解决方案**
- [在群晖NAS安装蒲公英，提示“部份设置错误，请再次输入。”](https://meta.appinn.net/t/topic/90860)（2026-08-28）
- 问题：计划任务中的 setuid 没有报错，但添加开机启动加载虚拟网卡时报错。
- 版主回复只给了排查方向：「任务名是空的？显示了红色」（[#2](https://meta.appinn.net/t/topic/90860/2)）。帖子里没有确认的解决结果。

**3. 安全相关的群晖公告（非求助帖）**
- [群晖发布公告：勒索病毒攻击利用了2024年12月已修复漏洞，请立即升级 DSM](https://meta.appinn.net/t/topic/94828)（最后活动 2026-11-09）：建议升级到最新 DSM。
- [群晖两连更：Telnetd 爆出两个 9.8 分 CVE 漏洞](https://meta.appinn.net/t/topic/82916)（2026-03-21）：帖子称不开启 Telnet 服务则不受影响，建议检查。
- [群晖公布 27 个 DSM 安全漏洞](https://meta.appinn.net/t/topic/95756)（2026-11-12）：转载新闻，没有用户反馈的解决记录。

## 局限

- 只读取了 2 个求助类主题；其他搜索结果多为新闻或无关讨论。
- 没有找到明确标记为已解决、带采纳回复的群晖求助帖。如需完整结论，建议在论坛中按分类或「已解决」状态再筛选一次。

**Citations:** 9, 9 a thread in the snapshot

- https://meta.appinn.net/t/topic/88672: thread in the snapshot
- https://meta.appinn.net/t/topic/88672/2: thread in the snapshot
- https://meta.appinn.net/t/topic/88672/3: thread in the snapshot
- https://meta.appinn.net/t/topic/88672/4: thread in the snapshot
- https://meta.appinn.net/t/topic/90860: thread in the snapshot
- https://meta.appinn.net/t/topic/90860/2: thread in the snapshot
- https://meta.appinn.net/t/topic/94828: thread in the snapshot
- https://meta.appinn.net/t/topic/82916: thread in the snapshot
- https://meta.appinn.net/t/topic/95756: thread in the snapshot

**Tokens:** loop 32560 in / 4842 out · summary 0 in / 0 out

#### New Agent

**Tool calls:**

1. `search_forum` "群晖 after:2026-01-01 status:solved" → 2 threads
1. `search_forum` "Synology after:2026-01-01 status:solved" → 1 thread
1. `search_forum` "群晖 NAS 已解决 #问题求助 after:2026-01-01" → 0 threads
1. `search_forum` "NAS 群晖 解决 order:latest after:2026-01-01" → 6 threads
1. `search_forum` "群晖 硬盘 故障 OR 无法 OR 报错 after:2026-01-01" → 0 threads
1. `search_forum` "群晖 求助 after:2026-01-01" → 6 threads
1. `search_forum` "#问题求助 群晖 solved" → 0 threads
1. `search_forum` "DSM 求助 解决 after:2026-01-01" → 0 threads
1. `read_topic` #88672 → 4 posts
1. `read_topic` #90860 → 2 posts
1. `read_topic` #83619 → 19 posts
1. `read_topic` #88526 → 5 posts

**Answer:**

我没能按「问题求助」分类和「已解决」状态筛出结果。搜索工具不返回分类和解决标记，我只能用关键词搜索，再逐个查看帖子。下面是找到的 2026-01-01 之后、与群晖 NAS 相关的帖子，但其中大多数并没有明确的已解决结论。

**1. 最接近「已解决」的一例：DS920+ 无法开机**
- 帖子：[求助！群晖NAS DS920+启动不了](https://meta.appinn.net/t/topic/88672)
- 问题：楼主挪动 NAS 后断电清灰，再开机无法启动，硬盘灯闪烁后自动断电。
- 解决：楼主自己在 [#4](https://meta.appinn.net/t/topic/88672/4) 说，他把机器全部拆开清理了一遍，通电正常，装回去就好了。
- 其他回复：[#2](https://meta.appinn.net/t/topic/88672/2) 建议检查接触不良，因为清灰后出问题多半是碰到了什么地方。[#3](https://meta.appinn.net/t/topic/88672/3) 提到用小木槌敲主板的做法，但这只是个人经历，我不建议照做，敲击可能损坏硬件。

**2. 蒲公英 VPN 在群晖上安装报错（未见解决）**
- 帖子：[在群晖NAS安装蒲公英，提示“部份设置错误，请再次输入。”](https://meta.appinn.net/t/topic/90860)
- 问题：计划任务里的 “setuid pgyvpn” 没有报错，但添加开机加载虚拟网卡的任务时报错 001、002、003。
- 回复：版主 Qingwa 在 [#2](https://meta.appinn.net/t/topic/90860/2) 问「任务名是空的？显示了红色」。帖子里没有楼主确认或最终方案。

**3. 群晖远程开机与远程桌面（讨论帖，有多种方案，没有标记解决）**
- 帖子：[求助远程开机+远程桌面](https://meta.appinn.net/t/topic/83619)
- 有群晖用户的做法：在 [#15](https://meta.appinn.net/t/topic/83619/15) 提到，有公网 IP 时用群晖 VPN 套件开 OpenVPN，再用 WOL 开机，最后 RDP 登录。
- 其他方案包括 [#16](https://meta.appinn.net/t/topic/83619/16) 的 frp + upsnap + RustDesk，以及 [#11](https://meta.appinn.net/t/topic/83619/11) 的 ToDesk 加 BIOS 网络唤醒设置。这些是各人分享的方案，楼主没有确认哪个最好用。

**4. 替代群晖 Drive 同步的工具（推荐讨论，没有明确结论）**
- 帖子：[有没有软件或工具可以替代群晖的drive同步功能？](https://meta.appinn.net/t/topic/88526)
- 需求：实时同步、版本控制、快照。
- 回复提到 Syncthing（[#2](https://meta.appinn.net/t/topic/88526/2)），但 [#3](https://meta.appinn.net/t/topic/88526/3) 指出它没有快照和版本控制，低端群晖也不一定能装 Docker。[#4](https://meta.appinn.net/t/topic/88526/4) 认为低端机型还是 Drive 最合适，[#5](https://meta.appinn.net/t/topic/88526/5) 提到 Seafile。

**总结**
在这次搜索能找到的范围内，只有第 1 个帖子有楼主明确说明的解决办法（拆机清灰后恢复正常）。其余帖子要么没有解决结论，要么是推荐讨论。论坛上也可能有我没搜到的帖子，比如用了其他关键词或分类标签的。如果你需要，我可以再用「DSM」「硬盘」「Docker」「Tailscale」等关键词继续搜。

**Citations:** 15, 15 a thread in the snapshot

- https://meta.appinn.net/t/topic/88672: thread in the snapshot
- https://meta.appinn.net/t/topic/88672/4: thread in the snapshot
- https://meta.appinn.net/t/topic/88672/2: thread in the snapshot
- https://meta.appinn.net/t/topic/88672/3: thread in the snapshot
- https://meta.appinn.net/t/topic/90860: thread in the snapshot
- https://meta.appinn.net/t/topic/90860/2: thread in the snapshot
- https://meta.appinn.net/t/topic/83619: thread in the snapshot
- https://meta.appinn.net/t/topic/83619/15: thread in the snapshot
- https://meta.appinn.net/t/topic/83619/16: thread in the snapshot
- https://meta.appinn.net/t/topic/83619/11: thread in the snapshot
- https://meta.appinn.net/t/topic/88526: thread in the snapshot
- https://meta.appinn.net/t/topic/88526/2: thread in the snapshot
- https://meta.appinn.net/t/topic/88526/3: thread in the snapshot
- https://meta.appinn.net/t/topic/88526/4: thread in the snapshot
- https://meta.appinn.net/t/topic/88526/5: thread in the snapshot

**Tokens:** loop 54982 in / 2918 out · summary 0 in / 0 out

| Owner verdict | |
|---|---|
| New better, same, or worse | same |
| Note | About equal; both wrongly say threads are "not marked solved" (88672 and 83619 are solved). |

### H1

**Question:** 这里的人怎么看用 Intel N100 迷你主机做家用服务器？

**Starting page:** https://news.ycombinator.com/

#### Old Research

**Tool calls:**

1. `search_forum` query=N100 home server → 20 topics
1. `search_comments` query=N100 mini PC → 5 topics
1. `read_topic` topic_id=50109715 → Read 434 posts

**Answer:**

## 结论

HN 上的讨论总体偏正面。N100 被看作性价比高、功耗低、足够跑家用服务器的小主机。不过我找到的相关讨论很少，而且大多出现在一个更宽泛的“自托管”帖子里，所以这只能算少量样本的印象，不代表整体共识。

## 主要观点

**正面评价**
- 一位用户说自己有两台 N100 小主机，一台跑 Proxmox + 虚拟机，一台跑 Debian + Docker，运行 Jellyfin、FreshRSS 和身份认证服务，“稳定运行”。他们购入时约 180 美元，并提到这是在内存涨价（“RAMpocalypse”）之前。[What I self-host](https://news.ycombinator.com/item?id=50109715)
- 另一位用户用一台 16GB 内存的 N100 迷你主机（带 4 个网口的国产型号）跑 arr 全家桶、Jellyfin、Immich、n8n 等，并称它“处理 4K HEVC 相当不错”，“是一颗出乎意料地强的芯片”。后来他因需求增长换成了 Core Ultra 7 155H。[What I self-host](https://news.ycombinator.com/item?id=50109715)
- 在另一个关于 Android TV 去广告的讨论里，有用户建议“最好的办法就是迷你主机”，并认为仍能便宜买到 N100 机器。[An ad-free Android TV](https://news.ycombinator.com/item?id=50158942)

**局限与注意点**
- 有用户指出，N100 类机器的硬件转码会让 GPU 发热明显，很多机型是无风扇设计，重负载下压力较大。[What I self-host](https://news.ycombinator.com/item?id=50109715)
- 同一用户的反馈是：一两路转码没问题，只是同时多路时要注意。另有用户提到，在 Linux 上配置 Intel 的专有驱动是最麻烦的部分。[What I self-host](https://news.ycombinator.com/item?id=50109715)
- 另一个痛点是存储扩展受限：这类机器通常只有 1 到 2 个硬盘位，要做 NAS 或 RAID 就会很快碰到上限。有人提到部分国产主板/迷你主机能接 6 个 SATA 或 4 个 NVMe，但仍然有限。[What I self-host](https://news.ycombinator.com/item?id=50109715)
- 有用户指出自托管的“巴士因子”问题：家人依赖的服务如果只有你会维护，你离开后家人可能无法恢复。[What I self-host](https://news.ycombinator.com/item?id=50109715)

## 样本说明

我只做了两次搜索和一次帖子阅读。最相关的 N100 直接经验都来自“What I self-host”这一帖。其他提到 N100 的只是顺带一提（例如 [An ad-free Android TV](https://news.ycombinator.com/item?id=50158942) 和 [The cost of lies: A Mineserver story](https://news.ycombinator.com/item?id=49950865)）。因此，我没有看到系统性评测或大范围的购买建议；如果需要更全面的判断，可以再搜索“Proxmox mini PC”“Jellyfin transcoding”等关键词。

**Citations:** 3, 3 a thread in the snapshot

- https://news.ycombinator.com/item?id=50109715: thread in the snapshot
- https://news.ycombinator.com/item?id=50158942: thread in the snapshot
- https://news.ycombinator.com/item?id=49950865: thread in the snapshot

**Tokens:** loop 43806 in / 3703 out · summary 0 in / 0 out

#### New Agent

**Tool calls:**

1. `search_forum` "Intel N100 home server" → 1 thread
1. `search_comments` "N100 home server" → 10 comments
1. `read_topic` #41389931 → saved to results/4FD3CBE6-5D8D-4926-8713-007AB21DFE5E/03-read_topic.txt
1. `read_topic` #38823514 → saved to results/4FD3CBE6-5D8D-4926-8713-007AB21DFE5E/04-read_topic.txt

**Answer:**

HN 上对 N100 做家用服务器的整体评价偏正面，主要是“功耗低、够用、性价比高”。但我只找到零散的讨论，没有系统性的对比测试，下面的结论基于这几段评论。

**正面评价**
- **功耗低、够用。** 有用户说自己的 N100 mini PC 功耗约 2–8W，用普通 12V 电源即可，跑 Home Assistant 和轻量虚拟化性能不错，比他的 i5-6500 迷你机还快（[7 watts idle 讨论串](https://news.ycombinator.com/item?id=38823514)）。另一位用户说 N100 比树莓派更快，功耗几乎没增加（[Raspberry Pi 5 产量讨论](https://news.ycombinator.com/item?id=38996954)）。
- **替代树莓派。** 有人从树莓派 4 换到 N100 迷你机，评价是“非常好的性价比”（[Intel Clearwater Forest 讨论](https://news.ycombinator.com/item?id=45037572)）。
- **适合当“够用”的家庭服务器。** 有评论认为，只需要串流媒体和文件服务的话，N100 的性能已经绰绰有余（[The future is not self-hosted 讨论](https://news.ycombinator.com/item?id=44698899)）。也有人在 Nvidia Digits 的讨论里说，如果不需要本地跑大模型，基于 N100 的家庭服务器更合理（[Nvidia Digits 讨论](https://news.ycombinator.com/item?id=42621332)）。
- **有人实际在用。** 多位用户说自己的家庭服务器就是 N100，例如 ITX 板配 32GB 内存“运行良好”（[7 watts idle 讨论串](https://news.ycombinator.com/item?id=38823514)）。

**需要注意的地方**
- **硬盘和 SATA 口少。** 有用户指出，很多 N100 主板的 SATA 口不够，做 NAS 要靠额外的扩展卡（同上讨论串）。
- **ECC 内存通常不支持。** 讨论串里提到 ECC 的价值，但我没有找到 N100 支持 ECC 的明确说法，选型时需要自己确认。
- **ZFS 与硬盘休眠。** 讨论串里有人认为，频繁让硬盘休眠对 HDD 不利，ZFS 阵列也很难真正省电（同上讨论串）。
- **网卡和 BIOS 限制。** 有人提醒，Lenovo 迷你机在检测到非原装无线网卡时会锁定启动，升级空间有限（[Lenovo ThinkCentre 评论](https://news.ycombinator.com/item?id=41389931)）。这不是 N100 专有问题，但买二手机器时要留意。
- **二手平台的虚标。** 有用户反映某品牌迷你机标称的主频与实际不符，客服坚持原描述（[Low Cost Mini PCs 讨论](https://news.ycombinator.com/item?id=41389931)）。这也说明购买时要核实规格。

**另一种看法**
- 有人认为 N100 之外还有更好的选择，例如 N305，或者 Mac mini 配多盘位外置柜，功耗同样很低，还能跑 Plex、Gitea 等服务（[7 watts idle 讨论串](https://news.ycombinator.com/item?id=38823514)）。

**小结**：如果你的需求是媒体服务、Home Assistant、Docker 和少量虚拟机，HN 的普遍看法是 N100 很合适、性价比高。如果需要多块硬盘、ECC 或更多扩展，就要仔细看主板规格，或者考虑 N305 这类型号。

参考的讨论串：
- [Low Cost Mini PCs](https://news.ycombinator.com/item?id=41389931)
- [7 watts idle – building a low powered server/NAS on Intel 12th/13th gen](https://news.ycombinator.com/item?id=38823514)

**Citations:** 6, 6 a thread in the snapshot

- https://news.ycombinator.com/item?id=38823514: thread in the snapshot
- https://news.ycombinator.com/item?id=38996954: thread in the snapshot
- https://news.ycombinator.com/item?id=45037572: thread in the snapshot
- https://news.ycombinator.com/item?id=44698899: thread in the snapshot
- https://news.ycombinator.com/item?id=42621332: thread in the snapshot
- https://news.ycombinator.com/item?id=41389931: thread in the snapshot

**Tokens:** loop 45348 in / 2301 out · summary 0 in / 0 out

| Owner verdict | |
|---|---|
| New better, same, or worse | same |
| Note | About equal. |

### H2

**Question:** In the thread "SQLite in Production: Lessons from Running a Store on a Single File" (https://news.ycombinator.com/item?id=47637353), why did concurrent database exec queries during a deploy trigger the OOM killer on their t3.small machine, and what GitHub Actions feature does a commenter recommend instead of CLAUDE.md deploy rules?

**Starting page:** https://news.ycombinator.com/item?id=47637353

#### Old Research

**Tool calls:**

1. `read_topic` topic_id=47637353 → Read 130 posts

**Answer:**

## Answer

**1. Why the OOM killer fired:** The thread does not show the article's own OOM explanation. The only source is a commenter, jbrogers63, quoting the article ([thread, comment #96](https://news.ycombinator.com/item?id=47637353)):

> "On our t3.small (2GB RAM), the web container uses ~780MB. Spawning an exec container for a quick database query adds another ~500MB. Two concurrent exec calls during a deploy? That's 2.5GB on a 2GB machine. OOM killer takes the web process down."

In short, each `exec` query ran in a new container costing about 500MB on top of the roughly 780MB web container. Two overlapping execs during a deploy needed about 2.5GB on a 2GB instance, so the kernel killed the web process. The memory figures are the article's as quoted by the commenter. I could not open the original article to confirm them.

**2. The GitHub Actions feature recommended instead of CLAUDE.md rules:** The commenter adobrawy suggested **workflow concurrency control** in GitHub Actions, linking to GitHub's docs on controlling workflow concurrency ([comment #116](https://news.ycombinator.com/item?id=47637353)). The point was to stop overlapping deploys mechanically, rather than relying on an AI agent to follow the rule "avoid rapid-fire pushes to main" written in CLAUDE.md. The article's own CLAUDE.md rule is quoted in [comment #3](https://news.ycombinator.com/item?id=47637353).

**Caveats:** Both answers come from commenters' quotes and suggestions, not from the article text itself. The thread also raises doubts about whether the blog and its store are real, which I did not verify.

**Citations:** 1, 1 a thread in the snapshot

- https://news.ycombinator.com/item?id=47637353: thread in the snapshot

**Tokens:** loop 14465 in / 1198 out · summary 0 in / 0 out

#### New Agent

**Tool calls:**

1. `read_topic` #47637353 → saved to results/DB98AEAF-BC2E-47B7-8174-3FA3B5769B27/01-read_topic.txt
1. `file_read` results/DB98AEAF-BC2E-47B7-8174-3FA3B5769B27/01-read_topic.txt → 20,000 of 41,608
1. `read_topic` #47637353 · "OOM memory t3.small" → 130 posts

**Answer:**

**Short answer:** According to a comment quoting the article, two concurrent `exec` queries during a deploy briefly needed more memory than the 2 GB box had. The GitHub Actions feature suggested instead of CLAUDE.md rules is workflow **concurrency control**.

**1. The OOM explanation**

The thread doesn't contain the article itself, so this comes from comment #96, which quotes the post: "On our t3.small (2GB RAM), the web container uses ~780MB. Spawning an exec container for a quick database query adds another ~500MB. Two concurrent exec calls during a deploy? That's 2.5GB on a 2GB machine. OOM killer takes the web process down." ([Hacker News thread](https://news.ycombinator.com/item?id=47637353), comment #96)

The cause is memory: the web container (~780 MB) plus two extra exec containers (~500 MB each) during a deploy exceeded the machine's 2 GB. The commenter's reading is that the overlap came from deploys, not from SQLite itself.

**2. The recommended GitHub Actions feature**

Comment #116 asks why the team didn't use GitHub Actions concurrency control to stop overlapping deploys, rather than relying on agent behavior: "If the problem is excessive deployments via GitHub Actions, why not use concurrency control on GitHub Actions... instead of relying on agent randomness and the hope that it won't make the same mistake again?" ([Hacker News thread](https://news.ycombinator.com/item?id=47637353), comment #116)

The commenter links to GitHub's docs on controlling workflow concurrency. Note that this is a suggestion in the thread, not something the article says it adopted.

**Caveats**
- The thread shows the article's deploy-rule quote in comment #3: "Avoid rapid-fire pushes to main — 11 pushes in 2h caused overlapping Kamal deploys with concurrent SQLite access." I didn't read the article itself, so I can't confirm the rest of its details.
- Comment #96 is a reply to #92, which fell in an omitted part of the thread, so I couldn't read the parent.

**Citations:** 1, 1 a thread in the snapshot

- https://news.ycombinator.com/item?id=47637353: thread in the snapshot

**Tokens:** loop 52866 in / 1641 out · summary 0 in / 0 out

| Owner verdict | |
|---|---|
| New better, same, or worse | same |
| Note | About equal (3.6x loop input). |

### H3

**Question:** Summarize the thread "How I use Tailscale" (https://news.ycombinator.com/item?id=44809166), then find what others here say about exposing a service with `tailscale funnel`.

**Starting page:** https://news.ycombinator.com/item?id=44809166

#### Old Research

**Tool calls:**

1. `read_topic` topic_id=44809166 → Read 102 posts
1. `search_comments` query=tailscale funnel → 5 topics
1. `read_topic` query=funnel topic_id=49754785 → Read 7 matching posts

**Answer:**

## Summary of "How I use Tailscale"

The HN thread links to the author's post at https://chameth.com/how-i-use-tailscale/. The thread itself contains only that link, so the site doesn't establish the post's contents. What follows is what commenters said about Tailscale ([thread](https://news.ycombinator.com/item?id=44809166)):

- **Use cases:** Commenters use it for private access to home media servers (Jellyfin) and file servers. Some run exit nodes at home to reach geo-restricted services such as banks and streaming (comments #7, #9).
- **Ad blocking:** One user routes mobile traffic through AdGuard Home or Pi-hole over Tailscale (#10).
- **Alternatives:** Several people compared it with WireGuard, Nebula, ZeroTier, Headscale, and NetBird (#3, #12, #20, #86, #95). One user said plain WireGuard is enough for their needs.
- **Concerns:** Battery drain on a phone and DNS (`resolv.conf`) problems under WSL were reported (#2). Commenters debated Tailscale's built-in SSH handling, which authenticates through Tailscale instead of keys (#15, #17, #87-#89). One user noted that tailnet ACLs and config are not signed, so a compromised coordination server could change them (#101). Another pointed out that Tailscale can take over DNS on Linux by default (#75-#76).

## What others say about `tailscale funnel`

Funnel makes a service reachable from the public internet through an HTTPS URL that Tailscale provides.

- **Exposure is fast:** One user ran `python -m http.server` behind Funnel and saw vulnerability scanners probing it within about 10 seconds. Certificate Transparency logs help bots find the hostname ([comment #21](https://news.ycombinator.com/item?id=44809166), item 44850881; replies #22-#32).
- **Mitigations discussed:** Commenters suggested non-standard high ports, which cut down on connections. Others argued that Tailscale proxies traffic, so the public IP isn't exposed, and that port choice matters little because scanners find services on standard ports anyway. Another suggestion was wildcard certificates so hostnames aren't leaked, though that only works if you manage your own certificates (#24-#28). The site does not settle which of these views is right.
- **Limits:** In a [Cloudflare Quick Tunnels thread](https://news.ycombinator.com/item?id=49754785), one commenter said you can have only one Funnel per machine at the HTTPS endpoint, so other apps end up on custom-port URLs (item 49758062). Another replied that path-based routing (`/foo` to `localhost:3001`) lets one Funnel serve several apps (same thread, item 49758062). A third ran a Tailscale container in each Docker Compose stack to get multiple Funnels (item 49758062).
- **Alternatives:** Commenters compared Funnel with Cloudflare Tunnels and with `tsnet` in Go for more control (items 49757202, 49758062, 49758784). One commenter said that for a public MCP endpoint, Tailscale would only help if you used Funnel, and suggested the Cloudflare option instead (item 49758784).
- **Also mentioned:** A later commenter called Funnel "easy" in a self-hosting thread ([item 49985548](https://news.ycombinator.com/item?id=49985548)). That excerpt was cut off, so I can't give its full view.

**Caveat:** These come from comment excerpts and partial thread reads, so they don't cover every opinion on Funnel.

**Citations:** 3, 3 a thread in the snapshot

- https://news.ycombinator.com/item?id=44809166: thread in the snapshot
- https://news.ycombinator.com/item?id=49754785: thread in the snapshot
- https://news.ycombinator.com/item?id=49985548: thread in the snapshot

**Tokens:** loop 59320 in / 4352 out · summary 0 in / 0 out

#### New Agent

**Tool calls:**

1. `summarize_topic` https://news.ycombinator.com/item?id=44809166 → How I use Tailscale
1. `read_topic` https://news.ycombinator.com/item?id=44809166 · "funnel" → 102 posts

**Answer:**

**Thread summary**

The story is [How I use Tailscale](https://news.ycombinator.com/item?id=44809166), submitted by aquariusDue and linking to [chameth's blog post](https://chameth.com/how-i-use-tailscale/). The thread has about 102 posts. The article covers the author's personal setup, including ACLs (so a compromised machine can't reach everything on the tailnet), Tailscale SSH, and OIDC for internal services. The discussion covers:

- **Use cases:** Exposing media servers like Jellyfin or Plex without opening ports, home exit nodes for geo-blocked services, and using Tailscale as a VPN.
- **Alternatives:** Headscale, Netbird, Nebula, ZeroTier, and plain WireGuard.
- **Privacy:** The most-discussed concern was that the default logging sends connection open/close metadata to Tailscale's servers, and mobile clients can't opt out. Commenters disagreed on how serious that metadata risk is.
- **Other issues:** Tailscale's DNS resolver can overwrite system DNS on some platforms, and one user reported battery drain on a phone.

**Funnel discussion**

I read the eight posts that matched "funnel", so this part is based on those plus the summary:

- **Scanners arrive fast.** abdusco ran `tailscale funnel` against `python -m http.server`, and bots were probing for vulnerabilities within about 10 seconds. The Tailscale warning about the public certificate transparency log was accurate, but they didn't expect it to be that quick ([comment 44850881](https://news.ycombinator.com/item?id=44850881), #21).
- **Port choice.** mh- suggested high non-standard ports to reduce connection volume, and said a funnel on a residential connection can amount to "summoning a DDoS" ([comment 44851004](https://news.ycombinator.com/item?id=44851004), #22). modernpacifist replied that Tailscale proxies the traffic, so the public IP isn't exposed, the flood stops when the funnel closes, and the port makes no difference ([#23](https://news.ycombinator.com/item?id=44809166)).
- **Wildcard certificates.** Jnr runs Headscale with a Traefik-based proxy UI, and uses one wildcard certificate so subdomains don't appear in CT logs ([comment 44851521](https://news.ycombinator.com/item?id=44851521), #58). j45 suggested routing public traffic through a single Cloudflare Tunnel instead, so Funnel doesn't need to be public ([#59](https://news.ycombinator.com/item?id=44809166)). The summary says this has the same CT issue unless a wildcard cert is used.
- **Hardening.** exac said dev servers typically aren't hardened, so they'd be wary of using Funnel for anything beyond quick sharing ([#65](https://news.ycombinator.com/item?id=44809166)). yjftsjthsd-h noted that a service isn't exposed if you use Tailscale as a VPN without enabling Funnel ([#55](https://news.ycombinator.com/item?id=44809166)).
- **Tooling.** jaxxstorm built tgate, an ngrok-style proof of concept using Tailscale Serve and Funnel ([comment 44818657's reply, #18](https://news.ycombinator.com/item?id=44809166)).

**Takeaway:** Commenters agree that Funnel makes a host visible quickly, and they disagree on whether that matters. Some treat it as a DDoS and targeting risk, and others as a non-issue once it's closed. The thread's consensus is to expose only what you intend to publish and to harden it. Wildcard certificates and a separate public ingress are the mitigations most often suggested. The thread doesn't establish how much real-world risk Funnel carries beyond these anecdotes.

**Citations:** 5, 4 a thread in the snapshot

- https://news.ycombinator.com/item?id=44809166: thread in the snapshot
- https://chameth.com/how-i-use-tailscale/: not in the snapshot
- https://news.ycombinator.com/item?id=44850881: thread in the snapshot
- https://news.ycombinator.com/item?id=44851004: thread in the snapshot
- https://news.ycombinator.com/item?id=44851521: thread in the snapshot

**Tokens:** loop 21893 in / 2184 out · summary 19005 in / 2794 out

| Owner verdict | |
|---|---|
| New better, same, or worse | worse |
| Note | Old better: new never searched other threads, and states the article's contents without fetching it. |

### H4

**Question:** What's worth reading today on Hacker News?

**Starting page:** https://news.ycombinator.com/

#### Old Research

**Tool calls:**

1. `list_latest`  → 30 topics
1. `read_topic` topic_id=50497155 → Read 8 posts

**Answer:**

## What's worth reading today

I checked only the 30 newest stories and read one discussion in full, so these picks rest mostly on titles and short snippets. Most new stories have a single post, so there is little discussion to judge them by.

**1. Serving GLM-5.3 across two Nvidia DGX stations (the one thread I read)**
- The linked [NVIDIA post](https://developer.nvidia.com/blog/when-one-gpu-isnt-enough-serving-glm-5-3-across-two-nvidia-dgx-stations-with-vllm/) is discussed in [this HN thread](https://news.ycombinator.com/item?id=50497155).
- The discussion is mostly skeptical of the economics. One commenter estimates roughly a 7-year payback at maximum utilization for a ~$100K box at $1.4/M output tokens, ignoring electricity. Another says 4-bit quantized models could run on 8x B6000 for about half the price.
- A reply says DeepSeek's memory savings allow more concurrent users on the same hardware, which is a reason to pick it over GLM for high-concurrency serving. The commenter calls the quality tradeoffs speculative.
- Worth reading if you care about self-hosting economics.

**2. Other new stories that look interesting from titles or snippets**
- **[Show HN: SrcWranglr v0.13](https://news.ycombinator.com/item?id=50497513)**: an open-source, Rust-based C/C++ code explorer for vulnerability research. The author says it started as a Python prototype.
- **[Show HN: Epistemic News, re-ranking HN comments](https://news.ycombinator.com/item?id=50497248)**: a comment re-ranker built with Gemini, using techniques from the paper "Scaling Discovery Requires Forgetting."
- **[Show HN: Burrmill, SQL over Parquet with exact integer arithmetic](https://news.ycombinator.com/item?id=50497375)**: from the title alone, a niche but possibly useful tool for analytics data.
- **[Amazon has a plan to index the online shopping data](https://news.ycombinator.com/item?id=50497330)**: title only, no discussion yet.
- **[Vercel should fork and maintain Deno](https://news.ycombinator.com/item?id=50497196)**: the post says Deno is being acquired by Cloudflare and will eventually be sunset. That is the post's claim, and I did not verify it.
- **[The "Year of Linux" isn't coming](https://news.ycombinator.com/item?id=50497522)** and **[Binary Logic Breaks AI Safety: "Yes, No, Probably"](https://news.ycombinator.com/item?id=50497158)**: title only, no discussion yet.

This is a snapshot of the newest stories, not a quality ranking. Stories with more discussion and the front page as a whole would need a separate check.

**Citations:** 9, 8 a thread in the snapshot

- https://developer.nvidia.com/blog/when-one-gpu-isnt-enough-serving-glm-5-3-across-two-nvidia-dgx-stations-with-vllm/: not in the snapshot
- https://news.ycombinator.com/item?id=50497155: thread in the snapshot
- https://news.ycombinator.com/item?id=50497513: thread in the snapshot
- https://news.ycombinator.com/item?id=50497248: thread in the snapshot
- https://news.ycombinator.com/item?id=50497375: thread in the snapshot
- https://news.ycombinator.com/item?id=50497330: thread in the snapshot
- https://news.ycombinator.com/item?id=50497196: thread in the snapshot
- https://news.ycombinator.com/item?id=50497522: thread in the snapshot
- https://news.ycombinator.com/item?id=50497158: thread in the snapshot

**Tokens:** loop 15161 in / 3432 out · summary 0 in / 0 out

#### New Agent

**Tool calls:**

1. `list_latest`  → 30 threads

**Answer:**

Here are some picks from the 30 newest stories. The list doesn't show scores, so I'm choosing by title and the short excerpts only. I haven't opened the articles or comment threads.

**Worth a look:**
- [The Challenge of Flying Below Sea Level](https://news.ycombinator.com/item?id=50497470): an engineering and geography topic with broad appeal.
- [Tokenizer Fairness in 2026](https://news.ycombinator.com/item?id=50497519): a technical AI topic that could be useful if you follow model design.
- [Amazon has a plan to index the online shopping data](https://news.ycombinator.com/item?id=50497330): a story about data and platform power.
- [DJI Gives ROMO 2 Its Drone Offline Mode, Eight Months After the Hack](https://news.ycombinator.com/item?id=50497399): a security follow-up with a clear arc.
- [Serving GLM-5.3 at 607.8 tok/s across two Nvidia DGX stations with vLLM](https://news.ycombinator.com/item?id=50497155): an inference performance write-up, and it already has 8 posts for discussion.

**If you like tools and projects:**
- [Show HN: SrcWranglr v0.13, a C/C++ Graphical Code Explorer for Vuln. Research](https://news.ycombinator.com/item?id=50497513): a Rust-based code-analysis tool for security work.
- [Show HN: Epistemic News, re-ranking HN comments](https://news.ycombinator.com/item?id=50497248): an experiment in ranking comments by quality.
- [Show HN: Burrmill, SQL over Parquet with exact integer arithmetic](https://news.ycombinator.com/item?id=50497375): a niche but practical data tool.

**Offbeat:**
- [Porting Elite to the Commodore PET the long way [video]](https://news.ycombinator.com/item?id=50497171)
- [Shadow DOM (2014)](https://news.ycombinator.com/item?id=50497340): an older article that is still relevant to web components.

If you tell me whether you want the current front page (ranked by votes) or a specific topic, I can search for it.

**Citations:** 10, 10 a thread in the snapshot

- https://news.ycombinator.com/item?id=50497470: thread in the snapshot
- https://news.ycombinator.com/item?id=50497519: thread in the snapshot
- https://news.ycombinator.com/item?id=50497330: thread in the snapshot
- https://news.ycombinator.com/item?id=50497399: thread in the snapshot
- https://news.ycombinator.com/item?id=50497155: thread in the snapshot
- https://news.ycombinator.com/item?id=50497513: thread in the snapshot
- https://news.ycombinator.com/item?id=50497248: thread in the snapshot
- https://news.ycombinator.com/item?id=50497375: thread in the snapshot
- https://news.ycombinator.com/item?id=50497171: thread in the snapshot
- https://news.ycombinator.com/item?id=50497340: thread in the snapshot

**Tokens:** loop 19178 in / 1053 out · summary 0 in / 0 out

| Owner verdict | |
|---|---|
| New better, same, or worse | worse |
| Note | Old better: new only lists titles. |

### H5

**Question:** What do commenters here say about running Litestream for SQLite backups in production?

**Starting page:** https://news.ycombinator.com/

**Snapshot misses:** https://hn.algolia.com/api/v1/search?tags=story&query=Litestream%20SQLite%20backup%20production&page=0&hitsPerPage=20

#### Old Research

**Tool calls:**

1. `search_forum` query=Litestream SQLite backups production → 2 topics
1. `search_comments` query=Litestream → 7 topics
1. `read_topic` topic_id=49501147 → Read 8 posts

**Answer:**

## What commenters say about Litestream for SQLite in production

The site has only a small amount of discussion on this, and most of it comes from a few threads. Treat these as anecdotes, not a broad survey.

**Most direct discussion: [Running SQLite Apps on Docker and Kubernetes with Litestream](https://news.ycombinator.com/item?id=49501147)**
- The OpenRun author describes built-in Litestream replication and automatic restore. Apps can use SQLite without code changes on a single Docker/Podman node or on Kubernetes.
- A commenter (sighansen) runs SQLite on ephemeral pods that restore the latest Litestream backup from object storage at startup. They report no issues so far, a restore that takes a few seconds, and no need for persistent volumes. They also say they don't store anything near terabyte scale.
- The OpenRun author replies that without persistent volumes, each deployment may need a restore from S3, which can be slow for large databases. With a PVC, normal deploys reuse the existing database and only disaster recovery restores from S3.
- simonw asked how two OpenRun instances sharing one S3 Litestream store would avoid corrupting it. The author says generated S3 paths include a binding ID that should be unique per instance, and that they will look at further safeguards. This is an open design concern, not a settled answer.
- solatic argues SQLite is fine for small production workloads but is hard to move if you later need to scale.

**Other relevant comments**
- In [Twelve years of distributed SQLite](https://news.ycombinator.com/item?id=50217500), rapind recommends one beefier box with in-process SQLite plus Litestream backups to object storage, instead of distributed SQLite. gizzlon says SQLite plus Litestream has been "safe enough" for them, with some data loss acceptable in extreme cases, and they have been looking for a reason to try rqlite.
- In [What I self-host](https://news.ycombinator.com/item?id=50109715), skrtskrt mentions Litestream as part of the newer SQLite tooling ecosystem alongside Turso.
- In [Engrim, a local-first SQLite memory engine](https://news.ycombinator.com/item?id=49594008), timgordontg says the database is a plain SQLite file, so Litestream or Syncthing works, provided WAL files are handled correctly.

**Summary**
The commenters who mention running Litestream in production report it as workable for small to moderate data sizes, with fast restores and a simple, single-writer setup. The concerns raised are restore time for larger databases, the risk of multiple writers or instances sharing one replica path, and the difficulty of moving off SQLite if you later need to scale. The site does not establish any large-scale production track record for Litestream.

**Citations:** 4, 4 a thread in the snapshot

- https://news.ycombinator.com/item?id=49501147: thread in the snapshot
- https://news.ycombinator.com/item?id=50217500: thread in the snapshot
- https://news.ycombinator.com/item?id=50109715: thread in the snapshot
- https://news.ycombinator.com/item?id=49594008: thread in the snapshot

**Tokens:** loop 9320 in / 1659 out · summary 0 in / 0 out

#### New Agent

**Tool calls:**

1. `search_forum` "Litestream SQLite backup production" → 1 thread
1. `search_comments` "Litestream" → 10 comments
1. `search_forum` "Litestream" → 20 threads
1. `summarize_topic` topic 39065201 → Ask HN: Are you using SQLite and Litestream in production?
1. `summarize_topic` topic 45581761 → Hold Off on Litestream 0.5.0
1. `summarize_topic` topic 49501147 → Running SQLite Apps on Docker and Kubernetes with Litestream

**Answer:**

Commenters are generally positive about Litestream for small, single-server production setups, but they raise specific caveats: the 0.5.0 release, restore times, retention settings, and write limits.

**Positives**
- Operations are simple. In the [Ask HN thread on SQLite and Litestream in production](https://news.ycombinator.com/item?id=39065201), several people say it needs little upkeep. One replicated to Cloudflare R2 and said it "Just Worked," and another ran a Pocketbase app with Litestream for about two years with no maintenance.
- Cost is low. One developer streams to Backblaze B2 for effectively $0 a month on a single $14 droplet, and has never needed to restore (same thread).
- Containers work if configured carefully. In the same thread, one ECS setup runs Litestream as a daemon task that starts before the app and shares a volume with it.
- In a [thread on running SQLite on Docker and Kubernetes with Litestream](https://news.ycombinator.com/item?id=49501147), one user runs ephemeral pods that restore from object storage on startup. They report restores take a few seconds at their data size and have had no issues.

**Caveats**
- **Litestream 0.5.0:** The [Hold Off on Litestream 0.5.0 thread](https://news.ycombinator.com/item?id=45581761) advises waiting. Commenters report problems, mostly with transient read failures in read-replica use. Several recommend 0.5.1 instead, or staying on 0.3.x if you're on production. The author, Ben Johnson, said the move to the new LTX file format was the biggest hurdle. The thread also covers a possible Backblaze issue that the poster didn't hit.
- **Retention and snapshots:** In the Ask HN thread, one commenter warns that with retention and snapshot intervals both at the default 24 hours, you don't actually get 24 hours of history. They also advise testing restore times, because replaying a day of WAL can be slow in an emergency.
- **Restore time vs. storage:** The Kubernetes thread notes that ephemeral pods must restore on every deploy, which gets slow for large databases. Persistent volumes avoid that, at the cost of needing restores only for disaster recovery.
- **Network filesystems:** One user found SQLite very slow on EFS because locking happens over the network, and moved to local EBS (Ask HN thread). The general advice is to keep SQLite on local disks or volumes.
- **Multiple writers:** In the Kubernetes thread, simonw asked whether two instances sharing one S3 Litestream path could corrupt each other's backups. Make sure only one writer uses a given path and use unique prefixes per instance.
- **Corruption worries:** One large-scale team backed away from Litestream after an issue report made them nervous about corruption, and they use snapshots with remote backups instead (Ask HN thread). The thread doesn't establish how serious that risk is in practice.
- **Write contention and monitoring:** Some users hit write conflicts between web servers and workers and are considering Postgres. Others note SQLite lacks ready-made slow-query tooling (Ask HN thread).

**Limits of this answer**
- The Ask HN thread is from January 2024, and the 0.5.0 discussion is from 2025, so newer experience may differ.
- I based this on automated summaries of the threads rather than reading every comment, so the specific claims are as the summaries report them.

Sources:
- [Ask HN: Are you using SQLite and Litestream in production?](https://news.ycombinator.com/item?id=39065201)
- [Hold Off on Litestream 0.5.0](https://news.ycombinator.com/item?id=45581761)
- [Running SQLite Apps on Docker and Kubernetes with Litestream](https://news.ycombinator.com/item?id=49501147)

**Citations:** 3, 3 a thread in the snapshot

- https://news.ycombinator.com/item?id=39065201: thread in the snapshot
- https://news.ycombinator.com/item?id=49501147: thread in the snapshot
- https://news.ycombinator.com/item?id=45581761: thread in the snapshot

**Tokens:** loop 45298 in / 1997 out · summary 10429 in / 7172 out

| Owner verdict | |
|---|---|
| New better, same, or worse | new better |
| Note | New better; its "Backblaze issue" detail is unsupported. |

### W1

**Question:** 这里的文章和读者怎么看 US Bank Smartly Visa 卡改版后的变化？

**Starting page:** https://www.doctorofcredit.com/

**Snapshot misses:** https://www.doctorofcredit.com/wp-json/wp/v2/comments?search=Smartly%20Visa&per_page=10&page=1&order=desc&orderby=date_gmt&_fields=id,post,parent,author_name,date_gmt,content, https://www.doctorofcredit.com/wp-json/wp/v2/posts?include=267097,262264,226038,254097,215946,241557,260501,65276,253208&per_page=9&_fields=id,title,link

#### Old Research

**Tool calls:**

1. `search_forum` query=US Bank Smartly Visa → 20 topics
1. `search_forum` query=Smartly card changes benefits → 13 topics
1. `read_topic` topic_id=235791 → Read 294 posts
1. `read_topic` topic_id=236854 → Read 150 posts
1. `search_forum` after=2025-06-01 query=Smartly nerf existing cardholders → 9 topics
1. `read_topic` topic_id=241557 → Read 377 posts

**Answer:**

## 结论

站内没有一篇文章专门描述一次统一的“改版”。变化是 2025 年分几步发生的：先是 3 月的传闻重做，接着 4 月新申请人拿到更差的 v1.1，9 月现有持卡人也被下调。读者的整体看法是：原版 4% 很诱人，但 U.S. Bank 的改动一再削弱它，大家不再把它当成长期稳定的产品。

## 主要变化（站内文章）

1. **2025 年 3 月：传闻停发/重做。** 文章称新申请暂停数周，正在重做，引用 Reddit 与分行人员的说法，未经官方确认。[\[Rumor\] U.S. Bank Smartly Visa Credit Card To Be Discontinued](https://www.doctorofcredit.com/rumor-u-s-bank-smartly-visa-credit-card-to-be-discontinued/)

2. **2025 年 4 月 14 日：新申请人改为 v1.1（更差版本）。**
   - 只有支票账户余额计入档位，储蓄和券商账户不计。
   - 2.5% 档门槛从 $5k 提高到 $10k；3% 和 4% 档仍为 $50k 与 $100k。
   - 余额按 30 天平均计算，旧版为 90 天。
   - 4% 等优惠每期最多 $10,000 消费，超过后为基础 2%。
   - 税款、B2B、保险、教育、第三方账单支付、礼品卡等不享受加成。
   - 4 月 13 日前已批准的老卡继续享有旧规则。[Big Changes Coming For New U.S. Bank Smartly Credit Card Approvals](https://www.doctorofcredit.com/big-changes-coming-for-new-u-s-bank-smartly-credit-card-approvals-no-changes-now-for-existing-customers-april-14th-cutoff/)

3. **2025 年 9 月 15 日：现有持卡人也被削减。** 现有持卡人收到通知：基础 2% 不设上限；额外 2% 仅限每期前 $10,000，并需要 $100k+ 合格余额才能达到 4%。税款、礼品卡、保险、教育、B2B 和第三方账单支付不计入加成。文章称读者分成“good nerf”和“bad nerf”两组：一组仍可计入投资账户，另一组不能；站内未说明分组标准。[\[Update\] U.S. Bank Nerfs Existing Smartly Cardholders On September 15, 2025](https://www.doctorofcredit.com/u-s-bank-to-nerf-existing-smartly-cardholders-on-september-15/)

4. **其他相关变化（仅见搜索摘要，未逐篇读取）：** 储蓄账户 APY 从 3.60% 降到 3.00%（[链接](https://www.doctorofcredit.com/u-s-bank-smartly-savings-account-3-00-apy/)）；2026 年 1 月称券商免费交易福利将结束（[链接](https://www.doctorofcredit.com/u-s-bank-smartly-brokerage-100-free-trades-benefit-ends-in-february-2026/)）。

## 读者怎么看

- **普遍认为是“先诱人、后收缩”。** 2025 年 3 月的评论中，有人批评这种做法损害信誉，也有人认为本来就不可持续。[Rumor 讨论串](https://www.doctorofcredit.com/rumor-u-s-bank-smartly-visa-credit-card-to-be-discontinued/)
- **对新申请人，多数人认为不划算。** 4 月的讨论指出，支票账户需要存 $10k 甚至 $100k，而支票利息很低，损失的利息可能抵消 4% 的收益。[Big Changes 讨论串](https://www.doctorofcredit.com/big-changes-coming-for-new-u-s-bank-smartly-credit-card-approvals-no-changes-now-for-existing-customers-april-14th-cutoff/)
- **对老卡持有人，意见分化。** 有人认为 4% 对日常消费仍然不错，只要券商资产能计入；也有人因税款、保险被排除而损失大。[Nerf 讨论串](https://www.doctorofcredit.com/u-s-bank-to-nerf-existing-smartly-cardholders-on-september-15/)
- **对 U.S. Bank 的信任下降。** 有读者称客服口径不一，且难以判断每笔消费是否享受加成。

## 站内无法确认的内容

- 没有找到 2026 年的官方“再次改版”文章。2026 年的评论多为个人经历（如卡片从金属换为塑料的说法、客服口径冲突），不足以当作定论。
- 关闭 Smartly 支票账户是否影响老卡 4% 资格，站内只有读者讨论，没有官方说明；有读者建议在获得书面确认前不要这样做。[Nerf 讨论串（2026 年评论）](https://www.doctorofcredit.com/u-s-bank-to-nerf-existing-smartly-cardholders-on-september-15/)

## 小结

脉络是：2025 年 3 月传闻，4 月新申请降级，9 月老卡降级。读者的主流看法是这张卡的高返现已不稳定，新申请基本不值得办，老卡持有人则需看自己能否计入投资余额，并随时准备应对进一步调整。

**Citations:** 5, 5 a thread in the snapshot

- https://www.doctorofcredit.com/rumor-u-s-bank-smartly-visa-credit-card-to-be-discontinued/: thread in the snapshot
- https://www.doctorofcredit.com/big-changes-coming-for-new-u-s-bank-smartly-credit-card-approvals-no-changes-now-for-existing-customers-april-14th-cutoff/: thread in the snapshot
- https://www.doctorofcredit.com/u-s-bank-to-nerf-existing-smartly-cardholders-on-september-15/: thread in the snapshot
- https://www.doctorofcredit.com/u-s-bank-smartly-savings-account-3-00-apy/: thread in the snapshot
- https://www.doctorofcredit.com/u-s-bank-smartly-brokerage-100-free-trades-benefit-ends-in-february-2026/: thread in the snapshot

**Tokens:** loop 195871 in / 6267 out · summary 0 in / 0 out

#### New Agent

**Tool calls:**

1. `search_forum` "US Bank Smartly Visa" → 20 threads
1. `search_comments` "Smartly" → 10 comments
1. `search_forum` "Smartly card changes benefits" → 13 threads
1. `search_comments` "Smartly Visa" → 10 comments
1. `read_topic` #236854 → saved to results/3B840B52-EAA0-4DB7-947B-2CB1FD7C4501/05-read_topic.txt
1. `read_topic` #241557 → saved to results/3B840B52-EAA0-4DB7-947B-2CB1FD7C4501/06-read_topic.txt
1. `read_topic` #235791 → saved to results/3B840B52-EAA0-4DB7-947B-2CB1FD7C4501/07-read_topic.txt

**Answer:**

这里的文章和读者主要讨论了 2025 年的两次改版。我读了三篇相关文章和其中的评论，没有查到 2026 年的官方条款变动，因此以下是站内讨论的情况，不是银行的最新官方说明。

**两次改版**

1. **2025 年 4 月 14 日：新申请人的 v1.1 版本。** 文章称，新版的主要变化是：只有支票账户余额计入奖励档位，储蓄和投资不计；进入 2.5% 档需要 1 万美元支票余额（旧版为 5 千）；余额按 30 天平均计算（旧版为 90 天）；4% 等较高档位每个账单周期只限 1 万美元消费；税款、B2B、保险、教育、第三方账单支付等不再享受加成。旧版持卡人仍保留原规则。[Big Changes Coming For New U.S. Bank Smartly Credit Card Approvals](https://www.doctorofcredit.com/big-changes-coming-for-new-u-s-bank-smartly-credit-card-approvals-no-changes-now-for-existing-customers-april-14th-cutoff/)

2. **2025 年 9 月 15 日：对老持卡人的削减。** 通知称，老持卡人仍有无上限的 2% 返现，额外 2% 需要配合 Smartly Savings，并且平均合格余额达到 10 万美元以上；同时税款、教育/礼品卡、保险、B2B 和第三方账单支付不计入额外 2%。文章还提到持卡人分成“good nerf”和“bad nerf”两组，前者仍可计入投资账户，后者不行，原因不明。[[Update] U.S. Bank Nerfs Existing Smartly Cardholders On September 15, 2025](https://www.doctorofcredit.com/u-s-bank-to-nerf-existing-smartly-cardholders-on-september-15/)

**作者的看法**

Chuck 在 2025 年 4 月的文章中认为，不计入储蓄账户使阶梯基本不可用，并说自己平均余额不到 1 万，因此不会觉得有用，还提到不得不逐笔判断消费类别很麻烦。[Big Changes Coming…](https://www.doctorofcredit.com/big-changes-coming-for-new-u-s-bank-smartly-credit-card-approvals-no-changes-now-for-existing-customers-april-14th-cutoff/) 9 月的更新中，作者则说明了通知内容和分组情况，没有给出明确的个人结论。

**读者的看法**

- **仍有人认可：** 有读者认为，老持卡人在 1 万美元内仍能拿到 4%，“仍然不错”，也有人说它仍是日常主力卡。[U.S. Bank Nerfs Existing Smartly Cardholders](https://www.doctorofcredit.com/u-s-bank-to-nerf-existing-smartly-cardholders-on-september-15/)
- **普遍不满：** 税款、保险、礼品卡等被排除是最常被提到的痛点。也有人认为银行“变卦”太快，对 Smartly 的信任度下降。同上链接。
- **对新版怀疑：** 新申请人需要长期保留 1 万美元以上支票余额，读者普遍认为这会损失不少利息，并让这张卡的吸引力大幅下降。[Big Changes Coming…](https://www.doctorofcredit.com/big-changes-coming-for-new-u-s-bank-smartly-credit-card-approvals-no-changes-now-for-existing-customers-april-14th-cutoff/)
- **执行上的困惑：** 9 月后，有人发现交易先显示为 2%，要等账单出来才可能显示为 4%；也有人发现房租、Bilt、公用事业等类别的结果并不一致，银行也无法提供明确的排除 MCC 清单。[U.S. Bank Nerfs Existing Smartly Cardholders](https://www.doctorofcredit.com/u-s-bank-to-nerf-existing-smartly-cardholders-on-september-15/)
- **对关闭支票账户的警惕：** 2026 年 7 月的一条评论认为，不应该为了churn 支票奖金而关掉 Smartly 支票账户，因为现行条款把额外奖励和 Smartly Savings 及合格余额挂钩，无法确定是否会影响老卡的 4% 资格。同上链接。

**需要注意**

- 讨论主要来自 2025 年的文章。评论区中有 2026 年的反馈，如卡片改为金属卡、Kroger 卡转为 Smartly 等，但我没有读取相关文章全文，只看到评论或搜索摘要。
- 评论多为个人经验，不能代表全部持卡人。站内也没有确认 2026 年的最新条款，具体规则应以 U.S. Bank 的官方说明为准。

**Citations:** 2, 2 a thread in the snapshot

- https://www.doctorofcredit.com/big-changes-coming-for-new-u-s-bank-smartly-credit-card-approvals-no-changes-now-for-existing-customers-april-14th-cutoff/: thread in the snapshot
- https://www.doctorofcredit.com/u-s-bank-to-nerf-existing-smartly-cardholders-on-september-15/: thread in the snapshot

**Tokens:** loop 81418 in / 3065 out · summary 0 in / 0 out

| Owner verdict | |
|---|---|
| New better, same, or worse | same |
| Note | About equal; new says the card "changed to metal" while comments say replacements came in plastic. |

### W2

**Question:** In the post "[Targeted] Chase Travel: Spend $600+ & Receive $100 Back" (https://www.doctorofcredit.com/?p=229112), does checking out multiple separate hotel bookings together in one Chase Travel cart count as a single transaction to trigger the $100 credit?

**Starting page:** https://www.doctorofcredit.com/?p=229112

**Snapshot misses:** https://www.doctorofcredit.com/wp-json/wp/v2/comments?search=single%20transaction%20cart&per_page=10&page=1&order=desc&orderby=date_gmt&_fields=id,post,parent,author_name,date_gmt,content, https://www.doctorofcredit.com/wp-json/wp/v2/comments?search=cart&per_page=10&page=1&order=desc&orderby=date_gmt&_fields=id,post,parent,author_name,date_gmt,content, https://www.doctorofcredit.com/wp-json/wp/v2/posts?include=268365,268674,229112,207182,162972,268568,263474,238498&per_page=8&_fields=id,title,link

#### Old Research

**Tool calls:**

1. `read_topic` topic_id=229112 → Read 317 posts

**Answer:**

## Short answer

The site does not settle this definitively. The most specific terms quoted by readers require the $600 to be met in a single transaction, but one recent reader reports that a multi-hotel cart did qualify.

## What the evidence shows

- **Quoted terms require one transaction.** Reader Jarrett posted the July 2026 offer language: "A minimum spend of $600 must be met in a single transaction... multiple transactions totaling $600 do not qualify." This is quoted in a reader comment, not the article body. ([[Targeted] Chase Travel: Spend $600+ & Receive $100 Back](https://www.doctorofcredit.com/targeted-chase-travel-spend-500-receive-100-back/), comment #261)
- **A recent reader reports a multi-hotel cart worked.** Justine (Nov 12, 2026) booked three nights at three different hotels, checked out in one cart, and says it posted as one transaction over $600 and earned the $100. This is a single anecdote. ([same post](https://www.doctorofcredit.com/targeted-chase-travel-spend-500-receive-100-back/), comment #317)
- **Older, unverified report.** In 2024, reader KS said a Chase representative told them several purchases could count, but this was secondhand. ([same post](https://www.doctorofcredit.com/targeted-chase-travel-spend-500-receive-100-back/), comment #48)
- **The article body is outdated.** The main text shows 2024 terms, which say payment must be made by the expiration date and do not address single versus multiple transactions.

## Other caveats

- Readers report different thresholds this round: $600 for some cards and $800 for others (comments #308 to #311). Check the amount on your own offer.
- Offers are card-targeted, so the offer must be on the card you pay with (comment #286).
- One update notes that abuse of offers may lead to exclusion from future offers.

## Practical takeaway

Multiple hotel stays in one cart may count, based on the most recent reader report. The quoted terms, however, say a single transaction is required, so the site does not guarantee it. For certainty, check the exact terms on your Chase Offers page, or book stays that meet the threshold within one booking, and confirm with Chase before relying on the cart combination.

**Citations:** 1, 1 a thread in the snapshot

- https://www.doctorofcredit.com/targeted-chase-travel-spend-500-receive-100-back/: thread in the snapshot

**Tokens:** loop 30591 in / 2815 out · summary 0 in / 0 out

#### New Agent

**Tool calls:**

1. `read_topic` #229112 → saved to results/6C802104-3EA6-4935-8107-5CABFAA3EB0B/01-read_topic.txt
1. `search_comments` "single transaction cart" → 0 comments
1. `read_topic` #229112 · "multiple purchases one transaction cart total" → 317 posts (saved to results/6C802104-3EA6-4935-8107-5CABFAA3EB0B/03-read_topic.txt)
1. `search_comments` "cart" → 10 comments
1. `file_read` results/6C802104-3EA6-4935-8107-5CABFAA3EB0B/03-read_topic.txt → 12,000 of 23,674

**Answer:**

**Probably yes, based on one recent reader report, but the site doesn't confirm it.**

- **Most direct evidence:** A reader says they booked three nights at three different hotels, had them all in the Chase Travel cart, and checked out in one transaction. It posted as one charge over $600 and they got the $100 back. (Justine, Nov 12, 2026 in [Targeted] Chase Travel: Spend $600+ & Receive $100 Back, https://www.doctorofcredit.com/targeted-chase-travel-spend-500-receive-100-back/)
- **Reader consensus on "one transaction":** Earlier commenters concluded the spend has to be a single transaction. One wrote "It has to be $500 or more in one transaction" (Oct 2024), and another said "I never bought into that it can be used over multiple transactions" (Nov 2024). Another suggested making the total charge reach the threshold at the time of purchase (May 2025). All in the same post.
- **Conflicting report:** One 2024 reader said a Chase representative told them several purchases could count. That is secondhand and was not confirmed by anyone else in the thread.
- **Not established:** The article's fine print only says "spend $600 or more" on a Chase Travel purchase, and the listed expiration date is outdated. The site doesn't quote Chase saying whether a multi-booking cart counts as one purchase. Also, a later commenter reports the required amount is now $800 for their targeted offer (Nov 1, 2026), so check the amount shown in your Chase Offers.

**Practical approach:** Put all the bookings in one cart and pay in a single checkout. Confirm the total on your offer, since it may be $600 or $800. Screenshot the offer while it's still active and the final receipt. Keep in mind that the thread also discusses cancelling bookings after the credit posts, and the offer's terms now warn that abuse may lead to exclusion from future offers.

**Citations:** 0, 0 a thread in the snapshot

**Tokens:** loop 70221 in / 1927 out · summary 0 in / 0 out

| Owner verdict | |
|---|---|
| New better, same, or worse | worse |
| Note | Old better: new missed the July 2026 "single transaction" terms in the snapshot and has zero linked citations. |

### W3

**Question:** Summarize the post "Year-End Credit Card Checklist for 2026: Travel Credits, Spend Reset, Application Strategy & More" (https://www.doctorofcredit.com/?p=268506), then find what others here say about the year-end double-dip strategy for the Amex Platinum, Citi Strata Elite and Bank of America Premium Rewards Elite cards.

**Starting page:** https://www.doctorofcredit.com/?p=268506

**Snapshot misses:** https://www.doctorofcredit.com/wp-json/wp/v2/posts?search=year-end%20double%20dip%20Amex%20Platinum%20Citi%20Strata%20Elite%20Bank%20of%20America%20Premium%20Rewards%20Elite&per_page=20&page=1&_fields=id,title,link,date_gmt,excerpt,author,_embedded,_links&_embed=author, https://www.doctorofcredit.com/wp-json/wp/v2/posts?search=double%20dip%20Platinum&per_page=20&page=1&_fields=id,title,link,date_gmt,excerpt,author,_embedded,_links&_embed=author, https://www.doctorofcredit.com/wp-json/wp/v2/posts?search=Strata%20Elite%20double%20dip&per_page=20&page=1&_fields=id,title,link,date_gmt,excerpt,author,_embedded,_links&_embed=author, https://www.doctorofcredit.com/wp-json/wp/v2/posts?search=Premium%20Rewards%20Elite%20double%20dip&per_page=20&page=1&_fields=id,title,link,date_gmt,excerpt,author,_embedded,_links&_embed=author, https://www.doctorofcredit.com/wp-json/wp/v2/comments?search=Strata%20Elite&per_page=10&page=1&order=desc&orderby=date_gmt&_fields=id,post,parent,author_name,date_gmt,content, https://www.doctorofcredit.com/wp-json/wp/v2/posts?include=268611,261214,253742,267595,267607,266928,201403,223265,265714&per_page=9&_fields=id,title,link, https://www.doctorofcredit.com/wp-json/wp/v2/posts/241605?_fields=id,title,link,modified_gmt, https://www.doctorofcredit.com/wp-json/wp/v2/comments?post=241605&per_page=1&page=1&order=asc&orderby=date_gmt&_fields=id, https://www.doctorofcredit.com/wp-json/wp/v2/posts/241605?_fields=id,title,link,date_gmt,modified_gmt,content,author,_embedded,_links&_embed=author, https://www.doctorofcredit.com/wp-json/wp/v2/comments?post=241605&per_page=100&page=1&order=asc&orderby=date_gmt&_fields=id,parent,author_name,date_gmt,content, https://www.doctorofcredit.com/wp-json/wp/v2/comments?post=241605&per_page=100&page=2&order=asc&orderby=date_gmt&_fields=id,parent,author_name,date_gmt,content, https://www.doctorofcredit.com/wp-json/wp/v2/comments?post=241605&per_page=100&page=3&order=asc&orderby=date_gmt&_fields=id,parent,author_name,date_gmt,content, https://www.doctorofcredit.com/wp-json/wp/v2/posts/244430?_fields=id,title,link,modified_gmt, https://www.doctorofcredit.com/wp-json/wp/v2/comments?post=244430&per_page=1&page=1&order=asc&orderby=date_gmt&_fields=id, https://www.doctorofcredit.com/wp-json/wp/v2/posts/244430?_fields=id,title,link,date_gmt,modified_gmt,content,author,_embedded,_links&_embed=author, https://www.doctorofcredit.com/wp-json/wp/v2/comments?post=244430&per_page=100&page=1&order=asc&orderby=date_gmt&_fields=id,parent,author_name,date_gmt,content, https://www.doctorofcredit.com/wp-json/wp/v2/comments?post=244430&per_page=100&page=2&order=asc&orderby=date_gmt&_fields=id,parent,author_name,date_gmt,content, https://www.doctorofcredit.com/wp-json/wp/v2/comments?post=244430&per_page=100&page=3&order=asc&orderby=date_gmt&_fields=id,parent,author_name,date_gmt,content, https://www.doctorofcredit.com/wp-json/wp/v2/posts/241171?_fields=id,title,link,modified_gmt, https://www.doctorofcredit.com/wp-json/wp/v2/comments?post=241171&per_page=1&page=1&order=asc&orderby=date_gmt&_fields=id, https://www.doctorofcredit.com/wp-json/wp/v2/posts/241171?_fields=id,title,link,date_gmt,modified_gmt,content,author,_embedded,_links&_embed=author, https://www.doctorofcredit.com/wp-json/wp/v2/comments?post=241171&per_page=100&page=1&order=asc&orderby=date_gmt&_fields=id,parent,author_name,date_gmt,content, https://www.doctorofcredit.com/wp-json/wp/v2/comments?post=241171&per_page=100&page=2&order=asc&orderby=date_gmt&_fields=id,parent,author_name,date_gmt,content, https://www.doctorofcredit.com/wp-json/wp/v2/comments?post=241171&per_page=100&page=3&order=asc&orderby=date_gmt&_fields=id,parent,author_name,date_gmt,content, https://www.doctorofcredit.com/wp-json/wp/v2/comments?post=241171&per_page=100&page=4&order=asc&orderby=date_gmt&_fields=id,parent,author_name,date_gmt,content, https://www.doctorofcredit.com/wp-json/wp/v2/posts?search=Bank%20of%20America%20Premium%20Rewards%20Elite&per_page=20&page=1&_fields=id,title,link,date_gmt,excerpt,author,_embedded,_links&_embed=author, https://www.doctorofcredit.com/wp-json/wp/v2/posts/257893?_fields=id,title,link,modified_gmt, https://www.doctorofcredit.com/wp-json/wp/v2/comments?post=257893&per_page=1&page=1&order=asc&orderby=date_gmt&_fields=id, https://www.doctorofcredit.com/wp-json/wp/v2/posts/257893?_fields=id,title,link,date_gmt,modified_gmt,content,author,_embedded,_links&_embed=author, https://www.doctorofcredit.com/wp-json/wp/v2/comments?post=257893&per_page=100&page=1&order=asc&orderby=date_gmt&_fields=id,parent,author_name,date_gmt,content

#### Old Research

**Tool calls:**

1. `summarize_topic` topic_id=268506 → Summarized 13 posts
1. `search_forum` after=2025-06-01 query=double dip year-end Amex Platinum Citi Strata Elite Bank of America Premium Rewards Elite → 0 topics
1. `search_forum` query=double dip Amex Platinum Strata Elite → 8 topics
1. `search_comments` query=double dip → 6 topics
1. `search_comments` query=Strata Elite year end → 0 topics

**Answer:**

## 1. Summary of the checklist post

**[Year-End Credit Card Checklist for 2026: Travel Credits, Spend Reset, Application Strategy & More](https://www.doctorofcredit.com/year-end-credit-card-checklist-for-2026-travel-credits-spend-reset-application-strategy-more/)** (Chuck, updated November 10, 2026)

- **Purpose:** An annual checklist of card benefits, spend limits, and requirements that expire or reset on December 31. It also covers which cards to apply for before year-end, since applications can capture a "double-dip" of benefits, with a possible "triple-dip" the next year. The Amex Platinum, Citi Strata Elite, and Bank of America Premium Rewards Elite are highlighted for this.
- **Structure:** Organized by calendar-year spend limits, calendar-year spend requirements, and then by issuer. Each entry says whether a benefit resets on the calendar year, the card anniversary, or the cardmember year.
- **Key dates:**
  - Chase Sapphire Reserve's $250 hotel credit is for 2026 only.
  - Southwest Companion Pass rules change in 2027. Signup bonus points stop counting, but approvals by December 2, 2026 are grandfathered.
  - Bilt Flexible Cash opt-in closes December 31, 2026.
  - Several Citi, Chase, and Bilt benefits change on or after January 1, 2027.
- **Year-end tips from the article:** Use calendar-year credits before December 31, such as Amex Platinum airline and hotel credits, Bank of America's $100 airline incidental credit, and Citi Prestige's $250 travel credit. Allow time for pending charges to post. Set your designated airline before using Amex airline credits. Finish spending now if close to spend thresholds such as the Sapphire Reserve's $75,000. Push referrals before year-end, since referral limits reset January 1.

## 2. What others say about the year-end double-dip for these three cards

**The site does not establish this.** I found no reader discussion of the year-end double-dip strategy for the Amex Platinum, Citi Strata Elite, or Bank of America Premium Rewards Elite.

- Searches for the double-dip and the card names returned only the checklist and card-specific benefit posts.
- Comment searches for "double dip" and "Strata Elite year end" returned only bank-bonus and portal double dips, such as [U.S. Bank business checking](https://www.doctorofcredit.com/u-s-bank-400-900-business-checking-bonus/), [Wells Fargo business checking](https://www.doctorofcredit.com/wells-fargo-400-825-business-checking-bonus/), and [Mercury business checking](https://www.doctorofcredit.com/mercury-fintech-500-business-checking-bonus/). These are unrelated to the three named cards.
- The closest reader material is the checklist's comment thread. It holds corrections and gap-filling on Amex referral limits, Sapphire Reserve and Venture X spend benefits, and United Quest discounts, but nothing on the double-dip for these cards.
- The double-dip and triple-dip application advice comes from the article itself, not from readers.

If you want reader views, try searching the site for the individual card names with the word "welcome offer" or "application," or check the comments on the individual card posts.

**Citations:** 4, 4 a thread in the snapshot

- https://www.doctorofcredit.com/year-end-credit-card-checklist-for-2026-travel-credits-spend-reset-application-strategy-more/: thread in the snapshot
- https://www.doctorofcredit.com/u-s-bank-400-900-business-checking-bonus/: thread in the snapshot
- https://www.doctorofcredit.com/wells-fargo-400-825-business-checking-bonus/: thread in the snapshot
- https://www.doctorofcredit.com/mercury-fintech-500-business-checking-bonus/: thread in the snapshot

**Tokens:** loop 25251 in / 2651 out · summary 16733 in / 2443 out

#### New Agent

**Tool calls:**

1. `read_topic` #268506 → saved to results/CA9FB6B0-6790-4170-9CC6-975CEE36FAE8/01-read_topic.txt
1. `search_forum` "year-end double dip Amex Platinum Citi Strata Elite Bank of America Premium Rewards Elite" → 0 threads
1. `file_read` results/CA9FB6B0-6790-4170-9CC6-975CEE36FAE8/01-read_topic.txt @ 9000 → 20,000 of 42,068
1. `search_forum` "double dip Platinum" → 20 threads
1. `search_forum` "Strata Elite double dip" → 10 threads
1. `search_forum` "Premium Rewards Elite double dip" → 20 threads
1. `file_read` results/CA9FB6B0-6790-4170-9CC6-975CEE36FAE8/01-read_topic.txt @ 29000 → 13,068 of 42,068
1. `search_comments` "double dip" → 10 comments
1. `search_comments` "Strata Elite" → 10 comments
1. `read_topic` #241605 · "double dip triple dip year-end" → 215 posts
1. `read_topic` #244430 · "double dip triple dip" → 230 posts
1. `read_topic` #241171 · "double dip triple dip" → 399 posts
1. `search_forum` "Bank of America Premium Rewards Elite" → 20 threads
1. `read_topic` #257893 · "double dip triple dip credits year" → 61 posts

**Answer:**

## Summary of the article

The post is Chuck's annual year-end checklist, updated November 10, 2026. It lists benefits, spend limits and credits that reset on January 1, and which cards are worth applying for now. It also has a 13-post comment thread. [Year-End Credit Card Checklist for 2026](https://www.doctorofcredit.com/year-end-credit-card-checklist-for-2026-travel-credits-spend-reset-application-strategy-more/)

- **Calendar-year spend limits:** Many cards reset on January 1, including Amex Platinum's $500,000 5x flight limit and Amex Gold's $25,000 grocery limit. Referral limits (Chase and Amex) also reset.
- **Spend requirements:** Examples include Amex Platinum's $75,000 spend for Centurion guest access, and the Chase Hyatt $15,000 free-night threshold. Finish these before December 31.
- **Use-it-now credits:** Amex Platinum's $200 airline credit, Hotel $600 (two $300 halves), Lululemon, Resy and Uber credits. The Citi Prestige $250 travel credit and the CSR Stubhub and dining credits are also listed. Some cards' benefits reset by cardmember year, not calendar year, so there's no need to rush those.
- **Applications:** Some cards can double-dip at year-end, with a possible triple-dip the following year. The article names the Amex Platinum, Citi Strata Elite and BofA Premium Rewards Elite.
- **Comments:** Most are thanks or small corrections. Chuck added the Capital One Venture X, Marriott's temporary $50 credit and Amex's referral limit.

## What others say about year-end double-dipping

The forum search did not find a thread on the year-end double-dip for these three cards together. Here is what I found for each card.

**Citi Strata Elite (the most discussion)**
- The article says the $300 hotel credit, $200 splurge credit and four Admirals Club passes are all calendar-year benefits, so there is "potential for a double-dip and even a triple-dip." [Year-End Checklist 2026](https://www.doctorofcredit.com/year-end-credit-card-checklist-for-2026-travel-credits-spend-reset-application-strategy-more/)
- The launch review says the hotel and splurge credits are per calendar year, so you can double-dip in the first year and possibly triple-dip if you get the card in December. [Citi Strata Elite Review](https://www.doctorofcredit.com/live-citi-strata-elite-review-80000-points-bonus-595-annual-fee-300-hotel-200-splurge-credit/)
- Readers in that thread describe the mechanics:
  - One reader says that with a 30-day window to product change or cancel, a triple-dip is possible. The plan is to use credits in late December, through the year, and on January 1, then cancel. [Citi Strata Elite Review](https://www.doctorofcredit.com/live-citi-strata-elite-review-80000-points-bonus-595-annual-fee-300-hotel-200-splurge-credit/)
  - Timing matters. One reader's first statement closed before the annual fee posted, so the fee would land in early January. Another's statement was closing within days, which would make a triple-dip "difficult or impossible." [Citi Strata Elite Review](https://www.doctorofcredit.com/live-citi-strata-elite-review-80000-points-bonus-595-annual-fee-300-hotel-200-splurge-credit/)
  - One reader reports a December 22 statement date with a successful triple-dip. The hotel credit posted instantly, and the splurge credit was used up with a Best Buy gift card within two days. [Citi Strata Elite Review](https://www.doctorofcredit.com/live-citi-strata-elite-review-80000-points-bonus-595-annual-fee-300-hotel-200-splurge-credit/)
  - Several readers report Citi sending mailed verification letters to new cardholders and phone verification problems. One reader speculates Citi is trying to stop triple-dips on new cards. That is a guess, not a confirmed policy. [Citi Strata Elite Review](https://www.doctorofcredit.com/live-citi-strata-elite-review-80000-points-bonus-595-annual-fee-300-hotel-200-splurge-credit/)
  - Another reader's idea of booking a hotel and cancelling to recoup the $300 is speculation, and no one confirmed it.

**Amex Platinum**
- The article says the $200 airline credit is calendar-year based. Charges must post before year-end, so allow a few days. It also says that if you apply now, the annual fee usually posts about a month after approval, which helps with triple-dipping. [Year-End Checklist 2026](https://www.doctorofcredit.com/year-end-credit-card-checklist-for-2026-travel-credits-spend-reset-application-strategy-more/)
- The Platinum revamp post says that in the first year you usually double-dip many credits because they run on calendar, half-year or quarterly schedules. [American Express Refreshes Platinum](https://www.doctorofcredit.com/american-express-refreshes-platinum-business-platinum-cards-895-fee-175k-200k-bonus-many-new-credits/)
- The article also notes that from January 1, 2027, all Platinum hotel bookings need a two-night minimum. That affects anyone planning to use the hotel credit later. [Year-End Checklist 2026](https://www.doctorofcredit.com/year-end-credit-card-checklist-for-2026-travel-credits-spend-reset-application-strategy-more/)
- I did not find a reader thread that specifically discusses an Amex Platinum year-end double-dip.

**Bank of America Premium Rewards Elite**
- The article says the $300 airline incidental and $150 lifestyle credits reset on the calendar year. It suggests that applying now could allow a triple-dip. [Year-End Checklist 2026](https://www.doctorofcredit.com/year-end-credit-card-checklist-for-2026-travel-credits-spend-reset-application-strategy-more/)
- I did not find any reader comments on a year-end double-dip for this card. The closest is a lifestyle-credit guide, which says what has and hasn't triggered the $150 credit.

**Citations:** 3, 3 a thread in the snapshot

- https://www.doctorofcredit.com/year-end-credit-card-checklist-for-2026-travel-credits-spend-reset-application-strategy-more/: thread in the snapshot
- https://www.doctorofcredit.com/live-citi-strata-elite-review-80000-points-bonus-595-annual-fee-300-hotel-200-splurge-credit/: thread in the snapshot
- https://www.doctorofcredit.com/american-express-refreshes-platinum-business-platinum-cards-895-fee-175k-200k-bonus-many-new-credits/: thread in the snapshot

**Tokens:** loop 287327 in / 6381 out · summary 0 in / 0 out

| Owner verdict | |
|---|---|
| New better, same, or worse | new better |
| Note | New better; verified Strata Elite triple-dip reports. |

### W4

**Question:** Which credit card will offer the biggest sign-up bonus in 2027?

**Starting page:** https://www.doctorofcredit.com/

**Snapshot misses:** https://www.doctorofcredit.com/wp-json/wp/v2/posts?search=biggest%20sign-up%20bonus%20credit%20card%202027&per_page=20&page=1&_fields=id,title,link,date_gmt,excerpt,author,_embedded,_links&_embed=author, https://www.doctorofcredit.com/wp-json/wp/v2/posts?search=best%20credit%20card%20sign%20up%20bonus%202026&per_page=20&page=1&_fields=id,title,link,date_gmt,excerpt,author,_embedded,_links&_embed=author, https://www.doctorofcredit.com/wp-json/wp/v2/posts?search=2027%20credit%20card%20changes%20bonus&per_page=20&page=1&_fields=id,title,link,date_gmt,excerpt,author,_embedded,_links&_embed=author

#### Old Research

**Tool calls:**

1. `search_forum` after=2026-01-01 query=2027 sign-up bonus credit card → 8 topics
1. `search_forum` after=2026-06-01 query=biggest sign-up bonus credit card 2026 → 1 topic
1. `search_forum` after=2026-06-01 query=highest credit card sign-up bonus points offer → 6 topics
1. `read_topic` topic_id=28140 → Read 1,798 posts

**Answer:**

## Short answer

The site can't tell you which card will have the biggest sign-up bonus in 2027. I found no post that forecasts 2027 offers or announces future bonuses. The closest evidence is the current bonus landscape as of November 2026.

## What the site shows today

- **Largest current points bonus in the roundup:** The Chase Marriott Bonvoy Boundless at 200,000 points + $100 airline credit. A recent weekly roundup also reports it ([Best Posts Last Week: 200k + $100 Airfare Marriott Offer...](https://www.doctorofcredit.com/best-posts-last-week-200k-100-airfare-marriott-offer-20-off-ubereats-up-to-50-off-amazon/)). The bonus list also includes it ([Best Current Credit Card Sign Up Bonuses & Offers For November, 2026](https://www.doctorofcredit.com/best-current-credit-card-sign-bonuses/)).
- **Top-ranked card on the list:** The American Express Platinum at up to 175,000 points after $12,000 spend, with an $895 fee. The list ranks it first as the "absolute best" personal card ([Best Current Credit Card Sign Up Bonuses & Offers For November, 2026](https://www.doctorofcredit.com/best-current-credit-card-sign-bonuses/)).
- **Other large offers on the list:** Citi AAdvantage Executive at 125,000 miles, and the Barclays Wyndham Earner Premier at up to 120,000 points.
- **Unverified:** A reader reported an IHG One Rewards Premier Select mailer offering 200,000 points. The site does not confirm this as a standard offer; the author replied that it appeared to be the standard bonus ([Best Current Credit Card Sign Up Bonuses & Offers For November, 2026](https://www.doctorofcredit.com/best-current-credit-card-sign-bonuses/)).

## Caveats

- Points aren't equal in value. The list author notes that a 200k Marriott or IHG bonus and a 175k Amex Platinum bonus are not directly comparable ([comment in the bonus roundup](https://www.doctorofcredit.com/best-current-credit-card-sign-bonuses/)).
- The bonus list changes often. Offers expire or return (for example, the Chase Southwest offer is listed as valid through 12/2/26), so today's leader may not be next year's.
- Based on this, the answer for 2027 is unknown. If the question is about the largest bonus now, the Chase Marriott Boundless 200k is the largest points figure in the roundup. The Amex Platinum 175k is the top-ranked card on the list.

**Citations:** 2, 2 a thread in the snapshot

- https://www.doctorofcredit.com/best-posts-last-week-200k-100-airfare-marriott-offer-20-off-ubereats-up-to-50-off-amazon/: thread in the snapshot
- https://www.doctorofcredit.com/best-current-credit-card-sign-bonuses/: thread in the snapshot

**Tokens:** loop 28063 in / 2197 out · summary 0 in / 0 out

#### New Agent

**Tool calls:**

1. `search_forum` "biggest sign-up bonus credit card 2027" → 0 threads
1. `search_forum` "best credit card sign up bonus 2026" → 20 threads
1. `search_forum` "2027 credit card changes bonus" → 20 threads

**Answer:**

I can't tell which card will have the biggest sign-up bonus in 2027. Nothing on the forum predicts that, and bonuses change without notice. The forum does show what's on offer now and some changes already scheduled for 2027.

**Largest current offers I found (all expire before 2027 unless noted):**
- **Chase Marriott Bonvoy Boundless:** 200,000 points + $100 airfare credit after $3,000 spend in three months, valid until 11/11/26. [Chase Marriott Bonvoy Boundless 200,000 Points + $100 Airfare Credit](https://www.doctorofcredit.com/chase-marriott-bonvoy-boundless-200000-points-100-airfare-credit/)
- **Marriott Bonvoy Brilliant:** 150,000 points + $250 credit, though a 2026 post says American Express was offering it with no lifetime-language links. [Best Posts Last Week: No Lifetime Language Links, $20 Off Walmart & More](https://www.doctorofcredit.com/best-posts-last-week-no-lifetime-language-links-20-off-walmart-more/)
- **Citi AAdvantage Executive:** 125,000 miles after $15,000 spend, but this offer is marked expired. [Citi AAdvantage Executive 125,000 Signup Bonus](https://www.doctorofcredit.com/citi-aadvantage-executive-125000-signup-bonus/)

**Known 2027 changes:**
- **Southwest:** Starting in 2027, signup bonus points won't count toward earning Companion Pass status. This may make Southwest offers less attractive. [Should I Apply For The Southwest Credit Card Now?](https://www.doctorofcredit.com/should-i-apply-for-the-southwest-credit-card-now/) and [Southwest Companion Pass No Longer Earned With Signup Bonus Points (Starts 2027)](https://www.doctorofcredit.com/southwest-companion-pass-no-longer-earned-with-signup-bonus-points-starts-2027/)
- **Bilt:** Bilt is discontinuing the 4% Bilt Cash for new applicants in 2027. [Bilt is Revamping Credit Card Benefits for 2027](https://www.doctorofcredit.com/bilt-revamps-credit-card-rewards-in-2027-discontinuing-4-bilt-cash-for-new-applicants-more/)
- **Citi AAdvantage Platinum Select and Business World Elite:** Both are being revamped on January 24, 2027, with a $150 annual fee and new benefits. [Citi AAdvantage Platinum Select Card Revamp](https://www.doctorofcredit.com/citi-aadvantage-platinum-select-card-revamp-coming-january-2027-150-annual-fee-new-benefits/)

Based on this, the highest offers have been large points bonuses from Chase and American Express. I can't say which will be biggest in 2027. A rumored American Express Platinum change is also mentioned, but the post is only a rumor. [Rumor: American Express To Add $250 AirBnB Experiences Credit To Platinum Card](https://www.doctorofcredit.com/rumor-american-express-to-add-250-airbnb-experiences-credit-to-platinum-card/) For the latest, check the [Deal Calendar](https://www.doctorofcredit.com/deal-calendar-full-list-deals-credit-card-bank-bonuses-expiry-dates/) and watch for new offers as they're posted.

**Citations:** 9, 9 a thread in the snapshot

- https://www.doctorofcredit.com/chase-marriott-bonvoy-boundless-200000-points-100-airfare-credit/: thread in the snapshot
- https://www.doctorofcredit.com/best-posts-last-week-no-lifetime-language-links-20-off-walmart-more/: thread in the snapshot
- https://www.doctorofcredit.com/citi-aadvantage-executive-125000-signup-bonus/: thread in the snapshot
- https://www.doctorofcredit.com/should-i-apply-for-the-southwest-credit-card-now/: thread in the snapshot
- https://www.doctorofcredit.com/southwest-companion-pass-no-longer-earned-with-signup-bonus-points-starts-2027/: thread in the snapshot
- https://www.doctorofcredit.com/bilt-revamps-credit-card-rewards-in-2027-discontinuing-4-bilt-cash-for-new-applicants-more/: thread in the snapshot
- https://www.doctorofcredit.com/citi-aadvantage-platinum-select-card-revamp-coming-january-2027-150-annual-fee-new-benefits/: thread in the snapshot
- https://www.doctorofcredit.com/rumor-american-express-to-add-250-airbnb-experiences-credit-to-platinum-card/: thread in the snapshot
- https://www.doctorofcredit.com/deal-calendar-full-list-deals-credit-card-bank-bonuses-expiry-dates/: thread in the snapshot

**Tokens:** loop 36627 in / 2010 out · summary 0 in / 0 out

| Owner verdict | |
|---|---|
| New better, same, or worse | same |
| Note | About equal; both honest, new lists two lapsed offers as current. |

### W5

**Question:** What do commenters here say since 2026-01-01 about getting Chase Ink business cards approved as a sole proprietor?

**Starting page:** https://www.doctorofcredit.com/

**Snapshot misses:** https://www.doctorofcredit.com/wp-json/wp/v2/posts?search=Chase%20Ink%20business%20sole%20proprietor%20approved&per_page=20&page=1&_fields=id,title,link,date_gmt,excerpt,author,_embedded,_links&after=2026-01-01T00:00:00&_embed=author, https://www.doctorofcredit.com/wp-json/wp/v2/comments?search=Ink%20business%20sole%20proprietor&per_page=10&page=1&order=desc&orderby=date_gmt&_fields=id,post,parent,author_name,date_gmt,content&after=2026-01-01T00:00:00, https://www.doctorofcredit.com/wp-json/wp/v2/posts/265640?_fields=id,title,link,modified_gmt, https://www.doctorofcredit.com/wp-json/wp/v2/comments?post=265640&per_page=1&page=1&order=asc&orderby=date_gmt&_fields=id, https://www.doctorofcredit.com/wp-json/wp/v2/posts/265640?_fields=id,title,link,date_gmt,modified_gmt,content,author,_embedded,_links&_embed=author, https://www.doctorofcredit.com/wp-json/wp/v2/comments?post=265640&per_page=100&page=1&order=asc&orderby=date_gmt&_fields=id,parent,author_name,date_gmt,content, https://www.doctorofcredit.com/wp-json/wp/v2/comments?post=265640&per_page=100&page=2&order=asc&orderby=date_gmt&_fields=id,parent,author_name,date_gmt,content, https://www.doctorofcredit.com/wp-json/wp/v2/comments?post=265640&per_page=100&page=3&order=asc&orderby=date_gmt&_fields=id,parent,author_name,date_gmt,content

#### Old Research

**Tool calls:**

1. `search_comments` after=2026-01-01 query=Chase Ink sole proprietor approved → 0 topics
1. `search_comments` after=2026-01-01 query=Chase Ink → 7 topics
1. `search_forum` after=2026-01-01 query=Chase Ink sole proprietor approval → 2 topics
1. `search_comments` after=2026-01-01 query=sole prop → 5 topics
1. `search_comments` after=2026-01-01 query=Ink business approved → 0 topics
1. `read_topic` topic_id=268010 → Read 58 posts

**Answer:**

## Short answer

The site's reader comments since 2026-01-01 contain only a few reports on Chase Ink approvals, and they come from one thread about the targeted Ink offers. Most of them point to prior Ink ownership or card-count rules as the main obstacle, not sole-proprietor status by itself. One reader gives a specific sole-prop rule, but it is a single reader's observation, not a verified finding. I found no reader report of a sole proprietor getting a Chase Ink card approved in 2026 in the comments I could search.

## What readers report

All of the following come from the comments on [Targeted Chase INK Cash/Unlimited $1,200 Bonus; INK Preferred 125,000 Points Bonus](https://www.doctorofcredit.com/targeted-chase-ink-cash-unlimited-1200-bonus-ink-preferred-125000-points-bonus/), posted October 30 to November 11, 2026.

- **Prior Ink ownership leads to denial.** Cathie (#17) was shown the "already approved" banner for Ink Preferred 125k, applied, and was declined because she had the card before. Brendon (#43–#45) was targeted for Ink Cash while already holding Ink Unlimited, and was denied for "having or had" an Ink no-annual-fee card. Brendon's advice: if you already have an active no-AF Ink Cash or Unlimited, don't apply for the other one. Tim (#54) got a cancelled application with a note to reapply without the bonus because of a prior Ink bonus.
- **"Already approved" is not approval.** Frogger (#6) and Dealgamer (#35) say the targeted banners did not guarantee approval. RG2 (#31) was denied for too many recent accounts despite the banner.
- **Sole-prop and EIN approach.** Adam_Seper (#49) reports that for Chase business cards applied for as a sole proprietor, the 2/24 threshold seems to matter, and that Chase has been denying most sole props with 3 or more personal cards opened across any bank in 24 months. He says an application under an LLC/EIN appears to still use 5/24. Adam (#51) says others have reported getting the same-card bonus with both a sole-prop application and an LLC/EIN application, but not guaranteed. Super_Pirate (#24) says applying with a different EIN, especially an LLC, can work. Pickle Rick (#4 thread at [Mercury post](https://www.doctorofcredit.com/mercury-fintech-500-business-checking-bonus/)) notes the IRS generally assigns a sole proprietor only one EIN.
- **Technical issues.** Marco (#55–#58) reports the Ink Preferred 120k "see details" page failing, and says Chase could not help by phone or secure message.

## Caveats

- The sole-prop-specific claims (2/24 threshold, 5/24 for LLCs, double-dipping) come from one or two readers. The site does not verify them.
- Search results were thin. The comment search found no direct Ink card approval reports from sole proprietors after January 1, 2026, beyond this thread.
- Other sole-prop reports in the results were about business bank accounts (for example, [Mercury](https://www.doctorofcredit.com/mercury-fintech-500-business-checking-bonus/), [U.S. Bank](https://www.doctorofcredit.com/u-s-bank-400-900-business-checking-bonus/), and [Wells Fargo](https://www.doctorofcredit.com/wells-fargo-400-825-business-checking-bonus/)), not Chase Ink cards.

## Bottom line

Readers since late October 2026 suggest the main risks for a sole-prop Chase Ink application are: having held an Ink card before, having too many recently opened cards (readers cite 2/24 for sole props), and targeted banners that don't guarantee approval. The site does not establish a reliable approval rule.

**Citations:** 4, 4 a thread in the snapshot

- https://www.doctorofcredit.com/targeted-chase-ink-cash-unlimited-1200-bonus-ink-preferred-125000-points-bonus/: thread in the snapshot
- https://www.doctorofcredit.com/mercury-fintech-500-business-checking-bonus/: thread in the snapshot
- https://www.doctorofcredit.com/u-s-bank-400-900-business-checking-bonus/: thread in the snapshot
- https://www.doctorofcredit.com/wells-fargo-400-825-business-checking-bonus/: thread in the snapshot

**Tokens:** loop 29238 in / 3669 out · summary 0 in / 0 out

#### New Agent

**Tool calls:**

1. `search_forum` "Chase Ink business sole proprietor approved" · after: 2026-01-01 → 3 threads
1. `search_comments` "Ink business sole proprietor" · after: 2026-01-01 → 0 comments
1. `read_topic` #265640 → saved to results/DCFA7EC6-A68B-456D-8809-DC00A46C558C/03-read_topic.txt
1. `read_topic` #265640 · "denied approved recon" → 237 posts (saved to results/DCFA7EC6-A68B-456D-8809-DC00A46C558C/04-read_topic.txt)

**Answer:**

Since 2026-01-01, the main discussion on the site is a thread on whether Chase changed its 5/24 rule for sole proprietors. Commenters mostly report a tighter 3/24 limit, applied from about 9/16/2026, and many denials since then. I read the article and its first ~200 comments. I did not read the middle section (roughly comments #52 to #205), so I may have missed some reports.

Source: [Has Chase Changed The 5/24 Rule For Sole Props? (3/24 For Sole Props)](https://www.doctorofcredit.com/has-chase-changed-the-5-24-rule-for-sole-props-3-24-for-sole-props/)

**Key points from commenters**

- **The 3/24 change:** Several callers said reconsideration reps cited a new rule of "3 or more cards in 24 months" for sole proprietors. Commenter Matt (#214) said an underwriter confirmed the policy changed on 9/16 and is 3/24. The article's author says it's "a bit early to call this official."
- **Timing matters:** Applications before about 9/16 were often approved at 4/24. Bubee (#13) and Swish (#32) were approved for Ink Cash at 4/24 on 9/1 and 9/10. Several people applied after 9/16 and were denied.
- **Calendar month:** Louis (#36, #213) applied in September, was denied, and was still refused on reconsideration on 10/1 because the 5/24 count runs through the calendar month.
- **Approvals still happen:** Derek (#29) was approved at 3/24 on 9/16 after three reconsideration calls, but was asked to lower personal credit limits. Matt-style underwriter escalation was the route several people described.
- **Whether Chase business cards count is disputed:** JoePro (#215, #219) reported approval at 4/24 and said Chase business cards didn't count against the limit in their experience. Others disagree, and KS (#19) said business cards don't count except for a few.
- **Sole prop vs. LLC:** Results are mixed. UserName (#234) was approved as a single-member LLC at 4/24 for a Sapphire Reserve Business. DerekD (#222) was denied as an LLC at 4/24 for "too many business cards." Miki (#225) was told they had applied as a corporation and needed to reapply as a sole prop.
- **Denials reported:** Commenters reported denials for Ink, Sapphire Business Reserve, United Club Business, and IHG Business at 3/24 and 4/24 (for example #233, #235–#237). Slappy (#237) said there was no reconsideration option.
- **Pre-approval isn't a guarantee:** Maverik (#212) got an in-app "already approved" pop-up, then was denied after applying. Jo (#20) got a pre-approval and wasn't sure it mattered.

**Bottom line:** The thread reports a stricter 3/24 limit for sole-prop Chase business applications from mid-September 2026, with approvals still reported at 4/24 and some at 3/24. Whether business cards count toward the limit is unresolved in these comments. The site doesn't establish the rule officially.

**Citations:** 1, 1 a thread in the snapshot

- https://www.doctorofcredit.com/has-chase-changed-the-5-24-rule-for-sole-props-3-24-for-sole-props/: thread in the snapshot

**Tokens:** loop 56283 in / 2578 out · summary 0 in / 0 out

| Owner verdict | |
|---|---|
| New better, same, or worse | new better |
| Note | New better; dedicated sole-prop thread, quotes verified. |

## Reading notes for the gate (facts, not verdicts)

- **Token cost.** The new Agent used about 53% more loop input tokens than old Research overall (910,710 vs 595,250) and about 25% fewer loop output tokens (36,755 vs 49,060). Its summary tokens are higher (67,738 in / 30,759 out vs 34,494 / 6,682), because it summarizes more often. Median time was about the same (28.3 s vs 25.2 s). Its 25 tool definitions cost 6,626 tokens on every forum turn.
- **Questions where the two sides differ most.**
  - **W2:** the new answer has no citation link at all and answers "probably yes, based on one reader report"; old Research cites one link and says the site does not settle it. This is the nearest candidate for "newly wrong".
  - **D3 and H3 (multi-step):** both sides on D3 only summarized the thread (one tool call) and gave a wider answer without a separate search for "point 2". On H3 the new side used 2 calls where old used 3.
  - **D4:** both sides list current threads; old read 2 and cited the `/t/topic/<id>` form, new read 4 and cited 6 links.
  - **D5, W4:** both sides say the forum cannot establish the answer, as the question set expected for W4.
- **Snapshot misses.** A miss is a URL the new side fetched live because the old side hadn't fetched it. Misses are high for D1, D5 and W3, so for those questions the two sides did not read exactly the same data.
- **Runs.** No question ended in an error, and every question ran once per side. No prompt fix was made, so nothing was recorded twice.

## Not proven

- Results on the owner's own Agent model (and Summaries model) may differ: both loops ran on `claude-haiku-5-5` only (the owner's Haiku-only rule). A larger model may close or widen the gaps above.
- Answer quality is not scored here: the owner's verdict rows are empty, and the link-check only shows whether a cited URL is in the snapshot.
- One run per question per side: model randomness is not measured.
- Live behaviour on the owner's iPhone and with the voice hand-off is not part of this comparison.
- Recording history: two earlier record attempts were interrupted when the test host died (the simulator was also shared with another task). They were run with the same Haiku-only guard, but their logs were discarded; the committed audit covers the final run only.

## Model audit

Every model request of this record run (old loop, new loop, summaries and the tool-definition count) passed through `ModelAudit`, which reads the request body's `model` and refuses anything but `claude-haiku-5-5`. 140 calls: 140 × `claude-haiku-5-5`. The log (host, path, model, status; no keys) is `WukongMindTests/Fixtures/Comparison/model-audit.jsonl`; the recorded new-side runs under `Fixtures/Comparison/runs/` name the model per turn as well.

## Re-record after gate 2 fixes

WUKO-63 fixed the tools and the prompt for conditions 1-3 (commit 3877948), then re-recorded W2, H3 and H4 on both sides, once each, with no retry. The run started from a fresh, empty snapshot in its own set, `WukongMindTests/Fixtures/Comparison/gate2/` (`ONE_LOOP_SET=gate2`): new snapshot, runs and audit log, with files prefixed `gate2-`. Task 8's snapshot, runs and audit log above are unchanged. Both loops and the summaries used `claude-haiku-5-5` only. The forums were fetched live again on 2026-11-14, so the H4 list and some comment counts differ from the first run.

| | |
|---|---|
| App commit | 3877948 |
| Snapshot misses (new side fetched live) | H3: 0, H4: 3, W2: 1 |
| Text Agent's tools on forum pages | 26 tools, 6833 tokens of definitions |

**Why W2 missed the terms (condition 1).** The first `read_topic` of `?p=229112` showed the article, comments #2-45 and #276-317 inline, and saved the rest to a file. Comment #261 (Jarrett, July 2026: "A minimum spend of $600 must be met in a single transaction…") was not inline. The site-wide `search_comments` "single transaction cart" returned 0: WordPress matches every word, and #261 doesn't contain "cart". The in-thread `read_topic` query "multiple purchases one transaction cart total" matched any one word, so it returned 70 of 317 comments in thread order, and #261 started at character 18,698 of that result. The Agent read only the first 12,000 characters. **Fix:** query matches now come best first (the whole query, then the most distinct words, thread order among equals), and the set of matches is unchanged. On the recorded fixture, #261 now starts at about character 5,000; `testThreadQueryPutsTheSingleTransactionTermsInTheFirstRead` fails on the old code and passes on the new.

**What else changed.**
- **Sources (condition 1):** Only a Markdown link `[title](url)` is a source, in the numbered sources and in History's save rule. A plain URL, or a thread read but not linked, is none. A title may hold one level of brackets ("[Targeted] Chase Travel…"), which the old pattern didn't match.
- **H3 (condition 2):** The prompt rule is "search the forum beyond that thread before answering". An in-thread `read_topic` query now opens with a note that it covers this thread only and points to `search_forum`.
- **H4 (condition 3):** The prompt rule is "never recommend from titles alone". `list_latest` now opens with a note to read at least one thread first.
- **Tests:** The replay test checks the re-recorded runs themselves: W2 has a Markdown-link source, H3 searches, H4 reads a thread.

### Totals (re-record)

| Kind | Side | Loop tokens in | Loop tokens out | Summary tokens in | Summary tokens out | Tool calls | Topics read | Median time |
|---|---|---|---|---|---|---|---|---|
| hackernews | Old Research | 55996 | 5362 | 0 | 0 | 6 | 4 | 16.4 s |
| hackernews | New Agent | 79773 | 4487 | 19005 | 2385 | 9 | 7 | 24.3 s |
| wordpress | Old Research | 15531 | 1978 | 0 | 0 | 1 | 1 | 17.5 s |
| wordpress | New Agent | 47401 | 1518 | 0 | 0 | 3 | 1 | 18.5 s |
| All | Old Research | 71527 | 7340 | 0 | 0 | 7 | 5 | 17.5 s |
| All | New Agent | 127174 | 6005 | 19005 | 2385 | 12 | 8 | 18.5 s |

### Verdicts (re-record)

| Question | New better, same, or worse | First run |
|---|---|---|
| W2 | better | worse |
| H3 | same | worse |
| H4 | better | worse |

Verdicts by the WUKO-63 agent from the answers below, for the orchestrator's final check.

### Questions (re-record)

#### H3

**Question:** Summarize the thread "How I use Tailscale" (https://news.ycombinator.com/item?id=44809166), then find what others here say about exposing a service with `tailscale funnel`.

**Starting page:** https://news.ycombinator.com/item?id=44809166

##### Old Research

**Tool calls:**

1. `read_topic` topic_id=44809166 → Read 102 posts
1. `search_comments` query=tailscale funnel → 5 topics
1. `read_topic` query=funnel topic_id=49754785 → Read 7 matching posts

**Answer:**

## 1. Summary of "How I use Tailscale"

The submission links to a personal write-up at [chameth.com/how-i-use-tailscale](https://chameth.com/how-i-use-tailscale/). The HN discussion is [How I use Tailscale](https://news.ycombinator.com/item?id=44809166). I read the thread, but the tool trimmed the middle replies, so this is not exhaustive. The blog post body itself was not retrieved, so I can't describe the author's setup beyond what commenters say.

Main themes in the comments:
- **Practical use:** Commenters use it for self-hosting, reaching Jellyfin or file servers away from home, exit nodes for home-network filtering (AdGuard Home/Pi-hole), and geo-access to banking or streaming. [#7](https://news.ycombinator.com/item?id=44809166#44819309), [#9](https://news.ycombinator.com/item?id=44809166#44819309), [#10](https://news.ycombinator.com/item?id=44809166#44818657)
- **Alternatives:** ZeroTier, plain WireGuard, Nebula, Headscale, and NetBird come up repeatedly. [#3](https://news.ycombinator.com/item?id=44809166#44823629), [#20](https://news.ycombinator.com/item?id=44809166#44809166), [#86](https://news.ycombinator.com/item?id=44809166#44854176), [#95](https://news.ycombinator.com/item?id=44809166#44854509)
- **Concerns:** Battery drain and WSL DNS breakage ([#2](https://news.ycombinator.com/item?id=44809166#44817950)). Tailscale SSH is seen as convenient but worrying for some ([#15](https://news.ycombinator.com/item?id=44809166#44823723)). One commenter wants tailnet lock to cover ACLs, not just nodes ([#101](https://news.ycombinator.com/item?id=44809166#44854509)). Another objects to DNS handling and telemetry-style logging ([#76](https://news.ycombinator.com/item?id=44809166#44857959), [#73](https://news.ycombinator.com/item?id=44809166#44852250)).

## 2. What others say about `tailscale funnel`

**Security and exposure (main HN thread on funnel, in [How I use Tailscale](https://news.ycombinator.com/item?id=44809166))**
- A commenter ran `tailscale funnel` on a dummy `python -m http.server` and saw vulnerability scanners probing within about 10 seconds. The HTTPS certificate is recorded in a public Certificate Transparency log ([#21](https://news.ycombinator.com/item?id=44809166#44850881)).
- Replies disagree on how much this matters. One says CT log consumers scan new hosts, and suggests non-standard ports to cut traffic ([#22](https://news.ycombinator.com/item?id=44809166#44851004)). Another notes that Tailscale proxies traffic, so the home IP isn't exposed, and that closing the funnel ends the load ([#23](https://news.ycombinator.com/item?id=44809166#44851004)). A third says port choice makes little difference, since IPv4 is scannable quickly ([#28](https://news.ycombinator.com/item?id=44809166#44853313)).
- Mitigations proposed: use wildcard certificates if you manage your own certs ([#24](https://news.ycombinator.com/item?id=44809166#44851580)), and avoid revealing domain or owner details through the default-IP certificate ([#26](https://news.ycombinator.com/item?id=44809166#44852837)). One reply notes that a server with no matching certificate simply fails the TLS handshake ([#27](https://news.ycombinator.com/item?id=44809166#44852837)).

**Usage and limits (from [Cloudflare Quick Tunnels](https://news.ycombinator.com/item?id=49754785))**
- Commenters present Funnel as the Tailscale analogue of Cloudflare's public tunnels. One calls Cloudflare's offering "their version of Tailscale funnel" ([#21](https://news.ycombinator.com/item?id=49754785#21), [#142](https://news.ycombinator.com/item?id=49754785#142)).
- Limit: one Funnel per Tailscale instance (per machine) on the HTTPS endpoint, so other apps use custom-port URLs ([#143](https://news.ycombinator.com/item?id=49754785#49758062)).
- Workarounds: path-based routing to different local ports, shown with `tailscale funnel status` ([#145](https://news.ycombinator.com/item?id=49754785#49758062)). Another user runs a Tailscale container per Compose stack for separate funnels ([#147](https://news.ycombinator.com/item?id=49754785#49758062)). One user prefers the `tsnet` Go library to get more control ([#144](https://news.ycombinator.com/item?id=49754785#49758062)).
- A tailnet alone won't serve a public endpoint, such as an MCP server for Claude.ai. Funnel or a similar public tunnel is needed ([#182](https://news.ycombinator.com/item?id=49754785#49758784)).

**Other mentions (search excerpts only, not read in full)**
- In a [Ask HN thread on $5 VPS projects](https://news.ycombinator.com/item?id=49985548), one user says Tailscale Funnel is "easy" for exposing things, compared with alternatives.
- In a [SQLite WAL bug thread](https://news.ycombinator.com/item?id=49272832), a reply links to the Funnel CLI and feature docs, with notes on DNS names and supported ports.

## Caveats
- The site doesn't establish whether Funnel is safe for a given workload. Commenters disagree about how much the CT-log discovery matters.
- The thread was trimmed, so some replies weren't seen.
- Quotes from the excerpt-only threads are unverified beyond the search snippets.

**Citations:** 24, 23 a thread in the snapshot

- https://chameth.com/how-i-use-tailscale/: not in the snapshot
- https://news.ycombinator.com/item?id=44809166: thread in the snapshot
- https://news.ycombinator.com/item?id=44809166#44819309: thread in the snapshot
- https://news.ycombinator.com/item?id=44809166#44818657: thread in the snapshot
- https://news.ycombinator.com/item?id=44809166#44823629: thread in the snapshot
- https://news.ycombinator.com/item?id=44809166#44809166: thread in the snapshot
- https://news.ycombinator.com/item?id=44809166#44854176: thread in the snapshot
- https://news.ycombinator.com/item?id=44809166#44854509: thread in the snapshot
- https://news.ycombinator.com/item?id=44809166#44817950: thread in the snapshot
- https://news.ycombinator.com/item?id=44809166#44823723: thread in the snapshot
- https://news.ycombinator.com/item?id=44809166#44857959: thread in the snapshot
- https://news.ycombinator.com/item?id=44809166#44852250: thread in the snapshot
- https://news.ycombinator.com/item?id=44809166#44850881: thread in the snapshot
- https://news.ycombinator.com/item?id=44809166#44851004: thread in the snapshot
- https://news.ycombinator.com/item?id=44809166#44853313: thread in the snapshot
- https://news.ycombinator.com/item?id=44809166#44851580: thread in the snapshot
- https://news.ycombinator.com/item?id=44809166#44852837: thread in the snapshot
- https://news.ycombinator.com/item?id=49754785: thread in the snapshot
- https://news.ycombinator.com/item?id=49754785#21: thread in the snapshot
- https://news.ycombinator.com/item?id=49754785#142: thread in the snapshot
- https://news.ycombinator.com/item?id=49754785#49758062: thread in the snapshot
- https://news.ycombinator.com/item?id=49754785#49758784: thread in the snapshot
- https://news.ycombinator.com/item?id=49985548: thread in the snapshot
- https://news.ycombinator.com/item?id=49272832: thread in the snapshot

**Tokens:** loop 42862 in / 3742 out · summary 0 in / 0 out

##### New Agent

**Tool calls:**

1. `summarize_topic` https://news.ycombinator.com/item?id=44809166 → How I use Tailscale
1. `search_comments` "tailscale funnel" → 10 comments
1. `read_topic` #49754785 · "funnel" → 317 posts

**Answer:**

## Summary of "How I use Tailscale"

The [story](https://news.ycombinator.com/item?id=44809166) links to chameth.com, a personal Tailscale setup write-up. The thread (102 posts) mostly discusses the author's workflow, then moves to four topics: exposing services, alternatives, security, and privacy. The article itself isn't quoted in the thread.

- **Uses:** Commenters use Tailscale to reach home services like Jellyfin and file servers from phones without making them public. Others use a home exit node for ad blocking, or for region-locked services while abroad.
- **Alternatives:** Headscale, Netbird, Nebula, ZeroTier, Cloudflare Tunnels, and Plex's UPnP remote access were all suggested.
- **Security:** Tailscale SSH worried some users, though others said it is opt-in. One commenter argued that ACLs aren't covered by tailnet lock, so a compromised coordination server could change access controls. Another warned against hosting your identity provider on the tailnet it authenticates.
- **Telemetry:** This was the most heated part. One user said desktop clients stream connection open/close metadata by default and mobile clients can't opt out, and recommended `--no-logs-no-support`. Defenders said the logs are operational and the content is encrypted. Critics replied that metadata still reveals behavior.
- **DNS:** One commenter said Tailscale takes over the resolver by default. Another found that on systemd-resolved, resolv.conf was untouched. The docs say local DNS is used unless "Override DNS servers" is enabled.

Unresolved in the thread: whether default telemetry is acceptable, whether signed ACLs will arrive, and whether mobile clients will get an opt-out.

## What others say about `tailscale funnel`

**In this thread** (as summarized by the tool, not read post by post): a user who enabled Funnel on a test Python server saw vulnerability scanners probing within about 10 seconds, apparently triggered by certificate transparency logs. The thread split over whether this is just removing obscurity. Suggested mitigations were wildcard certificates, rejecting unknown SNI, and non-standard ports, though others said scanners find services on any port. The most common advice was to avoid Funnel for real services and stay on the tailnet. ([story](https://news.ycombinator.com/item?id=44809166))

**In other threads**, the Funnel comments are more positive:

- In the [Cloudflare Quick Tunnels](https://news.ycombinator.com/item?id=49754785) thread, one commenter called Tailscale Funnel the equivalent of Cloudflare's quick tunnels for public access. Another said you can only have one Funnel per machine's HTTPS endpoint, so other apps end up on custom-port URLs. A reply said the CLI is limited, and that they use `tsnet` directly to run many funnels. Another showed that path-based routing (`/foo`, `/bar`) to different local ports lets one machine serve several apps on a single funnel. A fourth said they run a Tailscale container per Docker Compose stack, which gives each stack its own funnel. One user noted that Funnel only helps with MCP-style public endpoints if the setup is exposed publicly, and that Cloudflare is the simpler route there.
- In an [Ask HN thread about a $5 VPS](https://news.ycombinator.com/item?id=49985548), one commenter said Tailscale Funnel is easy, but I only saw the start of that comment, so I can't say more.

I didn't read the comments in the first thread individually, so those points come from the summary. The Cloudflare thread's Funnel posts were read directly.

**Citations:** 3, 3 a thread in the snapshot

- https://news.ycombinator.com/item?id=44809166: thread in the snapshot
- https://news.ycombinator.com/item?id=49754785: thread in the snapshot
- https://news.ycombinator.com/item?id=49985548: thread in the snapshot

**Tokens:** loop 34635 in / 2610 out · summary 19005 in / 2385 out

| Owner verdict | |
|---|---|
| New better, same, or worse | same |
| Note | Both sides now search beyond the named thread (`search_comments` "tailscale funnel") and read the Cloudflare Quick Tunnels thread. New no longer describes the article it did not fetch. Old still cites at post level (24 links) where new cites 3 threads, and new takes the in-thread Funnel points from its summary, which it says. |

#### H4

**Question:** What's worth reading today on Hacker News?

**Starting page:** https://news.ycombinator.com/

**Snapshot misses:** https://hn.algolia.com/api/v1/items/50498151, https://hn.algolia.com/api/v1/items/50498135, https://hn.algolia.com/api/v1/items/50498316

##### Old Research

**Tool calls:**

1. `list_latest`  → 30 topics
1. `read_topic` topic_id=50498380 → Read 4 posts
1. `read_topic` topic_id=50498273 → Read 2 posts

**Answer:**

## What's worth reading today (Nov 14, 2026)

I read only two threads in depth, so these picks are partly based on headlines. The list is mostly single-post stories with no discussion yet.

**1. [The Mystery Behind a 50-Year-Old Factory Part Flying Off the Shelves](https://news.ycombinator.com/item?id=50498380)**
The WSJ piece is about a Michigan air-vent maker that was suddenly flooded with orders from unknown buyers. A commenter says the vents are needed to cool data centers. The link is paywalled, and one commenter asked for a gift link. It's the most discussed story on the list (4 posts), and the discussion is short.

**2. [EU institutions survive Microsoft outage unscathed](https://news.ycombinator.com/item?id=50498273)**
Politico reports that EU institutions weren't badly hurt by a Microsoft outage. One commenter points out that the EU's legal database, EUR-Lex, has been mostly offline for unexplained reasons. The thread is brief, so treat the picture as incomplete.

**Other headlines worth a look (unread, so judged only by title):**
- [Thinking Machines: End-to-End 4-Bit Training](https://news.ycombinator.com/item?id=50498252): a technical ML topic.
- [Llama.cpp v1.0 on an RTX 3090: up to 55% faster with speculative decoding](https://news.ycombinator.com/item?id=50498314): a local-inference benchmark claim.
- [Training and Inference on Huawei Ascend NPUs](https://news.ycombinator.com/item?id=50498304).
- [Anthropic: Mythos got Claude running on AMD chips in 3 days instead of months](https://news.ycombinator.com/item?id=50498130).
- [Ask HN: Open-source projects with notably good online documentation](https://news.ycombinator.com/item?id=50498200): a question thread that may collect useful recommendations.

The site listing doesn't say which of these are most valuable, and I didn't check the claims in any of them. If you want, I can read the technical items (the 4-bit training, llama.cpp, and Ascend posts) next.

**Citations:** 7, 7 a thread in the snapshot

- https://news.ycombinator.com/item?id=50498380: thread in the snapshot
- https://news.ycombinator.com/item?id=50498273: thread in the snapshot
- https://news.ycombinator.com/item?id=50498252: thread in the snapshot
- https://news.ycombinator.com/item?id=50498314: thread in the snapshot
- https://news.ycombinator.com/item?id=50498304: thread in the snapshot
- https://news.ycombinator.com/item?id=50498130: thread in the snapshot
- https://news.ycombinator.com/item?id=50498200: thread in the snapshot

**Tokens:** loop 13134 in / 1620 out · summary 0 in / 0 out

##### New Agent

**Tool calls:**

1. `list_latest`  → 30 threads
1. `read_topic` #50498380 → 4 posts
1. `read_topic` #50498273 → 2 posts
1. `read_topic` #50498151 → 1 post
1. `read_topic` #50498135 → 2 posts
1. `read_topic` #50498316 → 2 posts

**Answer:**

I read five stories. The discussions are thin, so the linked articles carry most of the value. Here's what I found:

**Worth a look**
- [Robot startup cant pay staff after founder takes $4.6M from company to buy home](https://news.ycombinator.com/item?id=50498135): The comment quotes CNBC reporting that Foundation missed payroll on Oct. 30. It says CEO Sankaet Pathak borrowed $4.6M from the company in 2025 to buy a Sausalito home. I didn't open the CNBC article itself.
- [The Mystery Behind a 50-Year-Old Factory Part Flying Off the Shelves](https://news.ycombinator.com/item?id=50498380): A commenter says the part is air vents, bought by unknown buyers, and that they're needed to cool data centers. The WSJ link is paywalled, and a commenter asked for a gift link.

**Light on discussion**
- [EU institutions survive Microsoft outage unscathed](https://news.ycombinator.com/item?id=50498273): The Politico piece says the EU institutions came through a Microsoft outage. A commenter adds that EUR-lex has been mostly offline for unknown reasons.
- [Ask HN: Do you think everyone is going too far with Jensen Huang?](https://news.ycombinator.com/item?id=50498316): There's only one substantive reply, which says the answer depends on the direction and that more facts are needed.
- [The Cloud Is Just Someone Else's Computer – They Let It Burn](https://news.ycombinator.com/item?id=50498151): The link goes to soargram.io, and the thread has no comments beyond the post itself.

**Seen only in the list (not read)**
Other items include "Llama.cpp v1.0 on an RTX 3090" ([link](https://news.ycombinator.com/item?id=50498314)), "Thinking Machines: End-to-End 4-Bit Training" ([link](https://news.ycombinator.com/item?id=50498252)), "Creating a self booting ZIP archive" ([link](https://news.ycombinator.com/item?id=50498295)), and "The first unofficial native PS5-to-PC game port has arrived" ([link](https://news.ycombinator.com/item?id=50498068)). I haven't checked these, so I can't say whether they're worth your time.

If you want, I can read one of those next, or search the site for other discussion of the robot startup or the Microsoft outage.

**Citations:** 9, 9 a thread in the snapshot

- https://news.ycombinator.com/item?id=50498135: thread in the snapshot
- https://news.ycombinator.com/item?id=50498380: thread in the snapshot
- https://news.ycombinator.com/item?id=50498273: thread in the snapshot
- https://news.ycombinator.com/item?id=50498316: thread in the snapshot
- https://news.ycombinator.com/item?id=50498151: thread in the snapshot
- https://news.ycombinator.com/item?id=50498314: thread in the snapshot
- https://news.ycombinator.com/item?id=50498252: thread in the snapshot
- https://news.ycombinator.com/item?id=50498295: thread in the snapshot
- https://news.ycombinator.com/item?id=50498068: thread in the snapshot

**Tokens:** loop 45138 in / 1877 out · summary 0 in / 0 out

| Owner verdict | |
|---|---|
| New better, same, or worse | better |
| Note | New read five stories before recommending (old read two) and lists the rest as "seen only in the list". Both separate what they read from what they only saw listed. |

#### W2

**Question:** In the post "[Targeted] Chase Travel: Spend $600+ & Receive $100 Back" (https://www.doctorofcredit.com/?p=229112), does checking out multiple separate hotel bookings together in one Chase Travel cart count as a single transaction to trigger the $100 credit?

**Starting page:** https://www.doctorofcredit.com/?p=229112

**Snapshot misses:** https://www.doctorofcredit.com/wp-json/wp/v2/posts?search=Chase%20Travel%20$600%20$100%20back%20multiple%20bookings%20cart&per_page=20&page=1&_fields=id,title,link,date_gmt,excerpt,author,_embedded,_links&_embed=author

##### Old Research

**Tool calls:**

1. `read_topic` topic_id=229112 → Read 317 posts

**Answer:**

## Short answer

The thread suggests **yes, it can work, but it is not guaranteed by the terms as quoted.** The evidence is one reader's successful report and reader-quoted terms that say the spend must be a single transaction.

## What the evidence says

- **Reader success report:** In comment #317, Justine says she booked three nights at three different hotels, had them all in her cart, and checked out in one transaction. It "posted as one transaction over $600" and she received the $100 back. This is a single anecdote, and the post doesn't say how Chase handled it at scale. ([Targeted] Chase Travel: Spend $600+ & Receive $100 Back, https://www.doctorofcredit.com/targeted-chase-travel-spend-500-receive-100-back/)
- **Terms quoted by a reader (2026 version):** In comment #261 (July 2, 2026), Jarrett quotes the offer language: "A minimum spend of $600 must be met in a single transaction... multiple transactions totaling $600 do not qualify." That points against counting separate bookings as one qualifying spend, unless the cart checkout posts as one charge, which is what Justine reports. (Same post, comment #261.)
- **Earlier reader comments are not conclusive:** In 2024 comments, a reader said a Chase representative told them several purchases could count (#48), while another asked the same question without a clear answer (#44, #57, #69). These predate the current terms and were for a different version of the offer.
- **The article's own fine print is outdated:** The body of the post still shows 2024 terms (expiry 10/31/2024). The updates list later windows, and the quoted 2026 terms are from a reader comment, not the article.

## Other things to check

- **Spend amount may have changed:** Comments #308 to #310 (Nov 1, 2026) report the offer now requires **$800** on some cards, not $600. Confirm the amount shown in your own Chase Offers before booking.
- **Offer is card-specific:** Comment #286 says the offer is targeted by card and is not extended to other cards on request.
- **Qualifying charge must post:** Comment #288 describes a purchase where the offer disappeared after use. Comment #290 explains it is normal for an offer to leave the available list once used, and the credit posted a few days later.

## Bottom line

You can put multiple hotel bookings in one Chase Travel cart and pay in one checkout, which one reader reports posted as a single transaction over $600. Because the quoted terms say a single transaction is required, there is some risk that Chase treats separate reservations differently. Confirm the required amount in your offer, consider combining the bookings into a single charge at checkout, and keep records (screenshots of the offer and the receipt) in case you need to dispute it.

Sources: [Targeted] Chase Travel: Spend $600+ & Receive $100 Back, https://www.doctorofcredit.com/targeted-chase-travel-spend-500-receive-100-back/ (comments #261, #286, #288, #290, #308–310, #317, and older comments #44, #48).

**Citations:** 0, 0 a thread in the snapshot

**Tokens:** loop 15531 in / 1978 out · summary 0 in / 0 out

##### New Agent

**Tool calls:**

1. `read_topic` #229112 → saved to results/08083403-413D-476C-8BA1-7CF64937A5DC/01-read_topic.txt
1. `search_forum` "Chase Travel $600 $100 back multiple bookings cart" → 0 threads
1. `read_topic` #229112 · "multiple separate cart" → 317 posts

**Answer:**

**Probably yes, based on one reader report, but the terms say a single transaction is required, so it isn't guaranteed.**

- **Reader report:** In the comments, Justine reports: "I bought 3 different nights at 3 different hotels and had it in my cart, checked out in one transaction. It posted as one transaction over $600 and I got the $100 back!" ([Targeted Chase Travel: Spend $600+ & Receive $100 Back](https://www.doctorofcredit.com/targeted-chase-travel-spend-500-receive-100-back/), comment #317, 2026-11-12). That is the closest match to your situation, and it is the most recent report on the page.
- **Terms quoted in the comments:** Jarrett quoted the July 2026 offer terms: "A minimum spend of $600 must be met in a single transaction … multiple transactions totaling $600 do not qualify" (same post, comment #261, 2026-07-02). So what counts is the single transaction, and a single checkout that posts as one charge is the thing the offer describes.
- **Gaps:** The article's own fine print is an outdated 2024 version, so I couldn't confirm the current terms from it. The site doesn't say how Chase treats a cart with separate bookings in terms of how it posts, and only one reader has reported this result. Earlier commenters asked the same question and got no definitive answer (for example, comment #57 and comment #60 in the same post).

**Practical takeaway:** Put everything in one cart and check out once, so the charge posts as a single transaction of $600 or more after taxes and discounts. Keep a screenshot of the offer in your account before you buy, since several commenters had offers disappear after use or after a booking was cancelled.

**Citations:** 1, 1 a thread in the snapshot

- https://www.doctorofcredit.com/targeted-chase-travel-spend-500-receive-100-back/: thread in the snapshot

**Tokens:** loop 47401 in / 1518 out · summary 0 in / 0 out

| Owner verdict | |
|---|---|
| New better, same, or worse | better |
| Note | Both now find the July 2026 "single transaction" terms (#261) and the cart report (#317). New cites the post as a Markdown link (1 source); old cites it only as a plain URL, which counts as zero sources. |

### Model audit (re-record)

Every model request of the re-record (old loop, new loop, summaries and the tool-definition count) passed through `ModelAudit`, which refuses any model but `claude-haiku-5-5`. 23 calls: 23 × `claude-haiku-5-5`. The log is `WukongMindTests/Fixtures/Comparison/gate2/model-audit.jsonl`; the runs under `Fixtures/Comparison/gate2/runs/` name the model on each turn.

### Conditions

1. **Met.** Agent sources are Markdown links only, in the numbered sources and in History's save rule (`AssistantSourcesTests`, `AgentAnswerHistoryTests`). The W2 miss is explained above and fixed in `read_topic` query matching, with a unit test on the recorded fixture.
2. **Met.** H3's new side searched beyond the thread (`search_comments`, then `read_topic` on another thread). Covered by the prompt rule, the tool note, `testInThreadQueryPointsToAForumSearch` and the H3 replay.
3. **Met.** H4's new side read five threads. Covered by the prompt rule, the tool note, `testLatestListAsksForAReadBeforeRecommending` and the H4 replay.
4. **Met.** W2, H3 and H4 were re-recorded on both sides from a fresh, empty snapshot. The new side is no worse on all three (better, same, better), and all 18 recorded new-side runs replay.

## Approval

Gate 2 approved with conditions by the orchestrator for the owner, 2026-11-14; deletion tasks wait for conditions 1-4.

Decision (delegated by the owner: the orchestrator decides gate 2 for the owner). The bar (no worse on 12 of 15, nothing newly wrong in a main answer, no invented links) is met, but only just, on one run each.

Conditions, met before any deletion task (9, 10, 11, 13, 14) merges:

1. W2: Agent sources must be Markdown links; plain-text URLs count as zero sources (this also affects task 12's History save rule). Find why the comment query missed the "single transaction" terms (#261).
2. H3/D3: "then find what others say about X" must search beyond the named thread.
3. H4: a "worth reading" answer must read at least one thread, not only list titles.
4. Then re-record W2, H3 and H4 with a fresh, empty snapshot (the current snapshot looks pre-filled by discarded attempts). The new side must be no worse than old on all three. Put the re-record in the report.

Not blocking: D5 should surface the solved flag in search results (both sides); watch `summarize_topic` overuse (D4, H5) and the W3/H5 token spikes.

Conditions 1-4: met on 2026-11-14 (WUKO-63; see [Re-record after gate 2 fixes](#re-record-after-gate-2-fixes)), pending the orchestrator's final check.
