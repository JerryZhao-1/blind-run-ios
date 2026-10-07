# iOS 第三方 SDK 的隐私披露：高德与阿里云实人认证该写什么（2026-10-07）

> 起因：iOS #355（安卓 #54 同源）。`AMapManager` 向高德声明「告知已含高德条款」，而首启告知与内置隐私政策都没写高德。
> 本文只记**厂商原文**与本仓库实测；措辞决定在 PR 里。

## 1. 高德《SDK 合规使用方案》

- 来源：<https://lbs.amap.com/compliance-center/check-and-reference/sdkhgsy>（页面「最后更新时间: 2026年09月09日」，2026-10-07 用 firecrawl 抓原文）。
- **iOS 版高德开放平台地图 SDK 合包**（本仓库三个 pod：`AMap3DMap-NO-IDFA` 11.1.200 / `AMapLocation-NO-IDFA` 2.11.1 / `AMapSearch-NO-IDFA` 9.7.5，基础库 `AMapFoundation-NO-IDFA` 1.8.7）原文：
  - 第三方名称：北京高德图强科技有限公司
  - 使用目的：为了实现地图展示、定位、搜索等服务
  - 收集个人信息：经纬度、搜索词、传感器信息（矢量、加速度、压力）、IDFA、当前应用信息（应用名、应用版本号）、设备参数及系统信息（设备品牌及型号、操作系统、运营商信息、屏幕分辨率）
  - 信息收集方式：SDK本机采集
  - 第三方隐私政策：<https://lbs.amap.com/pages/privacy/>
- 🔑 **与安卓合包不同**：安卓那条多出「IP 地址、GNSS、网络类型、WiFi 状态/参数/列表/信号强度/网关、SSID、BSSID、基站信息、传感器（方向、地磁）、设备信号强度」与 OAID。**iOS 条目里没有 Wi-Fi、基站、IP。**
- IDFA：同页「SDK 可选个人信息」表把 IDFA 列为 iOS 可选项，配置方式是「提供不同功能的基础库下载」⇒ 本仓库用 NO-IDFA 基础库，不收 IDFA。
- 隐私政策要求：「正确透出且用户可点击《高德地图开放平台隐私权政策》链接」；首次打开时弹窗、有明显同意和拒绝按钮；进入主功能后 4 次点击内能访问到隐私政策。
- 扩展功能：「安全保障服务」「数据分析和处理」，配置方式原文「由开发者提供给用户选择，用户选择是或否后，对应API传入true或者false」。数据分析的用途原文含「帮助优化广告投放营销效果、辅助商业决策分析」。

## 2. iOS 基础库里两项扩展功能的默认值（本机头文件实证）

`Pods/AMapFoundation-NO-IDFA/AMapFoundationKit.framework/Headers/AMapServices.h:144-150`：

- `securityAgree`：「用户是否同意数据用于安全保障。默认为YES。since 1.8.7」
- `analysisAgree`：「用户是否同意数据用于统计分析。默认为YES。since 1.8.7」

⇒ **iOS 默认开**，安卓（jar 11.3.100，见安卓 #54）默认关。iOS 不显式关，就是在没问用户的情况下把数据交给高德做统计分析（含广告投放优化）。

## 3. 阿里云金融级实人认证 SDK

- 本仓库 `Vendor/AliyunCloudAuth/2.3.50`（聚合包，只取了 ID_PRO 人脸核验子集，含 `APPSecuritySDK.framework`）。
- 合规说明：<https://help.aliyun.com/zh/id-verification/financial-grade-id-verification/security-and-compliance/compliance-description> —— 披露格式：SDK 名称「金融级实人认证SDK」、业务功能「身份认证」、收集类型「按照实际配置采集信息的情况填写」、隐私政策链接。iOS 可选项只有 IDFA（「通过裁剪APPSecuritySDK.framework模块控制」）。
- SDK 隐私政策：<https://terms.aliyun.com/legal-agreement/terms/suit_bu1_ali_cloud/suit_bu1_ali_cloud202107281509_18386.html>（「更新日期：2024年5月22日」）。主体：**杭州阿里云智能科技有限公司**。收集项原文：
  - 设备基础信息：设备制造商、设备品牌、设备类型及型号、设备名称、设备操作系统信息、设备内存及存储大小、电池及电量信息、基带信息、开机时间、屏幕亮度及分辨率、CPU信息、系统时区、系统语言、充电状态、系统内核信息、传感器列表、光线传感器信息
  - 设备标识信息：IDFA（可选）、IDFV、Android ID、OAID
  - 设备网络信息：BSSID、SSID、运营商信息、网络类型、SIM卡状态
  - 设备应用信息：宿主APP应用名称、版本、安装时间
  - 人脸与身份：姓名、身份证号、人脸图片和视频流（OCR、多因子意愿认证本仓库没接）
  - 日志：操作参数、操作时间、服务响应时间、操作步骤、验证结果、错误原因
- IDFA：App 的 `Info.plist` 没有 `NSUserTrackingUsageDescription`、从不申请广告追踪授权 ⇒ 系统不给 IDFA，政策里不列。

## 4. 结论（落到 #355 的实现）

1. 首启告知加高德一条，**按负责人要求与安卓逐字一致**。⚠️ 那句写着「Wi-Fi、基站」，而高德 iOS 条目没有 —— 是多告知不是少告知，已在 #355 提出由负责人定。
2. 内置隐私政策「第三方 SDK」一节按 iOS 条目写（去掉 IDFA），阿里云按其政策写（去掉 IDFA、Android ID、OAID 与没接的 OCR/多因子），两条链接可点。
3. 初始化高德时显式 `securityAgree = false`、`analysisAgree = false`。

## 5. 复核触发条件

高德 SDK 换版本或换 pod（尤其换回带 IDFA 的基础库）；高德合规方案页「最后更新时间」晚于 2026-09-09；阿里云实人认证换版本、接入 OCR / 多因子 / 裁掉 `APPSecuritySDK`；产品决定给用户提供扩展功能的选择。
