# 跑完看轨迹：同类跑步 App 的回放页怎么做，我们缺哪一块

调研日期 2026-08-12 ｜ 只谈**已完成订单的轨迹回放页**（页面结构、地图占比、统计项摆放）
不谈实时采集（那部分见已归档的 `enable-live-escort-location-and-track-summary`）

**一手材料**：`docs/ui/reference-screenshots/run-tracking/` 下 6 个产品 47 张 App Store 官方截图，
用 iTunes Lookup API 于 2026-08-12 抓取（沿用 `blind-ui-visual-benchmark-20260808.md` 的方法）。

⚠️ `docs/ui/reference-screenshots/` 整个目录被 `.gitignore:81` 排除，**图不在仓库里**，
换台机器要自己重抓。下表的 trackId 就是为此留的：

```bash
curl -s "https://itunes.apple.com/lookup?id={trackId}&country={cn|us}" \
  | python3 -c "import json,sys;[print(u) for u in json.load(sys.stdin)['results'][0]['screenshotUrls']]"
```

| 产品 | trackId | 区服 | 版本 |
|---|---|---|---|
| Strava | 426826309 | us | 476.0.0 |
| Nike Run Club | 387771637 | us | 7.79.2 |
| Keep | 952694580 | cn | 9.1.0 |
| 咕咚 | 453480684 | cn | 10.77.4 |
| 悦跑圈 | 881766160 | cn | 5.47.11 |
| 悦动圈 | 872341407 | cn | 5.17.171 |

⚠️ **材料的局限，先说清楚**：App Store 截图是营销物料，不是产品截图。47 张里真正露出
「地图 + 轨迹 + 统计」这一版式的只有 3 张（悦跑圈 04、Strava 02/04）。咕咚、Nike Run Club、
悦动圈的截图全是 3D 插画和榜单页，对本题**零信息量**——这三家的结论不该从这批材料里推。
下面每条结论都标了它站在哪张图上，没图支撑的地方写「未取证」。

---

## 0. 一句话结论

同类产品的回放页是**同一个版式**，没有第二种：

> **地图占顶部一大块（约屏高 35–45%）+ 下面一张卡片装标题和统计数字。**

我们仓库**这个版式已经有了一半**：`CompletedTrackSummaryView` 画了折线、算了里程时长配速。
缺的不是渲染能力，是三件事：**地图太小（220pt）、没有起终点标记、以及最要命的——
两个入口里有一个根本没挂这个组件**。详见 §3。

---

## 1. 版式：地图在上，统计在下（悦跑圈 04、Strava 04）

**悦跑圈 04.png** 是最贴近我们需求的一张，从上到下：

1. 顶部分段控件（地图 / 水平图）
2. **地图约占屏高 35%**，轨迹是一条**粗红色折线**，闭环路线看得出形状
3. 轨迹上有两个**蓝色圆形标记**，分别标「起」「终」
4. 白底卡片：路线名称（`奥森南门逆穿`）
5. **3 列统计网格 ×2 行**：路段全长 10.44 km / 累计爬升 71m / 累计下降 70m，第二行 0.7% / 656人 / 宽穿型
6. **起点 / 终点两行地址**，各带一个定位图标 + 完整街道地址

**Strava 04.jpg** 是同一骨架的另一种填法：视觉区（力量训练是人体肌群图，跑步则是地图）
占上半屏约 40%，下面卡片依次是头像+日期、活动标题、**2×2 统计网格**
（Elapsed Time 45:30 / Total Volume 4,115 lbs / Total Sets 47 / Avg Heart Rate 98 bpm）。

**Strava 02.jpg** 给出了**列表里的压缩版**：地图缩成一条通栏窄banner（约屏高 12%），
下面一行文字把统计横排（`1 day ago · 9.56 mi`）。

→ 两种密度都要：**列表/详情页内嵌用压缩版，点进去才是大屏版**。

## 2. 数字怎么排：3 列一行，标签在数字下面

悦跑圈和 Strava 都是**数字大、标签小、标签在数字正下方**，横向 3–4 列平分宽度。
没有一家把统计做成「标签: 值」的左右两端对齐行——而我们现在的 `summaryRow` 正是这种。

对我们的取舍：我们只有 **3 个统计量**（里程 / 时长 / 平均配速），正好一行 3 列。

⚠️ **但这条不能照抄到盲人端**。3 列并排的网格在 VoiceOver 里的遍历顺序依赖布局实现，
而 `.accessibilityElement(children: .combine)` 把一格合成一个元素后，读出来是「10.44 公里 里程」
（值在前标签在后）——语序是反的。**视觉排 3 列，无障碍标签单独给「里程 10.44 公里」的语序。**

## 3. 我们的差距（不来自截图，来自读代码，2026-08-12 核）

| # | 事实 | 位置 |
|---|---|---|
| A | 志愿者首页「近期服务」点进去的 `VolunteerOrderDetailView` **完全没有挂轨迹组件** | `VolunteerOrderFlowViews.swift:696-710` |
| B | 志愿者「服务记录」点进去的 `VolunteerReadOnlyOrderView` **挂了**，所以同一个订单换个入口就有 | 同文件 `:2640-2650` |
| C | 盲人端**根本没有历史订单列表**，`/api/orders/mine` 只被用来找当前进行中的那单 | `BlindRunnerHomeView.swift:165-169`；路由枚举只有 `voiceBooking`/`orderStatus`/`settings`（`:7-14`） |
| D | 地图高度写死 `220pt`，且是内嵌不可点，没有大屏页 | `CompletedTrackSummaryView.swift:53` |
| E | 轨迹上**没有起点/终点标记**，只有一条线 | 同文件 `:45-57`，只传了 `polylines`，`annotations` 为空 |

**A 就是用户报的那个现象**——「近期服务点进去看不到跑步路线」。B 的存在说明这不是能力缺失，
是**两个详情页各写各的**，其中一个漏了。

后端**不缺数据**：`run_order_track_point` 表、`GET /api/orders/{id}/track`、90 天留存策略
（`TrackDataRetentionScheduler`）都在 `origin/main` 上，DTO 也对得上前端的 `OrderTrackResponse`。

视口自适应**也已经实现**了，之前以为没有是看错了：`AMapContainer.swift:185-192` 对
`isPrimary` 的折线调 `setVisibleMapRect(boundingMapRect, edgePadding:)`，按签名去重只 fit 一次。

## 4. 被否掉的方案

- **「用 MapKit 而不是高德」**：否。本仓库地图只有高德一条通道（`MAMapView`），
  且坐标全链路是 GCJ-02，换 MapKit 要再引一套坐标转换，纯亏。
- **「轨迹按配速染色」**（Strava 的 pace-colored polyline）：否，YAGNI。
  后端 `TrackPointDto` 只给 `lat/lng/recordedAt`，没有逐点配速；要染色得客户端按相邻点时间差反算，
  而 GPS 抖动会让盲人陪跑这种低速场景的逐点配速噪声大于信号。等有人真的要再说。
- **「生成轨迹分享图 / 海报」**：否，本轮没人要。

---

## 5. 复核触发条件

- 悦跑圈或 Strava 的活动详情页发生重大改版（对标图会失效）
- 后端给 `TrackPointDto` 加了逐点配速或海拔字段（配速染色的否决理由随之消失）
- 我们把盲人端首页信息架构再动一次（本篇假定历史入口放设置里，理由见
  `blind-ui-visual-benchmark-20260808.md`「首页做减法」）
