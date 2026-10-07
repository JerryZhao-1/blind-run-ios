## Why

`AMapManager.configurePrivacyCompliance` 一直向高德声明「隐私政策已含高德条款、用户已同意」，但首启告知和内置隐私政策都没写高德（iOS #355，安卓 #54 同源，负责人 2026-10-07 同意推荐方案）。另外 iOS 高德基础库里「安全保障」「数据用于统计分析」两项扩展功能**默认开启**（`AMapServices.h`），统计分析的用途原文含「帮助优化广告投放营销效果」，与告知里「不做广告」冲突，而我们从没问过用户。阿里云实人认证 SDK 同样没有在政策里披露。

## What Changes

- 首启告知 `disclosureVersion` 2 → 3：在「运动数据」后加高德一条（与安卓逐字一致）；「不卖给第三方」改「不出售给任何人」；首启摘要点名高德。
- 内置隐私政策新增「第三方 SDK」一节：高德（按高德 iOS 地图合包条目，NO-IDFA）与阿里云金融级实人认证（按其 SDK 隐私政策）的提供方、目的、收集项、收集方式，以及两条**可点**的隐私政策链接。
- 初始化高德时显式关闭两项扩展功能（`securityAgree` / `analysisAgree` = false）。

## Capabilities

### New Capabilities
- `third-party-sdk-disclosure`: 首启告知与内置隐私政策如何披露第三方 SDK，以及第三方 SDK 的可选扩展功能默认关闭。

### Modified Capabilities

## Impact

- 代码：`blindRun/Core/PrivacyConsent.swift`、`blindRun/Core/Models/LegalLinksModels.swift`、`blindRun/Core/LegalDocumentsView.swift`、`blindRun/Map/AMapManager.swift`。
- 老用户：版本 +1 ⇒ 下次冷启动重新看一次首启告知。v2 未随任何外部构建分发。
- 依据：`docs/research/third-party-sdk-disclosure-ios-20261007.md`。
