# Tasks

## 1. 定位（N48 根因的第一环）

- [x] 1.1 `BlindBookingView` 启动语音时 `locationService.requestOneTimeLocation()` —— **正面修法**。`onAppear` 的 `startUpdating()` 是持续定位，而非陪跑模式 `distanceFilter = 10` 意味着站着不动 Core Location 不推新样本；`requestLocation()` 绕过它直接要一次新 fix，而用户接下来要说 10~20 秒，新坐标早在请求发出前就到了。
- [x] 1.2 语音那一处的 `latestBackendSample(freshness: 300)` —— 兜底。**只改这一处、不动方法默认值**：另外三个调用点（`ContentView:406`、`EmergencyCoordinator:119/126`、`VolunteerOrderFlowViews:1504`）各有各的新鲜度要求。
- [x] 1.3 新鲜度回归用例：60 秒前的样本下 `/parse` 请求仍带 `latitude`/`longitude`
      （`testAStaleDeviceSampleStillReachesTheParseRequest`）。**两侧都断言** —— 默认 15 秒门会把
      样本拒掉（坐标消失那一步），放宽后的门放行；只断言后者的话，有人把 `freshness: 300`
      清理回默认值也不会红。配套 `testNoCoordinateIsSentWhenThereIsNoRealDeviceSample`：
      没有真实设备采样时一个坐标都不许编。
  - [-] 1.3b `requestOneTimeLocation()` **真被调到**这一半没做成机器检查，理由记在这里：
        它在 `BlindBookingView.startVoiceWizard()`（SwiftUI View 的 private 方法）里，
        单测进不去；UI 测试观察不到这个调用；`guard.mjs` 是**行级禁止**规则，
        表达不了「某个调用必须存在」（要加就得引入文件级配对规则 + 给自测加写临时文件的通道，
        而它的 `pre` 模式只拿得到 edit 片段、拿不到整文件）。
        **删掉那行的后果是降级不是回归** —— 退回「接受最多 300 秒前的坐标」，
        N48 报的那个 1000 公里量级的失败仍然被兜住。所以按代价定档：
        留注释（`startVoiceWizard` 里那 8 行写清了为什么）+ 本条记录，不为它造一套新守卫。

## 2. 模型层

- [x] 2.1 `AddressCandidate`：`name` / `address` / `adname` / `business` / `distanceMeters` / 坐标。
- [x] 2.2 `readbackAddress` 计算属性 —— **镜像后端 `VoiceOrderService.readback`**（POI 名 + 空格 + 街道地址）。后端平铺 `address` 就是这么拼的，挑第二个必须拼出同样的形态，否则下游按空格切 POI 名的 `spokenAddress` 会切错。
- [x] 2.3 `ParseVoiceOrderResponse` 加 `candidates` / `addressUnresolved`，一律可选。
- [x] 2.4 `startCandidatesToDisambiguate` —— 判据只看**数量 ≥2**，不看 `needReask`：后端在这一轮同时可能报 `missing`，两者混在一起分不出「该消歧」还是「该追问」。
- [x] 2.5 `replacingStartPlace(with:)` —— 挑定后换掉快照，**并清空 `candidates`**。不清空的话下一轮又被 `startCandidatesToDisambiguate` 读到，用户为同一批候选被问第二遍。

## 3. 向导

- [x] 3.1 `Step` 新增 `.disambiguateStart(candidates:prompt:)`。**唯一一个由后端文案驱动的轮次** —— 候选的名称/行政区/距离只有后端知道。
- [x] 3.2 `speechField` 复用既有的 `.voiceOrderStartPlace`（逐项追问删掉后一直空着），不新增枚举值 —— 新增要同步 `isAllowlisted` 白名单，白拿一处可能漏改的地方。
- [x] 3.3 `parseFreeform` 里消歧**排在读回之前**。读回念的是最佳猜测，用户听完多半就说「确认」。
- [x] 3.4 `ordinalIndex(in:count:)`：汉字 + 阿拉伯数字两种写法；`count` 是护栏，只念了 2 个不许认「第三个」。
- [x] 3.5 三次挑不出来 → 取第一条 + **说出「按第一个来」**，不丢回表单。
- [x] 3.6 消歧轮里「重说」随时能退出去，复用确认轮的 `restartWords`。
- [x] 3.7 接 `addressUnresolved`：听见了地名却没查到时，读回前先说出来，且**与时长夹取提示一起说**，不是二选一。

## 4. 已知坑（踩过，别再踩）

- [x] 4.1 🔴 **消歧轮不能用 `promptAndListen`** —— 它开头 `reaskCount = 0`（那是给定向追问用的「不计入重问上限」路径），用在这里 3.5 那个上限**永远数不到**，挑不出来的用户被永远关在候选列表里。真机 XCTest 抓到的，已改成 `speak` + `listen`。
- [x] 4.2 `BlindBookingView` 的 `onChange(of: voiceWizard.step)` 是 exhaustive switch，加 Step 值要同步。消歧轮同样停在确认页 —— 换页会把用户从他刚听到的内容上挪开。

## 5. 配套

- [x] 5.1 Mock 产 `candidates`，播报文案逐字照抄后端 `buildCandidateTts`（含「距您 X 米」与超 1 公里换单位）。不做的话开发期与 demo 环境永远走不到消歧轮。
- [x] 5.2 Mock 候选断言 4 条：带坐标且同名 ≥2 才有候选 / 没坐标就没有 / 只有一个同名不问
      （`testMockReturnsCandidatesOnlyForSameNamePlacesWithCoordinates`）；播报文案形状与后端
      `buildCandidateTts` 一致（`testMockCandidateTtsMatchesTheBackendShape`，含「距您」与
      平铺 `address` == 候选第一项的 `readbackAddress`）；🔴 catch-all 条目 `("公园", "本市公园")`
      不许被当成同名兄弟（`testMockCatchAllParkEntryNeverFabricatesCandidates`）—— 否则每个带
      「公园」二字的地名都凭空多出一轮消歧；抽到 span 却查不到坐标时 `addressUnresolved` 为 true
      （`testMockReportsAddressUnresolvedWhenTheSpanCannotBeGeocoded`）。
      同名 fixture 用「万象城」，`address` 非 nil，所以 `readbackAddress` 的「POI 名 + 空格 + 街道」
      那条分支是走到的（对方提醒的那点）—— 线上高德多数时候有 `address`，只测单段会漏。
- [x] 5.3 词表门禁加第 4 张表，**方向与前三张相反**：前三张查「本地认的词后端会不会判成别的」，这张查「后端念给用户的词本地认不认得」，读后端 `VoiceOrderService.ORDINALS`。
- [x] 5.4 pre-push 后端新鲜度清单补上词表门禁读的两个 `.java`。

## 6. 验证

- [x] 6.1 真机 XCTest：`Executed 85 tests, with 0 failures` — **TEST SUCCEEDED**。9 条新用例逐条确认执行（`Test Case '...' passed` 逐条 grep），不是「套件绿就算跑了」。
- [x] 6.2 pre-push 全门禁通过（含新增序数覆盖检查、golden-corpus 96 条、codegen 比对）。
  ⚠️ 后端 N48 **已合入 `origin/main`**（`08466c2`），所以**不需要** `AIDRUN_ALLOW_BACKEND_DRIFT=1`。跨端顺序是「后端契约先合，再推前端」。
- [ ] 6.3 真机手测：站着说「明天早上八点从万象城出发跑一个小时」，确认听到序号播报、说「第二个」能选中。
      **必须真人说**（要验的正是真实人声），两个 session 都做不了这一步。
- [x] 6.4 「第二个」的渲染形式**不必再测** —— 2026-08-06 已实测，记在 `demo/docs/handoff.md:2072-2088`：
      「第一个/第二个/第三个/就第二个吧/选第三个/我要第一个」**12/12 全对**，加不加 `contextualStrings`
      偏置逐字相同，渲染出来是**汉字**不是「第2个」。
      ⚠️ 但那批是**合成音频**：6.3 要验的是**真实人声下的召回**（户外风噪会掉），
      不是渲染形式。两者别混为一谈 —— 把已测的当未知，会有人为「第2个」加一条其实用不上的分支；
      把未测的当已知，则会以为真人说一遍必成。

## 7. 归档顺序（⚠️ 别搞错）

- [ ] 7.1 本变更 MODIFY 的 `blind-runner-voice-first-experience`，`enable-one-utterance-booking` 与 `enable-cross-turn-voice-correction` 两个未归档变更也 MODIFY 过。**本变更必须最后归档**，且上面的 MODIFIED 块已基于 `enable-cross-turn-voice-correction` 那一版写 —— 否则会把跨轮修正那批的 Scenario 覆盖回去。
