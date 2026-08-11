import Combine
import CoreLocation
import SwiftUI
import UIKit

// MARK: - Booking Option Types

enum BookingDurationOption: Int, CaseIterable, Identifiable {
    case none = 0
    case fifteen = 15
    case thirty = 30
    case fortyFive = 45
    case sixty = 60
    case ninety = 90
    case oneTwenty = 120

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .none: return "不填写"
        case .fifteen: return "15 分钟"
        case .thirty: return "30 分钟"
        case .fortyFive: return "45 分钟"
        case .sixty: return "1 小时"
        case .ninety: return "1.5 小时"
        case .oneTwenty: return "2 小时"
        }
    }

    var minutes: Int? {
        rawValue == 0 ? nil : rawValue
    }
}

enum BlindBookingGuidedStep: Int, CaseIterable, Identifiable {
    case startPoint
    case appointmentTime
    case runningNeeds
    case review

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .startPoint:
            return "确认出发地点"
        case .appointmentTime:
            return "确认预约时间"
        case .runningNeeds:
            return "跑步需求"
        case .review:
            return "确认并提交"
        }
    }

    var shortName: String {
        switch self {
        case .startPoint:
            return "地点"
        case .appointmentTime:
            return "时间"
        case .runningNeeds:
            return "需求"
        case .review:
            return "确认"
        }
    }

    var nextActionTitle: String {
        switch self {
        case .startPoint:
            return "下一步：预约时间"
        case .appointmentTime:
            return "下一步：跑步需求"
        case .runningNeeds:
            return "下一步：确认预约"
        case .review:
            return "提交预约"
        }
    }

    var nextSpeechAction: String {
        switch self {
        case .startPoint:
            return "确认地点后进入预约时间。"
        case .appointmentTime:
            return "确认时间后进入跑步需求。"
        case .runningNeeds:
            return "可跳过选填需求，进入确认预约。"
        case .review:
            return "确认无误后提交预约。"
        }
    }
}

struct BookingReviewItem: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String
}

// MARK: - Booking Gate

/// `POST /api/orders` 的硬门槛，枚举顺序即「第一个可操作的缺失项」的播报顺序。
///
/// 服务端门槛的唯一真源是 `OrderCreationService.createOrder`：
/// `verifyStatus != VERIFIED` → 403 `IDENTITY_NOT_VERIFIED`，
/// 随后才是无紧急联系人 → 403 `EMERGENCY_CONTACT_REQUIRED`（2026-07-30 起，见 `handoff.md`）。
/// **实名必须排在紧急联系人之前**，否则本地播报的「下一步」会和服务端实际拒绝的原因对不上。
/// `basicProfile` 是客户端自有的前置项（后端不校验 `BlindProfile.name`），保持在最前不影响上述同序。
enum BlindBookingGate: Equatable {
    case basicProfile
    case identityVerification
    case emergencyContacts
    case locationPermission
    case startPoint
    case appointmentTime

    static func firstMissing(
        isBasicProfileComplete: Bool,
        isIdentityVerified: Bool,
        hasValidEmergencyContacts: Bool,
        isLocationDenied: Bool,
        hasStartPoint: Bool,
        isAppointmentTimeValid: Bool
    ) -> BlindBookingGate? {
        if !isBasicProfileComplete { return .basicProfile }
        if !isIdentityVerified { return .identityVerification }
        if !hasValidEmergencyContacts { return .emergencyContacts }
        if isLocationDenied { return .locationPermission }
        if !hasStartPoint { return .startPoint }
        if !isAppointmentTimeValid { return .appointmentTime }
        return nil
    }

    /// 展示与朗读共用的缺失说明。
    var message: String {
        switch self {
        case .basicProfile:
            return "请先完善个人资料，至少填写昵称。"
        case .identityVerification:
            return "请先完成实名认证才能下单。返回上一页，打开右上角设置，选择实名认证，填写姓名和身份证号后提交。"
        case .emergencyContacts:
            return "请先设置紧急联系人：至少 1 位，并指定其中 1 位为主联系人。"
        case .locationPermission:
            return "定位权限未开启。请前往系统设置开启定位，以便创建跑步预约。"
        case .startPoint:
            return "请选择出发地点。"
        case .appointmentTime:
            return "预约时间需至少在 30 分钟后。"
        }
    }
}

// MARK: - Blind Booking ViewModel

@MainActor
final class BlindBookingViewModel: ObservableObject {
    @Published var currentStep: BlindBookingGuidedStep = .startPoint
    @Published var placeSearchKeyword = ""
    @Published var placeSearchResults: [ResolvedPlace] = []
    @Published var selectedStartPlace: ResolvedPlace?
    @Published var currentResolvedPlace: ResolvedPlace?
    /// 本次预约的终点。**只有语音会写它** —— 表单向导没有终点输入，产品上终点是纯可选槽位，
    /// 而在表单里再加一段 POI 搜索 + 候选列表，对看不见屏幕的人是又一段同样长的交互。
    ///
    /// `nil` = 用户未指定，任何读回与展示都**一个字不提终点**（不是「原路返回起点」）。
    @Published var endPlace: BookingEndPlace?
    @Published var startLocationDescription = ""
    @Published var appointmentTime = Date()
    @Published var routeNotes = ""
    /// 表单那个选择器的绑定。**它只是 UI**，真正下单用的分钟数看 `resolvedDurationMinutes`。
    @Published var duration: BookingDurationOption = .none {
        didSet {
            // 手动改了选择器就以选择器为准 —— 用户刚在屏幕上做的动作，优先级高于上一轮语音。
            guard duration != oldValue else { return }
            exactDurationMinutes = duration.minutes
        }
    }
    /// 语音说出来的**精确**分钟数。
    ///
    /// 枚举只有 6 个档位、最大 120 分钟，而契约允许 10–300（`api_spec.yaml:2549`）。
    /// 枚举存在的理由是「选择器需要有限选项」，而**说话的人不需要选择器** ——
    /// 让语音迁就一个为触屏设计的控件，等于把用户说的「三个小时」改成两小时。
    /// 2026-08-06 用户报的「时间上只有两个小时这样的限制」就是这条。
    @Published var exactDurationMinutes: Int?
    @Published var pacePreference: PacePreference = .noPreference
    @Published var routePreference: RoutePreference = .noPreference
    /// 本次是否携带导盲犬。**三态，不是布尔** —— `nil` 与 `false` 在下单时的含义完全不同：
    ///
    /// - `nil` —— 没提。请求里不传该字段，后端回落 `BlindProfile.hasGuideDog` 档案默认值。
    /// - `false` —— 本次明确不带（语音说「今天不带导盲犬」）。原样传。
    ///
    /// 这个字段进派单的**硬过滤**（不接受导盲犬的志愿者被直接踢出候选池）。
    /// 把 `false` 塌缩成 `nil`，档案里登记了导盲犬的用户说了「今天不带」也会按"带"派单，
    /// 候选池被无声缩小 —— 而盲人全程听不出来。表单那个开关只能表达 `nil`/`true`
    /// （关掉 = 没提），语音是唯一能说出 `false` 的入口。
    @Published var hasGuideDogThisRun: Bool?
    @Published var specialNotes = ""
    @Published var isSubmitting = false
    @Published var isResolvingStartLocation = false
    @Published var isSearchingPlaces = false
    @Published var errorMessage: String?
    @Published var placeMessage: String?
    @Published var searchResultFocusID: String?
    @Published private(set) var auxiliaryMapCenter: CLLocationCoordinate2D?
    @Published private(set) var auxiliaryMapPlace: ResolvedPlace?

    private weak var appState: AppState?
    private weak var locationService: LocationService?
    private weak var placeSearchProvider: (any PlaceSearchProviding)?
    private var speechService: SpeechService?
    private static let auxiliaryMapMarkerRefreshDistanceMeters: CLLocationDistance = 30

    var minimumAppointmentTime: Date {
        Date().addingTimeInterval(TimeInterval(AppConstants.Timing.minimumBookingLeadMinutes * 60))
    }

    var isAppointmentTimeValid: Bool {
        appointmentTime >= minimumAppointmentTime
    }

    /// 下单前第一个未通过的门槛；nil 表示全部通过。
    var firstMissingGate: BlindBookingGate? {
        BlindBookingGate.firstMissing(
            isBasicProfileComplete: appState?.isBlindBasicProfileComplete ?? true,
            isIdentityVerified: appState?.isBlindIdentityVerified ?? true,
            hasValidEmergencyContacts: appState?.hasValidEmergencyContacts ?? true,
            isLocationDenied: locationService?.isDenied == true,
            hasStartPoint: resolvedStartPlace != nil,
            isAppointmentTimeValid: isAppointmentTimeValid
        )
    }

    var canSubmit: Bool {
        !isSubmitting && firstMissingGate == nil
    }

    var isFirstStep: Bool {
        currentStep == BlindBookingGuidedStep.allCases.first
    }

    var isReviewStep: Bool {
        currentStep == .review
    }

    var canAdvanceFromCurrentStep: Bool {
        blockingReasonForCurrentStep == nil
    }

    var blockingReasonForCurrentStep: String? {
        switch currentStep {
        case .startPoint:
            if locationService?.isDenied == true {
                return "定位权限未开启。请前往系统设置开启定位，以便创建跑步预约。"
            }
            if resolvedStartPlace == nil {
                return "请选择出发地点。"
            }
            return nil
        case .appointmentTime:
            return isAppointmentTimeValid ? nil : "预约时间需至少在 30 分钟后。"
        case .runningNeeds:
            return nil
        case .review:
            // 审阅步的按钮禁用状态走 `canSubmit`，它查的是全部六道门槛。这里必须用同一个源，
            // 否则缺资料 / 实名 / 紧急联系人时按钮是灰的、`primaryActionHint` 却回落到
            // 「提交后系统将为你派单」—— 一个按不动的按钮配一句承诺，对看不见屏幕的人
            // 就是「点了没反应」，而真正的原因一个字都没播。
            //
            // 曾经这里手抄了后三道门槛（定位 / 起点 / 时间），顺序与 `firstMissingGate` 一致，
            // 少的正是要去别的页面才能补的前三道。
            return firstMissingGate?.message
        }
    }

    var stepProgressText: String {
        let total = BlindBookingGuidedStep.allCases.count
        return "第 \(currentStep.rawValue + 1) 步，共 \(total) 步"
    }

    var appointmentSummary: String {
        let timeText = DateFormatter.aidRunDisplayDateTime.string(from: appointmentTime)
        if isAppointmentTimeValid {
            return "预约时间：\(timeText)。"
        }
        return "预约时间：\(timeText)。预约时间需至少在 30 分钟后。"
    }

    var startPointSourceText: String {
        guard let place = resolvedStartPlace else {
            return "出发地点尚未解析。"
        }
        switch place.source {
        case .deviceLocation:
            return selectedStartPlace == nil ? "使用设备当前位置。" : "已选择高德地点。"
        case .manual:
            return "已选择高德地点。"
        case .demoDefault:
            return "正在使用演示坐标，不代表真实会合点。"
        }
    }

    /// 下单真正用的时长。语音说了精确值就用精确值，否则用选择器那一档。
    var resolvedDurationMinutes: Int? {
        exactDurationMinutes ?? duration.minutes
    }

    /// 读回与复核用的时长文案。**按精确分钟数生成**，不套枚举的 `displayName` ——
    /// 说了三个小时就该念「3 小时」，不是念一个最接近的档位名。
    var resolvedDurationText: String? {
        guard let minutes = resolvedDurationMinutes else { return nil }
        return Self.durationText(forMinutes: minutes)
    }

    static func durationText(forMinutes minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        switch (hours, remainder) {
        case (0, _): return "\(remainder) 分钟"
        case (_, 0): return "\(hours) 小时"
        default: return "\(hours) 小时 \(remainder) 分钟"
        }
    }

    var startPointSummary: String {
        let placeText = resolvedStartLocationDescription.nilIfBlank ?? "正在获取当前位置"
        return "\(startPointSourceText)出发地点：\(placeText)。"
    }

    /// 终点读回。**必须紧挨着 `startPointSummary` 念**，别塞进选填需求那一段。
    ///
    /// 起终点由大模型抽取，抽反了（「从五角场跑到人民广场」听成反过来）只有读回能被用户发现，
    /// 而两句挨着才听得出反没反 —— 中间隔着预约时间就听不出来了。后端 `api_spec.yaml:2843`
    /// 也是拿读回当这条防线的。
    ///
    /// 没有终点时返回空串：`nil` 的语义是「用户未指定」，多说一句「本次没有结束地点」
    /// 会让人以为系统漏听了他没说过的话。
    var endPointSummary: String {
        guard let endPlace else { return "" }
        if endPlace.isUnresolved {
            // 查不到坐标仍然照下单（后端允许「有地址无坐标」），但**必须说出来**：
            // 不说，盲人会以为终点已经定准了，而实际上志愿者拿到的只是一个地名。
            return "结束地点：\(endPlace.address)。这个地点没能定位到，志愿者会看到这个名字。"
        }
        return "结束地点：\(endPlace.address)。"
    }

    var optionalReviewItems: [BookingReviewItem] {
        var items: [BookingReviewItem] = []
        if let routeNotes = routeNotes.nilIfBlank {
            items.append(BookingReviewItem(id: "routeNotes", title: "路线备注", value: routeNotes))
        }
        if let durationText = resolvedDurationText {
            items.append(BookingReviewItem(id: "duration", title: "预计时长", value: durationText))
        }
        if pacePreference != .noPreference {
            items.append(BookingReviewItem(id: "pace", title: "配速偏好", value: pacePreference.displayName))
        }
        if routePreference != .noPreference {
            items.append(BookingReviewItem(id: "route", title: "路线偏好", value: routePreference.displayName))
        }
        // `false` 也要念。用户说了「今天不带导盲犬」却在读回里一个字听不到，
        // 与"我们没听懂"无从区分 —— 而这一项进派单硬过滤，听不出来的代价是候选池被改了。
        if let hasGuideDogThisRun {
            items.append(BookingReviewItem(
                id: "guideDog",
                title: "导盲犬",
                value: hasGuideDogThisRun ? "本次携带" : "本次不带"
            ))
        }
        if let specialNotes = specialNotes.nilIfBlank {
            items.append(BookingReviewItem(id: "specialNotes", title: "特殊说明", value: specialNotes))
        }
        return items
    }

    var optionalNeedsSpeechSummary: String {
        let items = optionalReviewItems
        guard !items.isEmpty else {
            return "没有填写选填跑步需求。"
        }
        return items.map { "\($0.title)：\($0.value)" }.joined(separator: "。") + "。"
    }

    var reviewSummarySpeech: String {
        let blockingText = blockingReasonForCurrentStep.map { "当前还不能提交，\($0)" } ?? ""
        return "请确认预约。\(startPointSummary)\(endPointSummary)\(appointmentSummary)\(optionalNeedsSpeechSummary)\(blockingText)"
    }

    /// 零输入下单那一步要复核的整单。
    ///
    /// **必须念绝对时刻，不许说「最早可约时间」。** 走到这条路径的用户语音已经坏了，屏幕他也看不见 ——
    /// 「最早可约时间」是一个他无法验证的相对说法，而下单是会真实派单的不可逆动作。
    /// 表单路径靠 `reviewSection` 把整单摆在屏幕上满足 WCAG 3.3.4 的「可复核确认」，
    /// 零输入路径没有那一屏，这句话就是它的等价物 —— 它同时是确认按钮的 `accessibilityLabel`。
    var zeroInputSummary: String {
        let place = resolvedStartLocationDescription.nilIfBlank ?? "当前位置"
        let time = DateFormatter.aidRunDisplayDateTime.string(from: appointmentTime)
        return "从\(place)出发，\(time) 开始，直接下单"
    }

    var currentStepSpeechSummary: String {
        let blockingText = blockingReasonForCurrentStep.map { "当前阻塞：\($0)" } ?? ""
        switch currentStep {
        case .startPoint:
            return "当前步骤：确认出发地点。\(startPointSummary)\(currentStep.nextSpeechAction)\(blockingText)"
        case .appointmentTime:
            return "当前步骤：确认预约时间。\(appointmentSummary)\(currentStep.nextSpeechAction)\(blockingText)"
        case .runningNeeds:
            return "当前步骤：跑步需求，全部选填。\(optionalNeedsSpeechSummary)\(currentStep.nextSpeechAction)"
        case .review:
            return reviewSummarySpeech
        }
    }

    var auxiliaryMapAccessibilityLabel: String {
        let placeText = resolvedStartLocationDescription.nilIfBlank ?? "出发地点待确认"
        return "辅助地图，\(startPointSourceText)当前出发地点：\(placeText)"
    }

    var resolvedStartLocationDescription: String {
        guard let place = resolvedStartPlace else { return "" }
        let baseAddress = place.addressText.trimmed.isEmpty ? place.title : place.addressText.trimmed
        let supplement = startLocationDescription.trimmed
        if supplement.isEmpty {
            return baseAddress
        }
        if baseAddress.contains(supplement) {
            return baseAddress
        }
        return "\(baseAddress)；补充：\(supplement)"
    }

    var resolvedStartPlace: ResolvedPlace? {
        if let selectedStartPlace {
            return selectedStartPlace
        }
        if let currentResolvedPlace {
            return currentResolvedPlace
        }
        guard let locationService else { return nil }
        guard locationService.currentLocation != nil || allowsDemoFallbackAsStartPoint else { return nil }
        let coordinate = bookingCoordinate(from: locationService)
        return ResolvedPlace(
            id: locationService.isUsingDemoFallback ? "demo-current" : "device-current",
            title: locationService.isUsingDemoFallback ? "当前位置（演示坐标）" : "当前位置",
            addressText: locationService.isUsingDemoFallback ? "北京市（演示位置）" : "当前位置",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            source: locationService.isUsingDemoFallback ? .demoDefault : .deviceLocation
        )
    }

    func configure(
        appState: AppState,
        locationService: LocationService,
        speechService: SpeechService,
        amapGeocodingService: AMapGeocodingService
    ) {
        self.appState = appState
        self.locationService = locationService
        self.speechService = speechService
        self.placeSearchProvider = amapGeocodingService

        if appointmentTime < minimumAppointmentTime {
            appointmentTime = minimumAppointmentTime.addingTimeInterval(60)
        }
    }

    /// 演示坐标能否当作下单起点。
    ///
    /// 兜底坐标是北京一个固定点。它落到云端就是把一个可能在上海的盲人约到另一个城市；
    /// 更隐蔽的是 `resolvedStartPlace` 因为总有兜底值而**永不为 nil**，
    /// `.startPoint` 这道门槛于是恒真 —— 一道写好的门槛在生产里是死代码。
    ///
    /// 放行的只有两处，它们都不会产生真实订单：不发网络请求的 Mock 通道，
    /// 以及显式打开了演示定位的 UI 测试。正式通道一律走「请选择出发地点」。
    private var allowsDemoFallbackAsStartPoint: Bool {
        if appState?.currentEnvironment.isMock == true { return true }
        return locationService?.isDemoLocationForcedForTesting == true
    }

    private func bookingCoordinate(from locationService: LocationService) -> CLLocationCoordinate2D {
        guard let currentLocation = locationService.currentLocation else {
            // 调用方已用 `allowsDemoFallbackAsStartPoint` 过滤过，走到这里只可能是 Mock 或 UI 测试。
            return locationService.effectiveLocation
        }
        return BackendCoordinateNormalizer.normalize(
            LocatedCoordinate(coordinate: currentLocation, system: .wgs84Device)
        )?.coordinate ?? currentLocation
    }

    #if DEBUG
    func configureForTesting(
        placeSearchProvider: (any PlaceSearchProviding)? = nil,
        speechService: SpeechService,
        locationService: LocationService? = nil,
        appState: AppState? = nil
    ) {
        self.placeSearchProvider = placeSearchProvider
        self.speechService = speechService
        self.locationService = locationService
        self.appState = appState
    }
    #endif

    func refreshCurrentLocation(lockMapCenterIfNeeded: Bool = true) async {
        guard let locationService else { return }
        guard !locationService.isDenied else {
            placeMessage = "需要开启定位权限才能创建预约。"
            return
        }

        let coordinate = bookingCoordinate(from: locationService)
        let fallbackPlace = ResolvedPlace(
            id: locationService.isUsingDemoFallback ? "demo-current" : "device-current",
            title: locationService.isUsingDemoFallback ? "当前位置（演示坐标）" : "当前位置",
            addressText: locationService.isUsingDemoFallback ? "北京市（演示位置）" : "当前位置",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            source: locationService.isUsingDemoFallback ? .demoDefault : .deviceLocation
        )

        guard let placeSearchProvider, !locationService.isUsingDemoFallback else {
            currentResolvedPlace = fallbackPlace
            updateAuxiliaryMapPlaceIfNeeded(to: fallbackPlace, lockMapCenterIfNeeded: lockMapCenterIfNeeded)
            if lockMapCenterIfNeeded {
                lockInitialAuxiliaryMapCenter(to: fallbackPlace.coordinate)
            }
            placeMessage = locationService.isUsingDemoFallback ? "定位暂不可用，正在使用演示坐标。" : nil
            return
        }

        isResolvingStartLocation = true
        let resolvedPlace = await placeSearchProvider.reverseGeocode(coordinate: coordinate)
        let finalPlace = resolvedPlace ?? fallbackPlace
        currentResolvedPlace = finalPlace
        updateAuxiliaryMapPlaceIfNeeded(to: finalPlace, lockMapCenterIfNeeded: lockMapCenterIfNeeded)
        if lockMapCenterIfNeeded {
            lockInitialAuxiliaryMapCenter(to: finalPlace.coordinate)
        }
        isResolvingStartLocation = false
        placeMessage = resolvedPlace == nil ? placeSearchProvider.lastErrorMessage : nil
    }

    func refreshCurrentLocationIfNeeded() async {
        guard selectedStartPlace == nil,
              !isResolvingStartLocation else { return }
        await refreshCurrentLocation(lockMapCenterIfNeeded: false)
    }

    func searchPlaces(triggeredBySpeech: Bool = false) async {
        guard let placeSearchProvider else { return }
        let keyword = placeSearchKeyword.trimmed
        guard !keyword.isEmpty else {
            placeSearchResults = []
            placeMessage = "请输入要搜索的地点。"
            speechService?.announce(placeMessage ?? "")
            return
        }

        isSearchingPlaces = true
        placeMessage = nil
        let results = await placeSearchProvider.searchPlaces(
            keyword: keyword,
            near: resolvedStartPlace?.coordinate
        )
        placeSearchResults = results
        isSearchingPlaces = false
        if results.isEmpty {
            placeMessage = placeSearchProvider.lastErrorMessage ?? "未搜索到相关地点。"
            searchResultFocusID = nil
            speechService?.announce(placeMessage ?? "")
        } else {
            let firstPlace = results[0]
            searchResultFocusID = firstPlace.id
            speechService?.announce("已找到 \(results.count) 个地点，第一个是 \(firstPlace.title)。")
        }
    }

    func handlePlaceSearchSpeechCompletion(_ completion: SpeechInputCompletion) async {
        guard completion.field == .startPlaceSearch,
              completion.reason.shouldTriggerSearchWithRecognizedText else { return }
        let recognizedText = completion.recognizedText.trimmed
        guard !recognizedText.isEmpty else { return }
        placeSearchKeyword = recognizedText
        await searchPlaces(triggeredBySpeech: true)
    }

    /// - Parameter announce: 语音向导会自己播报后端返回的确认文案，这时把这里的播报关掉，
    ///   否则同一件事被念两遍 —— 对语速调到 14 字/秒的读屏用户，重复播报是最伤的干扰。
    func selectPlace(_ place: ResolvedPlace, announce: Bool = true) {
        selectedStartPlace = place
        auxiliaryMapPlace = place
        auxiliaryMapCenter = place.coordinate
        placeSearchKeyword = place.title
        placeSearchResults = []
        searchResultFocusID = nil
        placeMessage = "已选择出发地点：\(place.title)。"
        if announce {
            speechService?.speak("已选择出发地点，\(place.title)。")
        }
    }

    /// 语音向导解析出的起点。坐标来自 `POST /api/orders/voice/resolve-address`，**已是 GCJ-02**，
    /// 与表单路径（高德 POI）同一坐标系，直接落进同一个 `selectedStartPlace`，下游一视同仁。
    ///
    /// 与表单路径的差别值得记一笔：POI 搜索给候选列表让用户挑，语音只给一个点。重名地点的消歧
    /// 责任因此完全落在后端，前端能做的只有把地址读回去让用户确认 —— 向导正是这么做的。
    func applyVoiceResolvedStartPlace(address: String, latitude: Double, longitude: Double) {
        let place = ResolvedPlace(
            id: "voice-resolved",
            title: address,
            addressText: address,
            latitude: latitude,
            longitude: longitude,
            source: .manual
        )
        selectPlace(place, announce: false)
    }

    /// 语音说「重说」时把上一轮抽到的槽位清干净。
    ///
    /// 不清的话，新的一句里没提到的项会留着旧值，而读回照样把它念出来 ——
    /// 用户会以为那是他这次说的。对听不见屏幕的人，这种「上一轮的残留」无从察觉。
    ///
    /// **不碰 `appointmentTime`**：它没有「未设置」这个状态（初值就是 `Date()`），
    /// 「这一轮有没有真的抽到时间」由 `VoiceOrderWizard.didCaptureStartTime` 记着，
    /// 读回只在那个标志为真时才念具体时刻。
    func resetVoiceFilledSlots() {
        selectedStartPlace = nil
        // 终点尤其不能留：屏幕上没有任何终点控件，用户重说一遍之后没有任何**视觉**线索
        // 能让他发现上一轮的终点还挂着，只有读回会念出来 —— 而那时他已经在准备说「确认」了。
        endPlace = nil
        duration = .none
        exactDurationMinutes = nil
        routeNotes = ""
        specialNotes = ""
        pacePreference = .noPreference
        routePreference = .noPreference
        hasGuideDogThisRun = nil
    }

    private func updateAuxiliaryMapPlaceIfNeeded(
        to place: ResolvedPlace,
        lockMapCenterIfNeeded: Bool
    ) {
        guard selectedStartPlace == nil else { return }
        guard let currentMapPlace = auxiliaryMapPlace else {
            auxiliaryMapPlace = place
            if lockMapCenterIfNeeded {
                lockInitialAuxiliaryMapCenter(to: place.coordinate)
            }
            return
        }

        if currentMapPlace.source == .demoDefault && place.source != .demoDefault {
            auxiliaryMapPlace = place
            auxiliaryMapCenter = place.coordinate
            return
        }

        let distance = CLLocation(latitude: currentMapPlace.latitude, longitude: currentMapPlace.longitude)
            .distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude))
        if distance >= Self.auxiliaryMapMarkerRefreshDistanceMeters {
            auxiliaryMapPlace = place
        }
    }

    private func lockInitialAuxiliaryMapCenter(to coordinate: CLLocationCoordinate2D) {
        guard auxiliaryMapCenter == nil else { return }
        auxiliaryMapCenter = coordinate
    }

    func moveToNextStep() {
        guard canAdvanceFromCurrentStep else {
            let message = blockingReasonForCurrentStep ?? "请先完成当前步骤。"
            errorMessage = message
            speechService?.speakError(message)
            return
        }

        guard let currentIndex = BlindBookingGuidedStep.allCases.firstIndex(of: currentStep),
              currentIndex < BlindBookingGuidedStep.allCases.count - 1 else {
            return
        }
        errorMessage = nil
        currentStep = BlindBookingGuidedStep.allCases[currentIndex + 1]
        speechService?.speak(currentStepSpeechSummary)
    }

    func moveToPreviousStep() {
        guard let currentIndex = BlindBookingGuidedStep.allCases.firstIndex(of: currentStep),
              currentIndex > 0 else {
            return
        }
        errorMessage = nil
        currentStep = BlindBookingGuidedStep.allCases[currentIndex - 1]
        speechService?.speak(currentStepSpeechSummary)
    }

    func repeatCurrentStepStatus() {
        speechService?.speak(currentStepSpeechSummary)
    }

    /// 进页面就把第一个「本页填不了」的门槛播出来。
    ///
    /// 起点和时间是这一页自己的槽位，缺了不算进不来，向导和分步提示各自会管。
    /// 剩下四道要么得去别的页面补（资料 / 实名 / 紧急联系人），要么得去系统设置开（定位），
    /// 越早说越好：审阅步的按钮禁用状态走的是全部六道门槛，用户填完四步撞上一个灰按钮时，
    /// 看不见屏幕的人只会当成「点了没反应」。
    ///
    /// 语音路径不走这里 —— `VoiceOrderWizard.start()` 在启动前用同一套门槛自己播过一次了。
    func announceEntryGateIfNeeded() {
        guard let gate = firstMissingGate, gate != .startPoint, gate != .appointmentTime else { return }
        errorMessage = gate.message
        speechService?.speak(gate.message)
    }

    func makeCreateOrderRequest() -> CreateOrderRequest? {
        guard let startPlace = resolvedStartPlace else { return nil }
        let plannedStartTime = DateFormatter.aidRunBackendLocalDateTime.string(from: appointmentTime)
        let plannedEndTime: String
        if let minutes = resolvedDurationMinutes {
            let endDate = appointmentTime.addingTimeInterval(TimeInterval(minutes * 60))
            plannedEndTime = DateFormatter.aidRunBackendLocalDateTime.string(from: endDate)
        } else {
            let endDate = appointmentTime.addingTimeInterval(3600)
            plannedEndTime = DateFormatter.aidRunBackendLocalDateTime.string(from: endDate)
        }

        return CreateOrderRequest(
            startLatitude: startPlace.latitude,
            startLongitude: startPlace.longitude,
            startAddress: resolvedStartLocationDescription,
            // 三项一律从 `endPlace` 取。坐标成对由 `BookingEndPlace.init` 保证，
            // 这里不再判一次 —— 判两次就有两份规则，迟早有一份忘了改。
            endAddress: endPlace?.address,
            endLatitude: endPlace?.latitude,
            endLongitude: endPlace?.longitude,
            plannedStartTime: plannedStartTime,
            plannedEndTime: plannedEndTime,
            expectedDurationMinutes: resolvedDurationMinutes,
            pacePreference: pacePreference == .noPreference ? nil : pacePreference,
            routePreference: routePreference == .noPreference ? nil : routePreference,
            routeNotes: routeNotes.nilIfBlank,
            // 三态原样透传。⚠️ 不要写成 `hasGuideDogThisRun ?? false` 或
            // `hasGuideDogThisRun == true ? true : nil` —— 前者把"没提"变成"明确不带"，
            // 后者把"明确不带"变成"没提"，两个方向都会静默改掉派单候选池。
            hasGuideDogThisRun: hasGuideDogThisRun,
            specialNotes: specialNotes.nilIfBlank
        )
    }

    func submit() async -> OrderResponse? {
        guard let appState, locationService != nil else { return nil }
        // 出发地点缺失要在 makeCreateOrderRequest 之后单独报，所以这里跳过 .startPoint。
        if let gate = firstMissingGate, gate != .startPoint {
            return fail(gate.message)
        }

        isSubmitting = true
        errorMessage = nil

        guard let request = makeCreateOrderRequest() else {
            isSubmitting = false
            return fail("请选择出发地点。")
        }

        do {
            let response: OrderResponse = try await appState.apiClient.post("/api/orders", body: request)
            isSubmitting = false
            speechService?.resetLastStatus()
            speechService?.speak("订单提交成功，系统正在为你派单。")
            return response
        } catch let error as APIError {
            isSubmitting = false
            if appState.handleAuthenticatedAPIError(error) {
                return nil
            }
            errorMessage = error.localizedMessage
            speechService?.speakError(error.localizedMessage)
            return nil
        } catch {
            isSubmitting = false
            return fail("提交失败，请重试。")
        }
    }

    private func fail(_ message: String) -> OrderResponse? {
        errorMessage = message
        speechService?.speakError(message)
        return nil
    }
}

// MARK: - Blind Booking View

struct BlindBookingView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var locationService: LocationService
    @EnvironmentObject private var speechService: SpeechService
    @EnvironmentObject private var speechInputService: SpeechInputService
    @EnvironmentObject private var amapGeocodingService: AMapGeocodingService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = BlindBookingViewModel()
    @StateObject private var voiceWizard = VoiceOrderWizard()
    @AccessibilityFocusState private var focusedSearchResultID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false
    /// 零输入下单走到第二步（复核整单）了没有。见 `zeroInputBookingSection`。
    @State private var isZeroInputConfirming = false
    /// 从首页「语音下单」进来时为 `true`，页面出现即启动向导。表单入口进来则为 `false`，
    /// 语音仍可随时手动启动 —— 语音是加速器，不是另一条平行流程。
    let startsWithVoice: Bool
    let onOrderCreated: (OrderResponse) -> Void

    init(startsWithVoice: Bool = false, onOrderCreated: @escaping (OrderResponse) -> Void) {
        self.startsWithVoice = startsWithVoice
        self.onOrderCreated = onOrderCreated
    }

    var body: some View {
        // **语音态与表单态互斥，不并排。** 这一页此前把语音区和四步表单堆在同一个滚动视图里，
        // 于是「语音下单」进来看到的是十几条 StaticText 加两个文本框 —— 那不是语音下单页，
        // 是一张表单外加给每个字段配了一个麦克风按钮。用户 2026-08-08 的原话：
        // 「表单的形式不应该给盲人用」。
        //
        // 表单没有消失，它是**降级出路**（语音坏了）也是**隐私出路**（在地铁上不想说出自己在哪，
        // 见 `docs/research/blind-voice-booking-ia-20260805.md` §9.3）。它只是不再与语音同屏共存。
        Group {
            if voiceWizard.isRunning {
                voiceStage
            } else {
                ScrollView {
                    formStage
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
                        .padding(.bottom, 120)
                }
            }
        }
        .background(AppColors.background)
        // 两指双击是 iOS 上「开始/停止录音」的标准手势（Apple 把 recording 列为 Magic Tap 的典型用途）。
        // `voiceStatusBlock` 那一整块对**触摸**用户是零成本的，但对 VoiceOver 用户不是：读屏下必须先把
        // 焦点滑到那个元素才能双击激活，「不用找」这个目标恰恰对真正的目标用户没实现。Magic Tap 补的是这一半。
        //
        // 顺带堵住一个副作用：不实现时，两指双击会沿响应链穿透到系统去播放/暂停音乐 ——
        // 用户在录音中做这个手势会莫名开始放歌。
        .accessibilityAction(.magicTap) {
            if voiceWizard.isRunning {
                voiceWizard.finishSpeakingOrSkipPrompt()
            } else {
                startVoiceWizard()
            }
        }
        .safeAreaInset(edge: .bottom) {
            submitArea
        }
        .navigationTitle("创建预约")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if locationService.isNotDetermined {
                locationService.requestPermission()
            }
            locationService.startUpdating()
            viewModel.configure(
                appState: appState,
                locationService: locationService,
                speechService: speechService,
                amapGeocodingService: amapGeocodingService
            )
            Task { await viewModel.refreshCurrentLocation() }
            voiceWizard.configure(
                bookingViewModel: viewModel,
                speechService: speechService,
                speechInputService: speechInputService,
                apiClient: appState.apiClient,
                // ⚠️ **必须放宽新鲜度门，别用默认的 15 秒**（2026-08-10，N48 的客户端那一级）。
                //
                // 非陪跑模式下 `distanceFilter = 10`，站着不动 Core Location 就不推新样本；
                // 而语音下单恰恰是**站着说完一整句**，说完通常已经超过 15 秒 ——
                // 于是这个闭包返回 nil、请求不带坐标，后端只能做全国范围解析。
                // 用户报的「定位开着，在深圳说的地名却定位到海南」根因链的第一环就是这里。
                //
                // 300 秒对「50 公里半径内就近消歧」绰绰有余：真要走出这个误差，人早就不在原地了。
                // **只改这一处、不动方法默认值** —— 另外三个调用点（`ContentView`、
                // `EmergencyCoordinator`、`VolunteerOrderFlowViews`）各有各的新鲜度要求，不该被顺带改掉。
                currentCoordinate: { locationService.latestBackendSample(freshness: 300) }
            )
            if holdVoiceStageForUITestingIfRequested() {
                // 接缝已经把向导按在运行态，下面两条分支都会去碰麦克风，跳过。
            } else if startsWithVoice, !voiceWizard.isRunning {
                startVoiceWizard()
            } else {
                viewModel.announceEntryGateIfNeeded()
            }
        }
        .onDisappear {
            // 页面离开就停录音：麦克风不该在用户看不见的地方继续开着。
            voiceWizard.stop()
        }
        .onChange(of: locationService.currentLocation) { _ in
            Task { await viewModel.refreshCurrentLocationIfNeeded() }
        }
        .onChange(of: viewModel.searchResultFocusID) { focusID in
            focusedSearchResultID = focusID
        }
        // 前提消失就回到第一步。这一条堵的是「门槛中途变化」那类路径（例如用户去系统设置关掉定位
        // 再打开）：`zeroInputBookingSection` 期间被整块藏起来，再出现时不该还停在提交那一步。
        //
        // 它**盖不住**「重启语音后又失败」那条 —— 那条路上这个布尔值一直是 true（`fallBack` 换的是
        // 消息内容，不是有无），所以 `startVoiceWizard()` 里另有一次显式复位。两处缺一不可。
        .onChange(of: isZeroInputOfferAvailable) { isAvailable in
            if !isAvailable {
                isZeroInputConfirming = false
            }
        }
        .onChange(of: voiceWizard.step) { step in
            // 表单跟着向导走：语音填到哪一项，屏幕上就停在哪一项，读屏用户切回手动时不用重新找位置。
            // 只剩整句和读回两轮，两轮屏幕都停在确认页：向导念的就是这一页的内容，
            // 用户中途切回手动时看到的和刚听到的是同一件事。
            //
            // 逐项修改删掉之后，这里再也不会在用户说话的中途把屏幕换成另一张表单
            // （2026-08-06 用户报的「点了改地点之后跳转到了一个界面」）。
            // 候选消歧轮同样停在确认页：它问的是「出发地是哪一个」，而出发地就在这一页上。
            // 换页会把用户从他刚听到的内容上挪开 —— 那正是 2026-08-06 删掉逐项追问的理由。
            switch step {
            case .freeform, .disambiguateStart, .confirm: viewModel.currentStep = .review
            }
        }
        // 语音提交与按钮提交共用同一个出口，跳转逻辑只有一份。
        .onReceive(voiceWizard.$createdOrder.compactMap { $0 }) { response in
            onOrderCreated(response)
        }
    }

    // MARK: - 语音态

    /// 启动向导，并把表单同步到向导实际停留的那一页。
    ///
    /// 同步这一步**不能只靠** `.onChange(of: voiceWizard.step)`：`step` 的初值就是 `.freeform`，
    /// `start()` 里的 `step = .freeform` 是同值赋值，而 SwiftUI 的 `onChange` 只在新旧值不等时触发。
    /// 少了这里，`currentStep` 停在初值 `.startPoint`，用户按「改用表单」退出语音时屏幕落在
    /// 「确认出发地点」那一步，而向导刚念完的是整单 —— 听到的和摸到的是两回事。
    ///
    /// `start()` 返回 false 表示被前置门槛挡住（资料 / 实名 / 紧急联系人 / 定位），它自己已经播报过
    /// 原因。这时 `currentStep` 保持第 1 步是对的：用户要去补前置项，不是来复核整单的。
    private func startVoiceWizard() {
        // 复位零输入那一步。**没有这行会露出一个可以直接下单的按钮**：
        // 用户点了「不用填，直接下单」（`isZeroInputConfirming = true`）之后改点「用语音重新说一次」，
        // 这一轮语音再失败时页面切回表单态，而 `@State` 还留着上一轮的 true ——
        // `zeroInputBookingSection` 直接渲染第二步那个真提交的按钮，
        // 而用户这一轮既没点过 offer、也没听到「确认就再点一次」那句整单播报。
        // 两步确认的全部理由就是那句播报，没听到就等于一步提交。
        isZeroInputConfirming = false
        // 主动要一次新坐标 —— **这是 N48 根因的正面修法**，放宽新鲜度门只是它的兜底。
        //
        // `onAppear` 里的 `startUpdating()` 是**持续**定位，而非陪跑模式下 `distanceFilter = 10`
        // 意味着站着不动 Core Location 就不推新样本；语音下单恰恰是站着说完一整句。
        // `requestLocation()` 绕过 distanceFilter 直接要一次新 fix，而用户接下来要说 10~20 秒 ——
        // 新坐标早在解析请求发出前就到了，**零延迟代价**。
        //
        // 同一个模式 `EmergencyCoordinator.freshEmergencyCoordinate` 已经在用（`:117-131`），
        // 那边还额外轮询等 5 秒；这里不等，因为拿不到也有 300 秒兜底，而求助没有兜底可言。
        locationService.requestOneTimeLocation()
        if voiceWizard.start() {
            viewModel.currentStep = .review
        }
    }

    /// UI 测试接缝：把向导按在运行态，**不碰麦克风**。
    ///
    /// 真机跑 UI 测试拿不到语音识别授权，`start()` 一定走 `isSpeechPathUnavailable` 直接降级到表单态 ——
    /// 于是「语音态里一个表单控件都不许出现」这条本次改动的核心约束**在自动化里根本走不到**。
    /// 少了这个接缝，唯一的验证方式是人肉开 VoiceOver 手测，而那正是这类回归会漏掉的地方。
    ///
    /// 它只置 `isRunning` / `step`（`startForTesting` 的全部作用），不伪造任何解析结果、
    /// 不改播报、不触碰下单路径。
    /// - Returns: 接缝是否生效。生效时调用方不要再走正常的启动分支。
    private func holdVoiceStageForUITestingIfRequested() -> Bool {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["AIDRUN_UI_TEST_FORCE_VOICE_STAGE"] == "1" else {
            return false
        }
        voiceWizard.startForTesting(at: .freeform)
        viewModel.currentStep = .review
        return true
        #else
        return false
        #endif
    }

    /// 语音在跑时屏幕上的全部内容：一块状态区，读回轮再加一张整单。**没有表单。**
    ///
    /// 不套 `ScrollView`：状态区要真的吃满内容区（`maxHeight: .infinity`），
    /// 而滚动视图里的子视图拿不到「剩余空间」这个概念，只能给一个拍脑袋的固定高度。
    /// 语音态的内容是定长的，本来也不需要滚动。
    private var voiceStage: some View {
        VStack(spacing: 16) {
            voiceStatusBlock
            voiceOrderRecap
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 整块内容区就是那一下：**在录音是「我说完了」，在播报是「别念了，我要说」。**
    ///
    /// 依据：AppleVis 上对 iMessage 语音消息的原话抱怨是「很难干净地停下来，只能到处滑动去找一个
    /// 很小很难定位的停止按钮」。盲人定位屏幕元素靠顺序滑动或空间记忆，让他在说完话之后再去
    /// 找一个按钮，等于把最该零成本的动作做成了最贵的。整块可点就没有「找」这一步。
    ///
    /// 覆盖范围从「录音中」放宽到「向导运行中」，是为了让长读回也能被打断 —— 读回整单在写死的
    /// 默认语速下要 15~25 秒，而读屏用户日常语速是它的两三倍。
    ///
    /// **它此前是 `body` 上的一层 `.overlay`，解析途中整块撤掉。** 撤掉的理由（`isParsing` 时
    /// `finishSpeakingOrSkipPrompt` 是空操作，宣告一个按不动的动作比没有更糟）现在由「不挂手势、
    /// 不加 `.isButton`」承担；而元素本身留下，否则解析那几秒屏幕上没有任何东西说「正在识别」。
    ///
    /// **逃生口不在它之下**：「改用表单」在 `safeAreaInset` 的底栏里，那一块永远不被内容区盖住。
    ///
    /// VoiceOver 只给**一个**焦点：`label` 是现在能做什么，`value` 是系统刚念的那句话。
    /// 分成两个元素的话，用户要滑两下才能同时知道「什么状态」和「它说了什么」，
    /// 而这两件事在语音流程里从来是一起需要的。
    private var voiceStatusBlock: some View {
        VStack(spacing: 12) {
            if isRecording {
                recordingIndicator
            }

            Text(voiceStageHeadline)
                .font(AppFonts.largeTitle())
                .foregroundColor(AppColors.textPrimary)
                .multilineTextAlignment(.center)

            if let detail = voiceStageDetail {
                Text(detail)
                    .font(AppFonts.body())
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.secondaryBackground)
        .cornerRadius(16)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !voiceWizard.isParsing else { return }
            voiceWizard.finishSpeakingOrSkipPrompt()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceStageAccessibilityLabel)
        .accessibilityValue(voiceWizard.lastSpokenPrompt ?? "")
        .accessibilityHint(voiceStageAccessibilityHint)
        .accessibilityAddTraits(voiceWizard.isParsing ? [] : .isButton)
        .accessibilityIdentifier("blindBookingFinishSpeakingSurface")
    }

    private var voiceStageHeadline: String {
        if isRecording { return "正在录音" }
        if voiceWizard.isParsing { return "正在识别" }
        return "请听提示后说话"
    }

    /// 小字那一行。录音中优先显示实时识别文本 —— 它只写屏、不进无障碍树：
    /// 一边说一边念会盖住用户自己的声音，识别也会跟着跑偏（调研 2026-08-03）。
    private var voiceStageDetail: String? {
        if !voiceWizard.partialTranscript.isEmpty {
            return "听到：\(voiceWizard.partialTranscript)"
        }
        return voiceWizard.lastSpokenPrompt
    }

    private var voiceStageAccessibilityLabel: String {
        if voiceWizard.isParsing { return "正在识别，请稍候" }
        return isRecording ? "正在录音，说完后双击结束" : "双击跳过播报，直接开始说话"
    }

    private var voiceStageAccessibilityHint: String {
        if voiceWizard.isParsing { return "" }
        return isRecording ? "也可以停顿几秒自动结束" : "也可以听完播报，麦克风会自动打开"
    }

    /// 读回轮把整单摆在屏幕上。**服务的是低视力用户和陪同的明眼人** —— 全盲用户靠读回听，
    /// 屏幕上这份是给看得见的人核对用的。
    ///
    /// 一行「一个名字 + 一个值」，不写「出发地点：」这种前缀：读屏合并后念出来长度翻倍，
    /// 而一张陪跑订单里出现的时间就是预约时间（`docs/research/blind-ui-visual-benchmark-20260808.md` §1 规则 4）。
    ///
    /// 时间只在**真的抽到**时才显示具体时刻。`appointmentTime` 的初值是 `Date()`，
    /// 无条件显示等于把一个用户从没说过的时刻摆成既成事实 —— 这是 2026-08-06 在读回文案上修过的
    /// 同一条红线（用户原话：「他也没有经过我的同意」），屏幕这一份不能把它退回去。
    @ViewBuilder
    private var voiceOrderRecap: some View {
        if voiceWizard.step == .confirm {
            VStack(spacing: 8) {
                recapRow("出发", viewModel.resolvedStartLocationDescription.nilIfBlank ?? "当前位置")
                // 紧跟「出发」，与读回同一个顺序 —— 起终点抽反了要能一眼/一耳看出来。
                // 没说终点就整行不渲染：nil 是「未指定」，摆一行「结束：无」是在回答用户没问的问题。
                if let endPlace = viewModel.endPlace {
                    recapRow("结束", endPlace.isUnresolved ? "\(endPlace.address)（未定位到）" : endPlace.address)
                }
                recapRow(
                    "时间",
                    voiceWizard.didCaptureStartTime
                        ? DateFormatter.aidRunDisplayDateTime.string(from: viewModel.appointmentTime)
                        : "还没说"
                )
                if let durationText = viewModel.resolvedDurationText {
                    recapRow("时长", durationText)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(AppColors.secondaryBackground)
            .cornerRadius(16)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("blindBookingVoiceOrderRecap")
        }
    }

    private func recapRow(_ name: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(name)
                .font(AppFonts.body())
                .foregroundColor(AppColors.textSecondary)
            Spacer(minLength: 12)
            Text(value)
                .font(AppFonts.body().weight(.semibold))
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - 表单态

    /// 语音停了之后的屏幕。顺序即「从最省到最费」：出了什么事 → 不用填就能下的单 →
    /// 再试一次语音 → 自己填。
    private var formStage: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let fallbackMessage = voiceWizard.fallbackMessage {
                Text(fallbackMessage)
                    .font(AppFonts.body())
                    .foregroundColor(AppColors.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(fallbackMessage)
            }

            zeroInputBookingSection

            Button("用语音重新说一次") {
                startVoiceWizard()
            }
            .font(AppFonts.primaryButton())
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 64)
            .background(AppColors.primary)
            .cornerRadius(12)
            .accessibilityLabel("用语音重新说一次")
            .accessibilityHint("重新开始语音下单")
            .accessibilityIdentifier("blindBookingVoiceOrderButton")

            header
            guidedStepHeader
            currentStepContent

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(AppFonts.body())
                    .foregroundColor(AppColors.destructive)
                    .accessibilityLabel(errorMessage)
                    .accessibilityHint("错误提示")
            }
        }
    }

    /// 零输入下单：不填任何东西，用当前位置和最早可约时间成单。
    ///
    /// 只在**语音自己放弃之后**出现（`fallbackMessage != nil`）。用户主动按「改用表单」时
    /// `fallbackMessage` 是 nil，那是他明说要自己填，不该再塞一个大按钮进去。
    ///
    /// 依据：IA 调研 §6.6 —— 国内产品对「识别不可用」的主流答案不是重试识别，而是**绕过输入**
    /// （滴滴关怀版预存常用地址、一键叫车不输起终点）。我们没有常用地址，能给的等价物就是
    /// 当前位置 + 最早可约时间。注意**没有「现在就跑」**：30 分钟提前量是后端硬约束。
    ///
    /// `firstMissingGate == nil` 这一个条件已经把演示坐标挡住了 —— 正式通道里
    /// `resolvedStartPlace` 拿不到真实定位就是 nil（`allowsDemoFallbackAsStartPoint` 只对
    /// Mock 与 UI 测试放行），`.startPoint` 那道门槛因此为真。不需要在这里再判一次坐标。
    /// 这条路径现在能不能给。**第二步的状态不许活得比它久** —— 见 `startVoiceWizard()` 与
    /// `body` 里对它的 `onChange`：前提消失就必须回到第一步，否则用户会看到一个没听过整单播报的
    /// 提交按钮，而两步确认的全部理由就是那句播报。
    private var isZeroInputOfferAvailable: Bool {
        voiceWizard.fallbackMessage != nil && viewModel.firstMissingGate == nil
    }

    @ViewBuilder
    private var zeroInputBookingSection: some View {
        if isZeroInputOfferAvailable {
            VStack(spacing: 10) {
                if isZeroInputConfirming {
                    // 第二步的按钮标题**就是整单**。表单路径靠 `reviewSection` 把整单摆在屏幕上
                    // 满足 WCAG 3.3.4 的「可复核确认」，这条路径没有那一屏，复核内容只能由
                    // 按钮自己承担 —— 读屏念按钮时念到的就是要下的单。
                    PrimaryButton(viewModel.zeroInputSummary, isLoading: viewModel.isSubmitting) {
                        Task {
                            if let response = await viewModel.submit() {
                                onOrderCreated(response)
                            }
                        }
                    }
                    .accessibilityLabel(viewModel.zeroInputSummary)
                    .accessibilityHint("点击后立即创建预约并开始派单")
                    .accessibilityIdentifier("blindBookingZeroInputConfirmButton")

                    // 误按第一步的出口。第二步是个占满宽度的大按钮，读屏用户滑过去就可能激活，
                    // 而它的后果是一张真实订单加一次真实派单。
                    Button("不用了，我自己填") {
                        isZeroInputConfirming = false
                        speechService.speak("已取消，你可以继续用下面的表单填写。")
                    }
                    .font(AppFonts.body().weight(.semibold))
                    .foregroundColor(AppColors.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 64)
                    .background(AppColors.secondaryBackground)
                    .cornerRadius(12)
                    .accessibilityLabel("不用了，我自己填")
                    .accessibilityHint("放弃直接下单，回到表单")
                } else {
                    PrimaryButton("不用填，直接下单") {
                        isZeroInputConfirming = true
                        speechService.speak("\(viewModel.zeroInputSummary)。确认就再点一次。")
                    }
                    .accessibilityLabel("不用填，直接下单")
                    .accessibilityHint("用当前位置和最早可约时间创建预约，点击后会先念一遍要下的单")
                    .accessibilityIdentifier("blindBookingZeroInputOfferButton")
                }
            }
        }
    }

    private var isRecording: Bool {
        voiceWizard.isRunning && speechInputService.isListening
    }

    /// 录音中的可见状态。动画只服务低视力用户与陪同的明眼人 —— 全盲用户靠的是起止提示音和震动
    /// （`RecordingCue`），所以这里的信息**不能**只存在于动画里，静态文字必须自带完整语义。
    ///
    /// 脉冲周期 1.2 秒（约 0.83 次/秒），远低于 WCAG 2.3.1 的每秒 3 次红线；
    /// 系统开启「减弱动态效果」时退化为静态圆点。
    private var recordingIndicator: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(AppColors.destructive)
                .frame(width: 20, height: 20)
                .opacity(reduceMotion ? 1 : (isPulsing ? 1 : 0.35))
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                    value: isPulsing
                )
                .accessibilityHidden(true)

            Text("正在录音")
                .font(AppFonts.primaryButton())
                .foregroundColor(AppColors.destructive)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { isPulsing = true }
        .onDisappear { isPulsing = false }
        .accessibilityHidden(true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HighContrastText("创建预约", style: .title)
                .accessibilityAddTraits(.isHeader)
            Text("按步骤确认出发地点、预约时间和选填需求，最后再提交。")
                .font(AppFonts.body())
                .foregroundColor(AppColors.textSecondary)
                .accessibilityLabel("按步骤确认出发地点、预约时间和选填需求，最后再提交")
        }
    }

    private var guidedStepHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 语音路径不走这四步，进度条对它是假的。
            //
            // 向导实际是「整句 → 读回」两轮，而 `.freeform` 和 `.confirm` 都映射到 `.review`，
            // 所以用户刚说第一句话，进度条就已经显示「第 4 步 / 共 4 步」。这句还进了下面那个
            // `accessibilityLabel`，VoiceOver 会把这个错的数字念出来。语音在跑就不画它。
            if !voiceWizard.isRunning {
                Text(viewModel.stepProgressText)
                    .font(AppFonts.caption())
                    .foregroundColor(AppColors.textSecondary)
                    .accessibilityLabel(viewModel.stepProgressText)

                HStack(spacing: 8) {
                    ForEach(BlindBookingGuidedStep.allCases) { step in
                        VStack(spacing: 6) {
                            Circle()
                                .fill(step.rawValue <= viewModel.currentStep.rawValue ? AppColors.primary : AppColors.textSecondary.opacity(0.25))
                                .frame(width: 12, height: 12)
                                .accessibilityHidden(true)
                            Text(step.shortName)
                                .font(AppFonts.caption())
                                .foregroundColor(step == viewModel.currentStep ? AppColors.textPrimary : AppColors.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(viewModel.stepProgressText)，当前步骤：\(viewModel.currentStep.displayName)")
            }

            Text(viewModel.currentStep.displayName)
                .font(.title2.bold())
                .foregroundColor(AppColors.textPrimary)
                .accessibilityAddTraits(.isHeader)

            Text(viewModel.currentStepSpeechSummary)
                .font(AppFonts.body())
                .foregroundColor(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(viewModel.currentStepSpeechSummary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.secondaryBackground)
        .cornerRadius(8)
    }

    @ViewBuilder
    private var currentStepContent: some View {
        switch viewModel.currentStep {
        case .startPoint:
            locationSection
        case .appointmentTime:
            appointmentSection
        case .runningNeeds:
            optionalSection
        case .review:
            reviewSection
        }
    }

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("出发地点")

            if locationService.isDenied {
                permissionDeniedView
            } else {
                currentLocationCard

                VoiceTextField(
                    title: "搜索出发地点",
                    placeholder: "例如：科技园地铁站 A 口",
                    text: $viewModel.placeSearchKeyword,
                    speechInputService: speechInputService,
                    speechService: speechService,
                    speechField: .startPlaceSearch,
                    accessibilityLabel: "搜索出发地点",
                    accessibilityHint: "可以使用语音或键盘搜索高德地点",
                    onRecognitionCompleted: { completion in
                        Task {
                            await viewModel.handlePlaceSearchSpeechCompletion(completion)
                        }
                    }
                )

                Button {
                    Task { await viewModel.searchPlaces() }
                } label: {
                    HStack {
                        if viewModel.isSearchingPlaces {
                            ProgressView()
                        }
                        Text(searchButtonTitle)
                    }
                    .font(AppFonts.body().weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRecognizingStartPlace || viewModel.isSearchingPlaces || viewModel.placeSearchKeyword.trimmed.isEmpty)
                .accessibilityLabel(searchButtonTitle)
                .accessibilityHint(isRecognizingStartPlace ? "请说出地点名称，识别结束后会自动搜索" : "搜索高德地点并显示可选择的出发地点列表")

                placeSearchResultsView

                VoiceTextField(
                    title: "出发地点补充描述",
                    placeholder: "例如：我在 A 口外侧等候",
                    text: $viewModel.startLocationDescription,
                    speechInputService: speechInputService,
                    speechService: speechService,
                    speechField: .startLocationDescription,
                    accessibilityLabel: "出发地点补充描述",
                    accessibilityHint: "可以使用语音或键盘补充出发地点说明，不能替代坐标"
                )

                if let placeMessage = viewModel.placeMessage {
                    Text(placeMessage)
                        .font(AppFonts.caption())
                        .foregroundColor(AppColors.textSecondary)
                        .accessibilityLabel(placeMessage)
                }

                auxiliaryStartMap
            }
        }
    }

    private var currentLocationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(viewModel.selectedStartPlace == nil ? "默认出发点" : "已选择出发点")
                    .font(.headline)
                    .foregroundColor(AppColors.textPrimary)

                Text(viewModel.resolvedStartLocationDescription.isEmpty ? "正在获取当前位置" : viewModel.resolvedStartLocationDescription)
                    .font(AppFonts.body())
                    .foregroundColor(AppColors.textPrimary)
                    .accessibilityLabel("出发地点，\(viewModel.resolvedStartLocationDescription)")
                    .accessibilityHint("提交预约时会使用这个地点")

                if viewModel.isResolvingStartLocation {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在使用高德解析当前位置")
                    }
                    .font(AppFonts.caption())
                    .foregroundColor(AppColors.textSecondary)
                    .accessibilityLabel("正在使用高德解析当前位置")
                } else {
                    Text(locationService.isUsingDemoFallback ? "使用演示坐标，适合模拟器测试。" : "已使用设备当前位置和高德地址作为出发点。")
                        .font(AppFonts.caption())
                        .foregroundColor(AppColors.textSecondary)
                        .accessibilityLabel(locationService.isUsingDemoFallback ? "使用演示坐标，适合模拟器测试" : "已使用设备当前位置和高德地址作为出发点")
                }
            }
        }
        .padding()
        .background(AppColors.secondaryBackground)
        .cornerRadius(8)
    }

    private var auxiliaryStartMap: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("辅助地图")
                .font(.headline)
                .foregroundColor(AppColors.textPrimary)
                .accessibilityAddTraits(.isHeader)

            MapViewWrapper(
                centerCoordinate: viewModel.auxiliaryMapCenter ?? viewModel.auxiliaryMapPlace?.coordinate ?? viewModel.resolvedStartPlace?.coordinate ?? locationService.effectiveBackendLocation,
                showsUserLocation: true,
                annotations: (viewModel.auxiliaryMapPlace ?? viewModel.resolvedStartPlace).map {
                    [
                        MapAnnotationItem(
                            id: "start-location",
                            coordinate: $0.coordinate,
                            title: $0.title,
                            subtitle: $0.addressText
                        )
                    ]
                } ?? [],
                zoomLevel: 16,
                tracksUserLocation: false,
                animatesCenterChanges: false
            )
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(viewModel.auxiliaryMapAccessibilityLabel)
            .accessibilityHint("地图仅用于视觉确认，出发地点文字和语音摘要在上方")
            .accessibilityIdentifier("blindBookingAuxiliaryMap")
        }
    }

    @ViewBuilder
    private var placeSearchResultsView: some View {
        if !viewModel.placeSearchResults.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("搜索结果")
                    .font(.headline)
                    .foregroundColor(AppColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                ForEach(viewModel.placeSearchResults) { place in
                    Button {
                        viewModel.selectPlace(place)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(place.title)
                                .font(AppFonts.body().weight(.semibold))
                                .foregroundColor(AppColors.textPrimary)
                            Text(place.addressText)
                                .font(AppFonts.caption())
                                .foregroundColor(AppColors.textSecondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(AppColors.secondaryBackground)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityFocused($focusedSearchResultID, equals: place.id)
                    .accessibilityLabel(place.bookingSearchAccessibilityLabel)
                    .accessibilityHint("点击后使用该地点坐标创建预约")
                }
            }
        }
    }

    private var isRecognizingStartPlace: Bool {
        speechInputService.isListening(for: .startPlaceSearch)
    }

    private var searchButtonTitle: String {
        if isRecognizingStartPlace {
            return "语音识别中"
        }
        if viewModel.isSearchingPlaces {
            return "正在搜索"
        }
        return "搜索地点"
    }

    private var permissionDeniedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("需要开启定位权限才能创建预约。")
                .font(AppFonts.body())
                .foregroundColor(AppColors.warning)
                .accessibilityLabel("需要开启定位权限才能创建预约")

            Button("去设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("去设置")
            .accessibilityHint("打开系统设置以开启定位权限")
        }
        .padding()
        .background(AppColors.secondaryBackground)
        .cornerRadius(8)
        .onAppear {
            speechService.speakError("定位权限未开启。请前往系统设置开启定位，以便创建跑步预约。")
        }
    }

    private var appointmentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("预约时间")
            DatePicker(
                "预约时间",
                selection: $viewModel.appointmentTime,
                in: viewModel.minimumAppointmentTime...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)
            .font(AppFonts.body())
            .foregroundColor(AppColors.textPrimary)
            .accessibilityLabel("预约时间，\(viewModel.appointmentTime.formatted(date: .abbreviated, time: .shortened))")
            .accessibilityHint("请选择至少三十分钟后的时间")

            Text("预约时间需至少在 30 分钟后。")
                .font(AppFonts.caption())
                .foregroundColor(viewModel.isAppointmentTimeValid ? AppColors.textSecondary : AppColors.destructive)
                .accessibilityLabel("预约时间需至少在三十分钟后")
        }
        .padding()
        .background(AppColors.secondaryBackground)
        .cornerRadius(8)
    }

    private var optionalSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("更多选项（选填）")

            VoiceTextField(
                title: "路线备注",
                placeholder: "例如：沿公园慢跑一圈",
                text: $viewModel.routeNotes,
                speechInputService: speechInputService,
                speechService: speechService,
                speechField: .destinationRoute,
                accessibilityLabel: "路线备注，选填",
                accessibilityHint: "可以使用语音或键盘输入路线说明"
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("预计时长")
                    .font(.headline)
                    .foregroundColor(AppColors.textPrimary)
                Picker("预计时长", selection: $viewModel.duration) {
                    ForEach(BookingDurationOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("预计时长，选填")
                .accessibilityHint("点击选择预计跑步时长")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("配速偏好")
                    .font(.headline)
                    .foregroundColor(AppColors.textPrimary)
                Picker("配速偏好", selection: $viewModel.pacePreference) {
                    ForEach(PacePreference.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("配速偏好，选填")
                .accessibilityHint("选择走跑结合、轻松、中等或快速")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("路线偏好")
                    .font(.headline)
                    .foregroundColor(AppColors.textPrimary)
                Picker("路线偏好", selection: $viewModel.routePreference) {
                    ForEach(RoutePreference.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("路线偏好，选填")
                .accessibilityHint("选择公园步道、街道或跑道")
            }

            // 开关只能表达 `nil`/`true`：关掉等于「没提」，不是「明确不带」——
            // 屏幕上一个关着的开关本来就分不出这两者，硬把它读成"明确不带"是替用户表态。
            // `false` 只由语音产生（「今天不带导盲犬」）。
            Toggle("本次携带导盲犬", isOn: Binding(
                get: { viewModel.hasGuideDogThisRun == true },
                set: { viewModel.hasGuideDogThisRun = $0 ? true : nil }
            ))
                .font(AppFonts.body())
                .foregroundColor(AppColors.textPrimary)
                .accessibilityLabel("是否本次携带导盲犬，选填")
                .accessibilityHint("开启后记录本次跑步携带导盲犬")

            VoiceTextField(
                title: "特殊说明",
                placeholder: "例如：我会带导盲杖",
                text: $viewModel.specialNotes,
                isMultiline: true,
                speechInputService: speechInputService,
                speechService: speechService,
                speechField: .remark,
                accessibilityLabel: "特殊说明，选填",
                accessibilityHint: "可以使用语音或键盘输入特殊说明"
            )
        }
    }

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("确认预约")

            reviewRow(title: "出发地点", value: viewModel.resolvedStartLocationDescription.nilIfBlank ?? "出发地点待确认")
            // 语音降级回表单时终点会跟着留下来，所以复核页也得能看到它。
            if let endPlace = viewModel.endPlace {
                reviewRow(
                    title: "结束地点",
                    value: endPlace.isUnresolved ? "\(endPlace.address)（未定位到）" : endPlace.address
                )
            }
            reviewRow(title: "预约时间", value: DateFormatter.aidRunDisplayDateTime.string(from: viewModel.appointmentTime))

            if viewModel.optionalReviewItems.isEmpty {
                Text("未填写选填跑步需求。")
                    .font(AppFonts.body())
                    .foregroundColor(AppColors.textSecondary)
                    .accessibilityLabel("未填写选填跑步需求")
            } else {
                ForEach(viewModel.optionalReviewItems) { item in
                    reviewRow(title: item.title, value: item.value)
                }
            }

            if let blockingReason = viewModel.blockingReasonForCurrentStep {
                Text(blockingReason)
                    .font(AppFonts.body())
                    .foregroundColor(AppColors.destructive)
                    .accessibilityLabel(blockingReason)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.secondaryBackground)
        .cornerRadius(8)
    }

    private func reviewRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(AppFonts.caption())
                .foregroundColor(AppColors.textSecondary)
            Text(value)
                .font(AppFonts.body())
                .foregroundColor(AppColors.textPrimary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)：\(value)")
    }

    private var submitArea: some View {
        // 语音在跑的时候，「上一步 / 下一步」是不连贯的：表单的步骤正被向导驱动，用户按它等于和语音抢方向盘。
        // 换成语音自己的两个控件，同时解决另一件事 —— 底栏在 `safeAreaInset` 里，整屏点击区盖不到它，
        // 所以「改用表单」这个逃生口在录音和播报期间都点得到。位置固定不随内容滚动，也更利于空间记忆。
        Group {
            if voiceWizard.isRunning {
                voiceControls
            } else {
                formControls
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    /// 竖排，不并排。两个理由：视觉上并排等于把每个按钮的宽度砍半
    /// （`docs/research/blind-ui-visual-benchmark-20260808.md` §1 规则 3，对标产品的次级操作一律整行铺满）；
    /// 读屏上横排两个元素的遍历顺序取决于框架布局而非视觉直觉，是本项目 UI 测试假失败的常见来源。
    private var voiceControls: some View {
        VStack(spacing: 10) {
            Button("重复一遍") {
                voiceWizard.repeatCurrentPrompt()
            }
            .font(AppFonts.body().weight(.semibold))
            .foregroundColor(AppColors.primary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 64)
            .accessibilityLabel("重复一遍")
            .accessibilityHint("再念一次刚才的提示")

            Button("改用表单") {
                voiceWizard.stop()
                speechService.speak("已停止语音下单，你可以继续用表单填写。")
            }
            .font(AppFonts.body().weight(.semibold))
            .foregroundColor(AppColors.destructive)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 64)
            .accessibilityLabel("改用表单")
            .accessibilityHint("停止语音，用屏幕上的输入框继续填写")
            .accessibilityIdentifier("blindBookingStopVoiceButton")
        }
    }

    private var formControls: some View {
        VStack(spacing: 10) {
            if let blockingReason = viewModel.blockingReasonForCurrentStep {
                Text(blockingReason)
                    .font(AppFonts.caption())
                    .foregroundColor(AppColors.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(blockingReason)
            }

            HStack(spacing: 12) {
                if !viewModel.isFirstStep {
                    Button("上一步") {
                        viewModel.moveToPreviousStep()
                    }
                    .font(AppFonts.body().weight(.semibold))
                    .foregroundColor(AppColors.textPrimary)
                    .frame(minWidth: 96)
                    .frame(minHeight: 64)
                    .background(AppColors.secondaryBackground)
                    .cornerRadius(12)
                    .accessibilityLabel("上一步")
                    .accessibilityHint("返回上一个预约步骤")
                }

                PrimaryButton(viewModel.currentStep.nextActionTitle, isLoading: viewModel.isSubmitting) {
                    if viewModel.isReviewStep {
                        Task {
                            if let response = await viewModel.submit() {
                                onOrderCreated(response)
                            }
                        }
                    } else {
                        viewModel.moveToNextStep()
                    }
                }
                .disabled(primaryActionDisabled)
                .opacity(primaryActionDisabled ? 0.45 : 1)
                .accessibilityLabel(viewModel.currentStep.nextActionTitle)
                .accessibilityHint(primaryActionHint)
            }

            PrimaryButton("重复当前状态") {
                viewModel.repeatCurrentStepStatus()
            }
            .accessibilityLabel("重复当前状态")
            .accessibilityHint("点击后重新播报当前预约步骤状态")
        }
    }

    private var primaryActionDisabled: Bool {
        viewModel.isReviewStep ? !viewModel.canSubmit : !viewModel.canAdvanceFromCurrentStep
    }

    private var primaryActionHint: String {
        if let blockingReason = viewModel.blockingReasonForCurrentStep {
            return blockingReason
        }
        return viewModel.isReviewStep ? "提交后系统将为你派单" : "进入下一步"
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.title3.bold())
            .foregroundColor(AppColors.textPrimary)
            .accessibilityAddTraits(.isHeader)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        BlindBookingView { _ in }
            .environmentObject(AppState())
            .environmentObject(LocationService())
            .environmentObject(SpeechService())
            .environmentObject(SpeechInputService())
            .environmentObject(AMapGeocodingService())
    }
}
#endif
