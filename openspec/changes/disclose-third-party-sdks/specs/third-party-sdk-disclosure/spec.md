## ADDED Requirements

### Requirement: 首启告知点名高德 SDK

首启告知 SHALL 有一条独立的告知说明地图、定位和地址搜索由高德开放平台 SDK（北京高德图强科技有限公司）提供及其收集与发送，文本与安卓逐字一致；首启摘要 SHALL 点名高德。告知 MUST NOT 出现「不卖给第三方」（改为「不出售给任何人」）。告知内容变化 SHALL 使 `disclosureVersion` +1。

#### Scenario: 老用户冷启动
- **WHEN** 已同意 v2 首启告知的用户升级后冷启动
- **THEN** 再次看到首启告知，其中含高德那一条

### Requirement: 隐私政策披露第三方 SDK 且链接可点

内置隐私政策 SHALL 有「第三方 SDK」一节，逐项列出高德与阿里云金融级实人认证 SDK 的提供方、使用目的、收集的个人信息与收集方式；收集项 MUST 取自厂商针对 iOS 的条目，不得照抄安卓。两家的隐私政策链接 SHALL 可点击打开。

#### Scenario: 读屏用户打开链接
- **WHEN** VoiceOver 用户在「第三方 SDK」一节聚焦「高德地图开放平台隐私权政策」并双击
- **THEN** 在浏览器里打开 `https://lbs.amap.com/pages/privacy/`

### Requirement: 第三方 SDK 可选扩展功能默认关闭

高德 SDK 的「安全保障」「数据用于统计分析」两项扩展功能 MUST 在 SDK 初始化时显式关闭，直到产品为用户提供选择。

#### Scenario: 初始化高德
- **WHEN** App 配置高德 SDK
- **THEN** `AMapServices.securityAgree` 与 `analysisAgree` 均为 false
