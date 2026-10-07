import Foundation
import AMapFoundationKit
import AMapLocationKit
import AMapSearchKit
import MAMapKit

// MARK: - AMap SDK Manager

/// 高德地图 SDK 初始化管理器。
/// 从 Info.plist 读取 AMap API Key 并初始化 SDK。
/// 当 Key 未配置时优雅降级，不会导致崩溃。
enum AMapManager {

    /// SDK 是否已成功配置（Key 有效且 SDK 初始化完成）
    private(set) static var isConfigured = false

    /// 初始化高德地图 SDK。
    /// 应在 App 启动时调用一次（如 blindRunApp.onAppear）。
    static func configure() {
        guard let key = resolveAPIKey(),
              !key.isEmpty,
              key != "YOUR_AMAP_IOS_KEY_HERE" else {
            isConfigured = false
            #if DEBUG
            print("[AMapManager] 高德地图 Key 未配置，地图功能不可用。请参考 LocalConfig.xcconfig.example 配置 Key。")
            #endif
            return
        }

        configurePrivacyCompliance()
        AMapServices.shared().apiKey = key
        AMapServices.shared().enableHTTPS = true
        isConfigured = true

        #if DEBUG
        print("[AMapManager] 高德地图 SDK 初始化成功")
        #endif
    }

    private static var cachedApprovalNumber: String?

    /// 高德底图的审图号（后端 issue #382）。地图页从自己的 `mapView` 取；「关于」页没有地图实例，
    /// 传 nil 时用缓存，没打开过地图就临时建一个取值。SDK 未配置时返回 nil（那时也没有地图可标）。
    @MainActor
    static func mapContentApprovalNumber(from mapView: MAMapView? = nil) -> String? {
        if let cachedApprovalNumber { return cachedApprovalNumber }
        guard isConfigured else { return nil }
        let value: String? = (mapView ?? MAMapView(frame: .zero)).mapContentApprovalNumber()
        cachedApprovalNumber = value?.nilIfBlank
        return cachedApprovalNumber
    }

    // MARK: - Private

    private static func configurePrivacyCompliance() {
        // App privacy policy includes AMap SDK usage; these calls must happen before creating SDK clients/views.
        MAMapView.updatePrivacyShow(.didShow, privacyInfo: .didContain)
        MAMapView.updatePrivacyAgree(.didAgree)
        AMapSearchAPI.updatePrivacyShow(.didShow, privacyInfo: .didContain)
        AMapSearchAPI.updatePrivacyAgree(.didAgree)
        AMapLocationManager.updatePrivacyShow(.didShow, privacyInfo: .didContain)
        AMapLocationManager.updatePrivacyAgree(.didAgree)
        // 高德两项扩展功能（安全保障、数据用于统计分析）按高德合规方案「由开发者提供给用户选择」；
        // 我们没问过用户，而统计分析的用途原文含「帮助优化广告投放营销效果」，与首启告知「不做广告」冲突。
        // 🔴 iOS 基础库里两者**默认 YES**（`AMapServices.h`：「默认为YES。since 1.8.7」），与安卓默认关相反 ——
        // 不显式关，隐私政策里「两项都没有开启」那句就是假的（#355）。
        AMapServices.shared().securityAgree = false
        AMapServices.shared().analysisAgree = false
    }

    private static func resolveAPIKey() -> String? {
        // 优先从 Info.plist 的 AMapApiKey 字段读取（由 xcconfig 注入）
        if let key = Bundle.main.infoDictionary?["AMapApiKey"] as? String {
            return key
        }
        // 备选：从 AMAP_API_KEY 字段读取
        if let key = Bundle.main.infoDictionary?["AMAP_API_KEY"] as? String {
            return key
        }
        return nil
    }
}
