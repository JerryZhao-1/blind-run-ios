## Why

用户真机报的：**定位是开着的**，在深圳南山区说「阳光棕榈园」被定位到广东其它城市，说「前海万象」被定位到**海南**。两个真实地点都在南山区附近。

模型抽 span 是对的，错在**地名 → 坐标**这一段，根因两级：

**① 坐标压根没送到后端。** `LocationService.latestBackendSample()` 有一道 **15 秒**新鲜度门，而非陪跑模式下 `locationManager.distanceFilter = 10` —— 站着不动 Core Location 不推新样本，而语音下单恰恰是**站着说完一整句**（10~20 秒）。于是 `VoiceOrderWizard` 的取样闭包返回 nil，`/parse` 请求不带 `latitude`/`longitude`，后端只能做全国范围解析。

**② 后端拿全国范围的正向编码兜底。** 周边搜索没命中就回落 `/v3/geocode/geo`，而那是**结构化地址**解析接口，对 POI 简称只能分词尽力匹配（「前海万象」被拆出「前海」），且调用不传 `city`、不看 `level`、无条件取 `geocodes[0]`。已由后端 N48 修掉（`08466c2`，PR #54）：带了坐标却搜不到候选时不再回落，改报 `addressUnresolved`。

**放大器**：多候选 + 拼音重排（SPEC B2 的产出）只挂在 `resolve-address` 上，而客户端只调 `/parse`。**做完了 ≠ 用户走得到。**

后端同批新增 `ParseVoiceOrderResponse.candidates`（起点同名候选，≥2 条即消歧轮，`ttsText` 是序号播报），iOS 侧需要接。

## What Changes

- 语音开始时主动 `requestOneTimeLocation()` 要一次新 fix；语音这一处的新鲜度门放宽到 300 秒兜底
- 新增**候选消歧轮**：起点撞同名地点时先念候选让用户挑，再读回整单
- 序数（「第二个」）**在客户端本地判定**，那一轮的回答不发回 `/parse`
- 接 `addressUnresolved`：听见了地名却没查到时，读回前先说出来

## Impact

- Affected specs: `blind-runner-voice-first-experience`
- Affected code: `VoiceOrderWizard`、`VoiceOrderModels`、`BlindBookingView`、`MockAPIClient`
- 依赖后端 N48（**已合入 `origin/main`**，`08466c2`）

## 明确不做

- **终点不做多候选。** 一次播起点 3 项 + 终点 3 项超过纯听觉工作记忆的约 3 项上限（那也是候选截断在 3 条的原因）。终点抽错由读回念出来、用户说「终点错了」走 `correctionTarget` 纠正。
- **消歧轮的回答不回传后端。** 「第二个」不是地名，模型可能把它圈成 `start_address_span`，高德查不到又按既有口径保留下来，于是把 `current` 里刚选好的地址冲掉。消歧闭环整个留在客户端。
- **挑不出来时不丢回表单。** 手上已经有一个可用的最佳猜测，而读回会把它念出来、用户仍可以说「重说」。但**必须说出「按第一个来」** —— 静默取第一条正是这批改动要消灭的那个失败。
