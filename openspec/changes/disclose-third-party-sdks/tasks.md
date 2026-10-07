## 1. 实现

- [x] 1.1 首启告知加高德一条、改「不出售给任何人」、`disclosureVersion` 2 → 3、摘要点名高德
- [x] 1.2 内置隐私政策「第三方 SDK」一节（高德 iOS 条目 + 阿里云）与可点链接（`LegalFallbackCopy.Section.links`）
- [x] 1.3 `AMapManager` 显式关闭 `securityAgree` / `analysisAgree`
- [x] 1.4 调研落盘 `docs/research/third-party-sdk-disclosure-ios-20261007.md` 并回写索引

## 2. 验证

- [ ] 2.1 单测 `PrivacyConsentTests`（指纹、高德条目、链接）真机执行
- [ ] 2.2 真机：首启弹窗与隐私政策页截图；读屏双击链接能打开；断点或日志确认两项扩展功能为 false
- [ ] 2.3 负责人确认首启那句里的「Wi-Fi、基站」在 iOS 上要不要改（高德 iOS 条目没有这两项）
