import Combine
import CoreLocation
import SwiftUI

// MARK: - Volunteer Shared Models

struct VolunteerServiceRecord: Identifiable {
    let order: OrderDetailResponse

    var id: Int64 { order.orderId }
    var pointsText: String { order.status == .completed ? "+100 积分" : "—" }
    var sortKey: String { order.createdAt ?? order.plannedStart ?? "" }

    var accessibilityLabel: String {
        "时间：\(sortKey.displayDateTime)，盲人：\(order.blindName ?? "")，地点：\(order.startAddress ?? "")，状态：\(order.status.displayName)，积分：\(pointsText)"
    }
}

private enum VolunteerSheet: Identifiable {
    case completion
    case navigation(ExternalMapNavigationRequest)

    var id: String {
        switch self {
        case .completion:
            return "completion"
        case .navigation(let request):
            return "navigation-\(request.id.uuidString)"
        }
    }
}

// MARK: - Shared Guards and Helpers

extension VolunteerOrderActionGuard {
    static func acceptBlockMessage(
        profile: VolunteerProfileResponse?,
        registrationStatus: VolunteerRegistrationStatus? = nil,
        locationAuthorized: Bool
    ) -> String? {
        if let message = acceptBlockMessage(profile: profile, registrationStatus: registrationStatus) {
            return message
        }
        guard locationAuthorized else {
            return "需要开启定位权限才能接单"
        }
        return nil
    }
}

extension RunOrderStatus {
    var volunteerDescription: String {
        switch self {
        case .pendingMatch:
            return "可接订单"
        case .pendingAccept:
            return "已接单，请前往约定地点"
        case .inProgress:
            return "服务进行中"
        case .driverEnRoute:
            return "正在前往约定地点"
        case .driverArrived:
            return "已到达，可开始服务"
        case .completed:
            return "服务完成，获得 +100 积分"
        case .cancelled:
            return "订单已取消"
        case .rematching:
            return "订单正在重新匹配"
        case .noVolunteer:
            return "暂无志愿者"
        case .unknown:
            return "订单状态有更新，请刷新页面"
        }
    }

    var serviceStageTitle: String {
        switch self {
        case .pendingAccept, .driverEnRoute:
            return "前往出发地点"
        case .driverArrived:
            return "已到达集合地点"
        case .inProgress:
            return "服务进行中"
        case .completed:
            return "行程结算"
        case .cancelled:
            return "订单已取消"
        case .rematching, .noVolunteer:
            return "订单异常"
        case .pendingMatch:
            return "等待接单"
        case .unknown:
            return "订单状态未知"
        }
    }

    var volunteerServiceDisplayName: String {
        switch self {
        case .pendingAccept:
            return "待出发"
        default:
            return displayName
        }
    }

    var serviceStageSubtitle: String {
        switch self {
        case .pendingAccept:
            return "请确认当前位置和出发地点，可使用外部地图步行导航"
        case .driverEnRoute:
            return "请按导航前往出发地点，盲人跑者正在等待"
        case .driverArrived:
            return "已到达集合地点，请点击开始服务，服务开始前不能结束订单"
        case .inProgress:
            return "完成本次陪跑后可结束服务"
        case .completed:
            return "感谢您的爱心陪伴"
        case .cancelled:
            return "本次服务已取消"
        case .rematching, .noVolunteer:
            return "本次服务已结束"
        case .pendingMatch:
            return "订单尚未进入服务流程"
        case .unknown:
            return "当前状态无法识别，请刷新后再操作"
        }
    }
}

private func orderCoordinate(_ order: OrderDetailResponse) -> CLLocationCoordinate2D? {
    guard let lat = order.startLatitude, let lng = order.startLongitude else { return nil }
    return CLLocationCoordinate2D(latitude: lat, longitude: lng)
}

struct VolunteerServiceMapPresentation {
    let centerCoordinate: CLLocationCoordinate2D
    let annotations: [MapAnnotationItem]
    let isCurrentLocationAvailable: Bool
    let hasCurrentLocationMarker: Bool

    init(
        order: OrderDetailResponse,
        currentLocation: CLLocationCoordinate2D?,
        locationAuthorized: Bool,
        fallbackCoordinate: CLLocationCoordinate2D,
        includesCurrentLocationMarker: Bool = false,
        centersOnCurrentAndStart: Bool = false
    ) {
        self.init(
            id: "order-start-\(order.orderId)",
            startCoordinate: orderCoordinate(order),
            startAddress: order.startAddress,
            currentLocation: currentLocation,
            locationAuthorized: locationAuthorized,
            fallbackCoordinate: fallbackCoordinate,
            includesCurrentLocationMarker: includesCurrentLocationMarker,
            centersOnCurrentAndStart: centersOnCurrentAndStart
        )
    }

    init(
        dispatchOrder: WSNewOrder,
        currentLocation: CLLocationCoordinate2D?,
        locationAuthorized: Bool,
        fallbackCoordinate: CLLocationCoordinate2D
    ) {
        let startCoordinate: CLLocationCoordinate2D?
        if let lat = dispatchOrder.startLatitude, let lng = dispatchOrder.startLongitude {
            startCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        } else {
            startCoordinate = nil
        }
        self.init(
            id: "dispatch-start-\(dispatchOrder.orderId)",
            startCoordinate: startCoordinate,
            startAddress: dispatchOrder.startAddress,
            currentLocation: currentLocation,
            locationAuthorized: locationAuthorized,
            fallbackCoordinate: fallbackCoordinate,
            includesCurrentLocationMarker: false,
            centersOnCurrentAndStart: false
        )
    }

    private init(
        id: String,
        startCoordinate: CLLocationCoordinate2D?,
        startAddress: String?,
        currentLocation: CLLocationCoordinate2D?,
        locationAuthorized: Bool,
        fallbackCoordinate: CLLocationCoordinate2D,
        includesCurrentLocationMarker: Bool,
        centersOnCurrentAndStart: Bool
    ) {
        let displayCurrentLocation = locationAuthorized ? currentLocation.flatMap {
            BackendCoordinateNormalizer.normalize(
                LocatedCoordinate(coordinate: $0, system: .wgs84Device)
            )?.coordinate
        } : nil

        var items: [MapAnnotationItem] = []
        if includesCurrentLocationMarker, let displayCurrentLocation {
            items.append(
                MapAnnotationItem(
                    id: "current-location",
                    coordinate: displayCurrentLocation,
                    title: "我的位置",
                    subtitle: nil,
                    kind: .currentLocation
                )
            )
        }

        if let startCoordinate {
            items.append(
                MapAnnotationItem(
                    id: id,
                    coordinate: startCoordinate,
                    title: "出发地点",
                    subtitle: startAddress,
                    kind: .orderStart
                )
            )
        }

        annotations = items
        isCurrentLocationAvailable = displayCurrentLocation != nil
        hasCurrentLocationMarker = includesCurrentLocationMarker && displayCurrentLocation != nil

        if centersOnCurrentAndStart, let displayCurrentLocation, let startCoordinate {
            centerCoordinate = CLLocationCoordinate2D(
                latitude: (displayCurrentLocation.latitude + startCoordinate.latitude) / 2,
                longitude: (displayCurrentLocation.longitude + startCoordinate.longitude) / 2
            )
        } else if let startCoordinate {
            centerCoordinate = startCoordinate
        } else if let displayCurrentLocation {
            centerCoordinate = displayCurrentLocation
        } else {
            centerCoordinate = fallbackCoordinate
        }
    }
}

struct VolunteerServiceMapLayout {
    static func screenAnchorY(
        viewportHeight: CGFloat,
        topSafeAreaInset: CGFloat,
        bottomPanelMaxHeight: CGFloat
    ) -> CGFloat {
        guard viewportHeight > 1 else { return 0.5 }
        let upper = max(topSafeAreaInset, 0)
        let lower = max(viewportHeight - bottomPanelMaxHeight, upper + 1)
        let visibleCenterY = (upper + lower) / 2
        return min(max(visibleCenterY / viewportHeight, 0.18), 0.45)
    }
}

private func externalNavigationRequest(
    for order: OrderDetailResponse,
    currentLocation: CLLocationCoordinate2D?,
    locationAuthorized: Bool
) -> ExternalMapNavigationRequest? {
    guard let destination = orderCoordinate(order) else { return nil }
    return ExternalMapNavigationRequest(
        originCoordinate: locationAuthorized ? currentLocation : nil,
        originName: "我的位置",
        destinationCoordinate: destination,
        destinationName: (order.startAddress?.nilIfBlank ?? "出发地点")
    )
}

// MARK: - Order Detail

private enum VolunteerOrderActionError: Error {
    case timedOut
}

enum VolunteerOrderTransitionState: Equatable {
    case idle
    case submitting(target: RunOrderStatus)
    case awaitingConfirmation(target: RunOrderStatus)
    case confirmationDelayed(target: RunOrderStatus)
    case failed(message: String)

    var targetStatus: RunOrderStatus? {
        switch self {
        case .submitting(let target),
             .awaitingConfirmation(let target),
             .confirmationDelayed(let target):
            return target
        case .idle, .failed:
            return nil
        }
    }

    var blocksDuplicateSubmission: Bool {
        switch self {
        case .submitting, .awaitingConfirmation, .confirmationDelayed:
            return true
        case .idle, .failed:
            return false
        }
    }

    var message: String? {
        switch self {
        case .idle, .submitting, .failed:
            return nil
        case .awaitingConfirmation:
            return "操作已提交，状态待确认。页面其他功能仍可使用。"
        case .confirmationDelayed:
            return "状态确认延迟，请稍后点击“重新确认状态”。请勿重复提交同一操作。"
        }
    }
}

private extension RunOrderStatus {
    func satisfiesVolunteerTransition(target: RunOrderStatus) -> Bool {
        if self == target { return true }
        switch target {
        case .pendingAccept:
            return [.driverEnRoute, .driverArrived, .inProgress, .completed].contains(self)
        case .driverEnRoute:
            return [.driverArrived, .inProgress, .completed].contains(self)
        case .driverArrived:
            return [.inProgress, .completed].contains(self)
        case .inProgress:
            return self == .completed
        case .rematching:
            return [.cancelled, .noVolunteer].contains(self)
        case .completed:
            return false
        case .pendingMatch, .cancelled, .noVolunteer:
            return false
        // `.unknown` 只可能来自解码兜底，永远不会是志愿者操作的目标状态。
        case .unknown:
            return false
        }
    }
}

private func withVolunteerOrderActionDeadline<T: Sendable>(
    nanoseconds: UInt64,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    do {
        return try await HomeLoadCoordinator.run(
            timeout: TimeInterval(nanoseconds) / 1_000_000_000,
            operationName: "volunteer-order-transition",
            operation: operation
        )
    } catch HomeLoadCoordinatorError.timedOut {
        throw VolunteerOrderActionError.timedOut
    }
}

@MainActor
final class VolunteerOrderDetailViewModel: ObservableObject {
    @Published var order: OrderDetailResponse?
    @Published var isLoading = false
    @Published var isPerformingAction = false
    @Published var errorMessage: String?
    @Published var didCancelOrder = false
    /// 接单被后端 403 `VOLUNTEER_NOT_VERIFIED` 拒绝后，错误区要长出「去上传资质证书」入口。
    @Published var needsCertificateUpload = false
    @Published private(set) var transitionState: VolunteerOrderTransitionState = .idle

    private weak var appState: AppState?
    private var speechService: SpeechService?
    private var realtimeRefreshCancellable: AnyCancellable?
    private var realtimeStatusCancellable: AnyCancellable?
    private var confirmationTask: Task<Void, Never>?
    private let actionDeadlineNanoseconds: UInt64
    private let confirmationTimeout: TimeInterval
    private let orderLoadTimeout: TimeInterval

    init(
        actionDeadlineNanoseconds: UInt64 = 12_000_000_000,
        confirmationTimeout: TimeInterval = HomeLoadPolicy.defaultTimeout,
        orderLoadTimeout: TimeInterval = HomeLoadPolicy.defaultTimeout
    ) {
        self.actionDeadlineNanoseconds = actionDeadlineNanoseconds
        self.confirmationTimeout = max(0.05, confirmationTimeout)
        self.orderLoadTimeout = max(0.05, orderLoadTimeout)
    }

    var isTransitionPending: Bool { transitionState.blocksDuplicateSubmission }
    var transitionMessage: String? { transitionState.message }
    var canRetryTransitionConfirmation: Bool {
        if case .confirmationDelayed = transitionState { return true }
        return false
    }

    var canAccept: Bool {
        order?.status == .pendingMatch
    }

    var canShowPhone: Bool {
        guard let order else { return false }
        return order.status != .pendingMatch && order.blindPhone?.trimmed.isEmpty == false
    }

    func configure(with appState: AppState, speechService: SpeechService) {
        self.appState = appState
        self.speechService = speechService
        if realtimeRefreshCancellable == nil {
            realtimeRefreshCancellable = appState.realtimeCoordinator.$pendingOrderRefreshIDs
                .receive(on: DispatchQueue.main)
                .sink { [weak self] orderIDs in
                    guard let self, let orderID = self.order?.orderId, orderIDs.contains(orderID) else { return }
                    Task { await self.load(orderId: orderID) }
                }
        }
        if realtimeStatusCancellable == nil {
            realtimeStatusCancellable = appState.realtimeCoordinator.statusUpdatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] update in
                    guard let self,
                          let current = self.order,
                          current.orderId == update.orderId else { return }
                    self.apply(
                        current.replacingStatus(with: update.toStatus),
                        speakChanges: true
                    )
                    self.isLoading = false
                    self.errorMessage = nil
                }
        }
    }

    func load(orderId: Int64) async {
        guard let appState else { return }
        appState.realtimeCoordinator.registerActiveOrder(orderId)
        var refreshedAuthoritativeOrder = false
        defer {
            if refreshedAuthoritativeOrder {
                appState.realtimeCoordinator.completeOrderRefresh(orderId)
            } else {
                appState.realtimeCoordinator.failOrderRefresh(orderId)
            }
        }
        isLoading = order == nil
        errorMessage = nil

        do {
            let apiClient = appState.apiClient
            let requestToken = appState.realtimeCoordinator.beginOrderStatusRequest(orderID: orderId)
            let candidate: OrderDetailResponse = try await HomeLoadCoordinator.run(
                timeout: orderLoadTimeout,
                operationName: "volunteer-order-detail"
            ) {
                try await apiClient.get("/api/orders/\(orderId)")
            }
            guard let loaded = appState.realtimeCoordinator.reconcileOrderDetail(
                candidate,
                requestToken: requestToken
            ) else {
                isLoading = false
                return
            }
            refreshedAuthoritativeOrder = true
            apply(loaded, speakChanges: false)
            isLoading = false
        } catch let error as APIError {
            isLoading = false
            if appState.handleAuthenticatedAPIError(error) {
                return
            }
            errorMessage = error.localizedMessage
            speechService?.speakError(error.localizedMessage)
        } catch {
            isLoading = false
            errorMessage = "订单加载失败，请重试"
            speechService?.speakError("订单加载失败，请重试")
        }
    }

    func accept(currentLocation: CLLocationCoordinate2D?, locationAuthorized: Bool) async {
        guard let order, let appState else { return }
        if let message = VolunteerOrderActionGuard.acceptBlockMessage(
            profile: appState.volunteerProfile,
            registrationStatus: appState.volunteerRegistrationStatus,
            locationAuthorized: locationAuthorized
        ) {
            errorMessage = message
            speechService?.speakError(message)
            return
        }
        VolunteerLocationReporter.reportIfNeeded(
            appState: appState,
            currentLocation: currentLocation,
            locationAuthorized: locationAuthorized
        )
        let apiClient = appState.apiClient
        let orderID = order.orderId
        await submitTransition(target: .pendingAccept, orderID: orderID, appState: appState) {
            let request = OrderRespondRequest(action: .accept)
            return try await apiClient.post(
                "/api/orders/\(orderID)/respond",
                body: request
            ) as EmptyResponse
        }
    }

    func enRoute() async {
        guard let order, let appState else { return }
        let apiClient = appState.apiClient
        let orderID = order.orderId
        await submitTransition(target: .driverEnRoute, orderID: orderID, appState: appState) {
            try await apiClient.post("/api/orders/\(orderID)/en-route") as EmptyResponse
        }
    }

    func arrive() async {
        guard let order, let appState else { return }
        let apiClient = appState.apiClient
        let orderID = order.orderId
        await submitTransition(target: .driverArrived, orderID: orderID, appState: appState) {
            try await apiClient.post("/api/orders/\(orderID)/arrived") as EmptyResponse
        }
    }

    func startService() async {
        guard let order, let appState else { return }
        guard order.status.canStartService else {
            let message = order.status.startServiceBlockedMessage
            errorMessage = message
            speechService?.speakError(message)
            return
        }
        let apiClient = appState.apiClient
        let orderID = order.orderId
        await submitTransition(target: .inProgress, orderID: orderID, appState: appState) {
            try await apiClient.post("/api/orders/\(orderID)/start-service") as EmptyResponse
        }
    }

    func cancel() async {
        guard let order, let appState else { return }
        let apiClient = appState.apiClient
        let orderID = order.orderId
        await submitTransition(target: .rematching, orderID: orderID, appState: appState) {
            try await apiClient.post("/api/orders/\(orderID)/cancel") as EmptyResponse
        }
    }

    func retryTransitionConfirmation() {
        guard let order, let appState, let target = transitionState.targetStatus else { return }
        transitionState = .awaitingConfirmation(target: target)
        errorMessage = nil
        startTransitionConfirmation(orderID: order.orderId, target: target, appState: appState)
    }

    private func submitTransition(
        target: RunOrderStatus,
        orderID: Int64,
        appState: AppState,
        operation: @escaping @Sendable () async throws -> EmptyResponse
    ) async {
        guard !isPerformingAction else { return }
        if transitionState.blocksDuplicateSubmission {
            guard transitionState.targetStatus != target else { return }
            let message = "上一项操作的状态尚未确认，请先重新确认状态。"
            errorMessage = message
            speechService?.speakError(message)
            return
        }
        confirmationTask?.cancel()
        confirmationTask = nil
        transitionState = .submitting(target: target)
        ClientFlowDiagnostics.record(event: "submitted", operation: "volunteer-detail-transition") // guard:allow legacy-status 诊断事件名，非订单状态
        isPerformingAction = true
        errorMessage = nil
        needsCertificateUpload = false
        defer { isPerformingAction = false }
        do {
            _ = try await withVolunteerOrderActionDeadline(
                nanoseconds: actionDeadlineNanoseconds,
                operation: operation
            )
            transitionState = .awaitingConfirmation(target: target)
            ClientFlowDiagnostics.record(event: "awaiting_confirmation", operation: "volunteer-detail-transition")
            startTransitionConfirmation(orderID: orderID, target: target, appState: appState)
        } catch VolunteerOrderActionError.timedOut {
            markTransitionOutcomeUnknown(target: target, orderID: orderID, appState: appState)
        } catch let error as APIError {
            if appState.handleAuthenticatedAPIError(error) {
                transitionState = .failed(message: error.localizedMessage)
                return
            }
            switch error {
            case .networkError, .decodingError:
                markTransitionOutcomeUnknown(target: target, orderID: orderID, appState: appState)
            case .serverError, .rateLimited, .unknown, .invalidURL:
                transitionState = .failed(message: error.localizedMessage)
                // 403 VOLUNTEER_NOT_VERIFIED 的唯一解法是上传资质证书，错误区必须给出入口。
                needsCertificateUpload = error.errorCode == .volunteerNotApproved
                errorMessage = error.localizedMessage
                speechService?.speakError(error.localizedMessage)
            case .unauthorized:
                transitionState = .failed(message: error.localizedMessage)
            }
        } catch {
            markTransitionOutcomeUnknown(target: target, orderID: orderID, appState: appState)
        }
    }

    private func markTransitionOutcomeUnknown(
        target: RunOrderStatus,
        orderID: Int64,
        appState: AppState
    ) {
        transitionState = .awaitingConfirmation(target: target)
        speechService?.speakError("操作结果尚未确认，正在后台同步状态。请勿重复提交同一操作。")
        startTransitionConfirmation(orderID: orderID, target: target, appState: appState)
    }

    private func startTransitionConfirmation(
        orderID: Int64,
        target: RunOrderStatus,
        appState: AppState
    ) {
        confirmationTask?.cancel()
        let apiClient = appState.apiClient
        let requestToken = appState.realtimeCoordinator.beginOrderStatusRequest(orderID: orderID)
        confirmationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let candidate: OrderDetailResponse = try await HomeLoadCoordinator.run(
                    timeout: self.confirmationTimeout,
                    operationName: "volunteer-detail-transition-confirmation"
                ) {
                    try await apiClient.get("/api/orders/\(orderID)")
                }
                guard !Task.isCancelled,
                      self.order?.orderId == orderID,
                      self.transitionState.targetStatus == target else { return }
                guard let updated = appState.realtimeCoordinator.reconcileOrderDetail(
                    candidate,
                    requestToken: requestToken
                ) else { return }
                self.apply(updated, speakChanges: true)
                if !updated.status.satisfiesVolunteerTransition(target: target) {
                    self.transitionState = .confirmationDelayed(target: target)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      self.order?.orderId == orderID,
                      self.transitionState.targetStatus == target else { return }
                self.transitionState = .confirmationDelayed(target: target)
                ClientFlowDiagnostics.record(event: "confirmation_delayed", operation: "volunteer-detail-transition")
            }
            self.confirmationTask = nil
        }
    }

    private func apply(_ updated: OrderDetailResponse, speakChanges: Bool) {
        let previousStatus = order?.status
        order = updated
        appState?.liveEscortCoordinator.updateOwnedOrder(orderID: updated.orderId, status: updated.status)
        if speakChanges, previousStatus != updated.status {
            speechService?.speakStatusChange(updated.status)
        }
        if let target = transitionState.targetStatus,
           updated.status.satisfiesVolunteerTransition(target: target) {
            transitionState = .idle
            ClientFlowDiagnostics.record(event: "confirmed", operation: "volunteer-detail-transition")
            confirmationTask?.cancel()
            confirmationTask = nil
            errorMessage = nil
        }
        if updated.status == .rematching || updated.status == .cancelled {
            appState?.realtimeCoordinator.unregisterActiveOrder(updated.orderId)
            appState?.liveEscortCoordinator.clearOwnedOrder()
            didCancelOrder = true
            speechService?.speak("订单已取消，系统将为盲人重新匹配。")
        }
    }
}

struct VolunteerOrderDetailView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var speechService: SpeechService
    @EnvironmentObject private var locationService: LocationService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = VolunteerOrderDetailViewModel()
    @StateObject private var trackViewModel = CompletedTrackSummaryViewModel()
    @State private var showAcceptConfirm = false
    @State private var showCancelConfirm = false
    @State private var serviceNavigationOrder: OrderDetailResponse?
    let orderId: Int64

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if viewModel.isLoading && viewModel.order == nil {
                    ProgressView("正在加载订单...")
                        .accessibilityLabel("正在加载订单")
                }

                if let order = viewModel.order {
                    VolunteerStatusBanner(status: order.status)
                    VolunteerOrderMap(order: order)
                    VolunteerBlindRunnerInfoCard(order: order, showPhone: viewModel.canShowPhone)
                    VolunteerOrderInfoSection(order: order, distanceText: distanceText(for: order))
                    // 这一页是志愿者首页「近期服务」点进来的落点。此前它没有轨迹，
                    // 而「服务记录」点进来的 `VolunteerReadOnlyOrderView` 有 ——
                    // 同一个已完成订单换个入口就看不到路线，用户报的就是这个。
                    completedTrackSection(order)
                    actionSection(order)
                }

                if let transitionMessage = viewModel.transitionMessage {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(transitionMessage, systemImage: "clock.arrow.circlepath")
                            .font(AppFonts.body())
                            .foregroundColor(AppColors.warning)
                            .accessibilityLabel(transitionMessage)
                        if viewModel.canRetryTransitionConfirmation {
                            Button("重新确认状态") {
                                viewModel.retryTransitionConfirmation()
                            }
                            .buttonStyle(.bordered)
                            .accessibilityHint("只重新查询订单状态，不会重复提交当前操作")
                        }
                    }
                }

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(AppFonts.body())
                        .foregroundColor(AppColors.destructive)
                        .accessibilityLabel(errorMessage)
                }

                // 接单被后端 403 VOLUNTEER_NOT_VERIFIED 拒绝时，直接给出上传入口。
                if viewModel.needsCertificateUpload {
                    VolunteerCertificateUploadEntryLink(
                        title: "去上传资质证书",
                        subtitle: "资质审核通过后才能接单"
                    )
                }
            }
            .padding(20)
        }
        .navigationTitle("订单详情")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            viewModel.configure(with: appState, speechService: speechService)
            locationService.requestPermission()
            locationService.startUpdating()
            await viewModel.load(orderId: orderId)
            if viewModel.order?.status == .completed {
                await trackViewModel.load(orderID: orderId, appState: appState)
            }
        }
        .onChange(of: viewModel.order?.status) { status in
            guard status?.isActiveForVolunteer == true,
                  let order = viewModel.order else { return }
            serviceNavigationOrder = order
        }
        .alert("确认接单", isPresented: $showAcceptConfirm) {
            Button("确认接单") {
                Task {
                    await viewModel.accept(
                        currentLocation: locationService.currentLocation,
                        locationAuthorized: locationService.isAuthorized
                    )
                    if let order = viewModel.order, order.status.isActiveForVolunteer {
                        serviceNavigationOrder = order
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确认接单后将显示盲人联系方式。")
        }
        .confirmationDialog("取消订单", isPresented: $showCancelConfirm) {
            Button("确认取消", role: .destructive) {
                Task {
                    await viewModel.cancel()
                    if viewModel.didCancelOrder {
                        dismiss()
                    }
                }
            }
            Button("不取消", role: .cancel) {}
        } message: {
            Text("确认取消本次预约？")
        }
        .navigationDestination(
            isPresented: Binding(
                get: { serviceNavigationOrder != nil },
                set: { isPresented in
                    if !isPresented {
                        serviceNavigationOrder = nil
                    }
                }
            )
        ) {
            if let order = serviceNavigationOrder {
                VolunteerInServiceView(orderId: order.orderId, initialOrder: order)
            }
        }
    }

    @ViewBuilder
    private func completedTrackSection(_ order: OrderDetailResponse) -> some View {
        if order.status == .completed {
            if let track = trackViewModel.track {
                CompletedTrackSummaryView(track: track, orderID: order.orderId) {
                    speechService.speak(track.spokenSummary)
                }
            } else if trackViewModel.isLoading {
                ProgressView("正在加载本次路线")
                    .accessibilityLabel("正在加载本次路线")
                    .accessibilityIdentifier("volunteerOrderDetailTrackLoading")
            } else if let message = trackViewModel.errorMessage {
                // 轨迹拉不到不该把整页判成失败：订单信息和联系方式仍然有用。
                Text(message)
                    .font(AppFonts.body())
                    .foregroundColor(AppColors.textSecondary)
                    .accessibilityLabel(message)
            }
        }
    }

    private func actionSection(_ order: OrderDetailResponse) -> some View {
        VStack(spacing: 12) {
            if order.status == .pendingMatch {
                let blockMessage = VolunteerOrderActionGuard.acceptBlockMessage(
                    profile: appState.volunteerProfile,
                    registrationStatus: appState.volunteerRegistrationStatus,
                    locationAuthorized: locationService.isAuthorized
                )
                PrimaryButton("接单", isLoading: viewModel.isPerformingAction) {
                    showAcceptConfirm = true
                }
                .disabled(
                    blockMessage != nil
                        || viewModel.isPerformingAction
                        || viewModel.isTransitionPending
                )
                .opacity(blockMessage == nil ? 1 : 0.45)
                .accessibilityLabel("接单")
                .accessibilityHint(blockMessage ?? "确认接单后将显示盲人联系方式")

                if let blockMessage {
                    Text(blockMessage)
                        .font(AppFonts.caption())
                        .foregroundColor(AppColors.warning)
                        .accessibilityLabel(blockMessage)
                }
            } else if order.status == .pendingAccept || order.status == .inProgress || order.status == .driverEnRoute || order.status == .driverArrived {
                NavigationLink {
                    VolunteerInServiceView(orderId: order.orderId, initialOrder: order)
                } label: {
                    Text("进入服务页面")
                        .font(AppFonts.primaryButton())
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 64)
                        .foregroundColor(.white)
                        .background(AppColors.primary)
                        .cornerRadius(8)
                }
                .accessibilityLabel("进入服务页面")
                .accessibilityHint("查看当前订单服务状态")

                if order.status.canVolunteerCancel {
                    Button("取消订单", role: .destructive) {
                        showCancelConfirm = true
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 52)
                    .accessibilityLabel("取消订单")
                    .accessibilityHint("需要确认后取消")
                }
            }
        }
    }

    private func distanceText(for order: OrderDetailResponse) -> String? {
        guard locationService.isAuthorized,
              let deviceCoordinate = locationService.currentLocation,
              let coordinate = orderCoordinate(order) else { return nil }
        let meters = DistanceCalculator.distanceFromDeviceToBackend(
            deviceCoordinate: deviceCoordinate,
            backendCoordinate: coordinate
        )
        return DistanceCalculator.formattedDistance(meters)
    }
}

// MARK: - In Service

@MainActor
final class VolunteerInServiceViewModel: ObservableObject {
    @Published var order: OrderDetailResponse?
    @Published var isLoading = false
    @Published var isPerformingAction = false
    @Published var errorMessage: String?
    @Published var dispatchSummary: VolunteerDispatchSummaryResponse?
    @Published var didCancelOrder = false
    @Published private(set) var latestBlindSample: LocatedCoordinate?
    @Published private(set) var transitionState: VolunteerOrderTransitionState = .idle
    @Published private(set) var isAcknowledgingEmergency = false

    private weak var appState: AppState?
    private var speechService: SpeechService?
    private var pollingTask: Task<Void, Never>?
    private var realtimeRefreshCancellable: AnyCancellable?
    private var realtimeStatusCancellable: AnyCancellable?
    private var peerLocationCancellable: AnyCancellable?
    private var confirmationTask: Task<Void, Never>?
    private var dispatchSummaryTask: Task<Void, Never>?
    private var peerExpiryTask: Task<Void, Never>?
    private var acceptsPeerLocations = true
    private let actionDeadlineNanoseconds: UInt64
    private let confirmationTimeout: TimeInterval
    private let orderLoadTimeout: TimeInterval
    private let peerFreshness: TimeInterval

    init(
        actionDeadlineNanoseconds: UInt64 = 12_000_000_000,
        confirmationTimeout: TimeInterval = HomeLoadPolicy.defaultTimeout,
        orderLoadTimeout: TimeInterval = HomeLoadPolicy.defaultTimeout,
        peerFreshness: TimeInterval = LiveEscortSessionCoordinator.peerFreshness
    ) {
        self.actionDeadlineNanoseconds = actionDeadlineNanoseconds
        self.confirmationTimeout = max(0.05, confirmationTimeout)
        self.orderLoadTimeout = max(0.05, orderLoadTimeout)
        self.peerFreshness = max(0.01, peerFreshness)
    }

    var isTransitionPending: Bool { transitionState.blocksDuplicateSubmission }
    var transitionMessage: String? { transitionState.message }
    var canRetryTransitionConfirmation: Bool {
        if case .confirmationDelayed = transitionState { return true }
        return false
    }

    func configure(with appState: AppState, speechService: SpeechService, initialOrder: OrderDetailResponse?) {
        self.appState = appState
        self.speechService = speechService
        acceptsPeerLocations = true
        if order == nil {
            order = initialOrder
        }
        if let order {
            appState.liveEscortCoordinator.updateOwnedOrder(orderID: order.orderId, status: order.status)
        }
        if realtimeRefreshCancellable == nil {
            realtimeRefreshCancellable = appState.realtimeCoordinator.$pendingOrderRefreshIDs
                .receive(on: DispatchQueue.main)
                .sink { [weak self] orderIDs in
                    guard let self, let orderID = self.order?.orderId, orderIDs.contains(orderID) else { return }
                    Task { await self.load(orderId: orderID, speakChanges: true) }
                }
        }
        if realtimeStatusCancellable == nil {
            realtimeStatusCancellable = appState.realtimeCoordinator.statusUpdatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] update in
                    guard let self,
                          let current = self.order,
                          current.orderId == update.orderId else { return }
                    self.apply(
                        current.replacingStatus(with: update.toStatus),
                        speakChanges: true
                    )
                    self.isLoading = false
                }
        }
        if peerLocationCancellable == nil {
            peerLocationCancellable = appState.realtimeCoordinator.peerLocationPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] sample in
                    self?.handleBlindLocationUpdate(sample)
                }
        }
    }

    func startPolling(orderId: Int64) {
        if order?.orderId != orderId {
            clearPeerLocation()
        }
        acceptsPeerLocations = true
        appState?.realtimeCoordinator.registerActiveOrder(orderId)
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            await self?.load(orderId: orderId, speakChanges: true)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(AppConstants.Timing.orderPollingInterval * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.load(orderId: orderId, speakChanges: true)
                if self?.order?.status.isTerminal == true {
                    return
                }
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        confirmationTask?.cancel()
        confirmationTask = nil
        acceptsPeerLocations = false
        clearPeerLocation()
    }

    func load(orderId: Int64, speakChanges: Bool) async {
        guard let appState else { return }
        var refreshedAuthoritativeOrder = false
        defer {
            if refreshedAuthoritativeOrder {
                appState.realtimeCoordinator.completeOrderRefresh(orderId)
            } else {
                appState.realtimeCoordinator.failOrderRefresh(orderId)
            }
        }
        isLoading = order == nil
        do {
            let apiClient = appState.apiClient
            let requestToken = appState.realtimeCoordinator.beginOrderStatusRequest(orderID: orderId)
            let candidate: OrderDetailResponse = try await HomeLoadCoordinator.run(
                timeout: orderLoadTimeout,
                operationName: "volunteer-order-poll"
            ) {
                try await apiClient.get("/api/orders/\(orderId)")
            }
            guard let loaded = appState.realtimeCoordinator.reconcileOrderDetail(
                candidate,
                requestToken: requestToken
            ) else {
                isLoading = false
                return
            }
            refreshedAuthoritativeOrder = true
            apply(loaded, speakChanges: speakChanges)
            isLoading = false
        } catch {
            isLoading = false
            if order == nil {
                errorMessage = "获取订单状态失败"
            }
        }
    }

    func enRoute() async {
        guard let order, let appState else { return }
        let apiClient = appState.apiClient
        let orderID = order.orderId
        await submitTransition(target: .driverEnRoute, orderID: orderID, appState: appState) {
            try await apiClient.post("/api/orders/\(orderID)/en-route") as EmptyResponse
        }
    }

    func arrive() async {
        guard let order, let appState else { return }
        let apiClient = appState.apiClient
        let orderID = order.orderId
        await submitTransition(target: .driverArrived, orderID: orderID, appState: appState) {
            try await apiClient.post("/api/orders/\(orderID)/arrived") as EmptyResponse
        }
    }

    func handleBlindLocationUpdate(_ sample: RealtimePeerLocationSample) {
        guard acceptsPeerLocations,
              sample.ownerRole == .blind,
              sample.orderId == order?.orderId else { return }
        let capturedAt = Date(timeIntervalSince1970: TimeInterval(sample.timestampMilliseconds) / 1_000)
        let age = max(0, Date().timeIntervalSince(capturedAt))
        guard age <= peerFreshness,
              let located = BackendCoordinateNormalizer.backend(
                latitude: sample.latitude,
                longitude: sample.longitude,
                capturedAt: capturedAt
              ) else { return }

        latestBlindSample = located
        schedulePeerExpiry(for: located, orderID: sample.orderId, remaining: peerFreshness - age)
    }

    func startService() async {
        guard let order, let appState else { return }
        guard order.status.canStartService else {
            let message = order.status.startServiceBlockedMessage
            errorMessage = message
            speechService?.speakError(message)
            return
        }
        let apiClient = appState.apiClient
        let orderID = order.orderId
        await submitTransition(target: .inProgress, orderID: orderID, appState: appState) {
            try await apiClient.post("/api/orders/\(orderID)/start-service") as EmptyResponse
        }
    }

    func cancel() async {
        guard let order, let appState else { return }
        let apiClient = appState.apiClient
        let orderID = order.orderId
        await submitTransition(target: .rematching, orderID: orderID, appState: appState) {
            try await apiClient.post("/api/orders/\(orderID)/cancel") as EmptyResponse
        }
    }

    func complete(summary: String) async {
        guard let order, let appState else { return }
        guard order.status.canFinishService else {
            let message = order.status.finishBlockedMessage
            errorMessage = message
            speechService?.speakError(message)
            return
        }
        let apiClient = appState.apiClient
        let orderID = order.orderId
        await submitTransition(target: .completed, orderID: orderID, appState: appState) {
            try await apiClient.post("/api/orders/\(orderID)/finish") as EmptyResponse
        }
    }

    func retryTransitionConfirmation() {
        guard let order, let appState, let target = transitionState.targetStatus else { return }
        transitionState = .awaitingConfirmation(target: target)
        errorMessage = nil
        startTransitionConfirmation(
            orderID: order.orderId,
            target: target,
            appState: appState
        )
    }

    // MARK: - 紧急求助（志愿者侧）

    /// 代被陪同的盲人发起求助。与盲人侧同一条路径、同一个 GPS 严格门槛（拿不到真实定位就不发），
    /// 区别只在后端把事件挂在订单的盲人身上、并用 `VOLUNTEER_BUTTON` 标注来源。
    func enterEmergency(locate: @escaping () async -> LocatedCoordinate?) async {
        guard let order, let appState else { return }
        let outcome = await appState.emergencyCoordinator.trigger(
            order: order,
            role: appState.activeRole,
            userID: appState.userId,
            apiClient: appState.apiClient,
            locate: locate
        )
        if outcome.isFailure {
            speechService?.speakError(outcome.message)
        } else {
            speechService?.speak(outcome.message)
        }
    }

    /// 对被陪同者的求助回一句「确认需要帮助」。这是志愿者唯一能做的响应。
    func acknowledgeEmergency(eventID: Int64) async {
        guard let appState, !isAcknowledgingEmergency else { return }
        isAcknowledgingEmergency = true
        let succeeded = await appState.emergencyCoordinator.acknowledgeAsVolunteer(
            eventID: eventID,
            apiClient: appState.apiClient
        )
        isAcknowledgingEmergency = false
        if succeeded {
            speechService?.speak(EmergencySafetyCopy.volunteerAcknowledged)
        } else {
            let message = "确认失败，请重试。若情况危急请立即拨打110。"
            errorMessage = message
            speechService?.speakError(message)
        }
    }

    private func submitTransition(
        target: RunOrderStatus,
        orderID: Int64,
        appState: AppState,
        operation: @escaping @Sendable () async throws -> EmptyResponse
    ) async {
        guard !isPerformingAction else { return }
        if transitionState.blocksDuplicateSubmission {
            guard transitionState.targetStatus != target else { return }
            let message = "上一项操作的状态尚未确认，请先重新确认状态。"
            errorMessage = message
            speechService?.speakError(message)
            return
        }
        confirmationTask?.cancel()
        confirmationTask = nil
        transitionState = .submitting(target: target)
        ClientFlowDiagnostics.record(event: "submitted", operation: "volunteer-service-transition") // guard:allow legacy-status 诊断事件名，非订单状态
        isPerformingAction = true
        errorMessage = nil
        defer { isPerformingAction = false }
        do {
            _ = try await withVolunteerOrderActionDeadline(
                nanoseconds: actionDeadlineNanoseconds,
                operation: operation
            )
            transitionState = .awaitingConfirmation(target: target)
            ClientFlowDiagnostics.record(event: "awaiting_confirmation", operation: "volunteer-service-transition")
            startTransitionConfirmation(orderID: orderID, target: target, appState: appState)
            simulateRealtimeConfirmationIfRequested(
                orderID: orderID,
                fromStatus: order?.status,
                target: target,
                appState: appState
            )
        } catch VolunteerOrderActionError.timedOut {
            markTransitionOutcomeUnknown(target: target, orderID: orderID, appState: appState)
        } catch let error as APIError {
            if appState.handleAuthenticatedAPIError(error) {
                transitionState = .failed(message: error.localizedMessage)
                return
            }
            switch error {
            case .networkError, .decodingError:
                markTransitionOutcomeUnknown(target: target, orderID: orderID, appState: appState)
            case .serverError, .rateLimited, .unknown, .invalidURL:
                transitionState = .failed(message: error.localizedMessage)
                errorMessage = error.localizedMessage
                speechService?.speakError(error.localizedMessage)
            case .unauthorized:
                transitionState = .failed(message: error.localizedMessage)
            }
        } catch {
            markTransitionOutcomeUnknown(target: target, orderID: orderID, appState: appState)
        }
    }

    private func simulateRealtimeConfirmationIfRequested(
        orderID: Int64,
        fromStatus: RunOrderStatus?,
        target: RunOrderStatus,
        appState: AppState
    ) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["AIDRUN_UI_TEST_CONFIRM_TRANSITION_VIA_REALTIME"] == "1",
              let fromStatus else { return }
        Task { @MainActor in
            await Task.yield()
            appState.realtimeCoordinator.simulateIncomingEventForTesting(
                .orderStatusChanged(
                    WSOrderStatusChanged(
                        type: WSMessageType.orderStatusChanged.rawValue,
                        orderId: orderID,
                        fromStatus: fromStatus.rawValue,
                        toStatus: target.rawValue,
                        message: nil,
                        ttsText: nil,
                        priority: "NORMAL",
                        timestamp: nil
                    )
                )
            )
        }
        #endif
    }

    private func markTransitionOutcomeUnknown(
        target: RunOrderStatus,
        orderID: Int64,
        appState: AppState
    ) {
        transitionState = .awaitingConfirmation(target: target)
        let message = "操作结果尚未确认，正在后台同步状态。请勿重复提交同一操作。"
        errorMessage = nil
        speechService?.speakError(message)
        startTransitionConfirmation(orderID: orderID, target: target, appState: appState)
    }

    private func startTransitionConfirmation(
        orderID: Int64,
        target: RunOrderStatus,
        appState: AppState
    ) {
        confirmationTask?.cancel()
        let apiClient = appState.apiClient
        let requestToken = appState.realtimeCoordinator.beginOrderStatusRequest(orderID: orderID)
        confirmationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let candidate: OrderDetailResponse = try await HomeLoadCoordinator.run(
                    timeout: self.confirmationTimeout,
                    operationName: "volunteer-transition-confirmation"
                ) {
                    try await apiClient.get("/api/orders/\(orderID)")
                }
                guard !Task.isCancelled,
                      self.order?.orderId == orderID,
                      self.transitionState.targetStatus == target else { return }
                guard let updated = appState.realtimeCoordinator.reconcileOrderDetail(
                    candidate,
                    requestToken: requestToken
                ) else { return }
                self.apply(updated, speakChanges: true)
                if !updated.status.satisfiesVolunteerTransition(target: target) {
                    self.transitionState = .confirmationDelayed(target: target)
                    self.errorMessage = nil
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      self.order?.orderId == orderID,
                      self.transitionState.targetStatus == target else { return }
                self.transitionState = .confirmationDelayed(target: target)
                ClientFlowDiagnostics.record(event: "confirmation_delayed", operation: "volunteer-service-transition")
                self.errorMessage = nil
            }
            self.confirmationTask = nil
        }
    }

    private func apply(_ updated: OrderDetailResponse, speakChanges: Bool) {
        let previousStatus = order?.status
        order = updated
        appState?.liveEscortCoordinator.updateOwnedOrder(orderID: updated.orderId, status: updated.status)
        if speakChanges, previousStatus != updated.status {
            speechService?.speakStatusChange(updated.status)
        }
        if let target = transitionState.targetStatus,
           updated.status.satisfiesVolunteerTransition(target: target) {
            transitionState = .idle
            ClientFlowDiagnostics.record(event: "confirmed", operation: "volunteer-service-transition")
            confirmationTask?.cancel()
            confirmationTask = nil
            errorMessage = nil
        }
        if updated.status == .rematching {
            appState?.realtimeCoordinator.unregisterActiveOrder(updated.orderId)
            appState?.liveEscortCoordinator.clearOwnedOrder()
            stopPolling()
            didCancelOrder = true
            order = nil
            speechService?.speak("订单已取消，系统将为盲人重新匹配。")
            return
        }
        if updated.status.isTerminal {
            appState?.realtimeCoordinator.unregisterActiveOrder(updated.orderId)
            stopPolling()
            if updated.status == .completed, let appState {
                refreshDispatchSummary(using: appState)
            }
            if updated.status == .cancelled {
                didCancelOrder = true
                order = nil
                speechService?.speak("订单已取消，系统将为盲人重新匹配。")
            }
        }
    }

    private func schedulePeerExpiry(
        for sample: LocatedCoordinate,
        orderID: Int64,
        remaining: TimeInterval
    ) {
        peerExpiryTask?.cancel()
        peerExpiryTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(max(0.01, remaining) * 1_000_000_000)
                )
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.order?.orderId == orderID,
                  self.latestBlindSample == sample else { return }
            self.clearPeerLocation()
        }
    }

    private func clearPeerLocation() {
        peerExpiryTask?.cancel()
        peerExpiryTask = nil
        latestBlindSample = nil
    }

    private func refreshDispatchSummary(using appState: AppState) {
        guard dispatchSummaryTask == nil else { return }
        let apiClient = appState.apiClient
        dispatchSummaryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.dispatchSummaryTask = nil }
            do {
                let summary: VolunteerDispatchSummaryResponse = try await HomeLoadCoordinator.run(
                    timeout: self.orderLoadTimeout,
                    operationName: "volunteer-service-summary-refresh"
                ) {
                    try await apiClient.get("/api/volunteer/dispatch-summary")
                }
                guard !Task.isCancelled else { return }
                self.dispatchSummary = summary
                ClientFlowDiagnostics.record(event: "confirmed", operation: "volunteer-service-summary-refresh")
            } catch is CancellationError {
                return
            } catch {
                ClientFlowDiagnostics.record(event: "failed", operation: "volunteer-service-summary-refresh")
            }
        }
    }
}

struct VolunteerInServiceView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var speechService: SpeechService
    @EnvironmentObject private var locationService: LocationService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = VolunteerInServiceViewModel()
    @StateObject private var trackViewModel = CompletedTrackSummaryViewModel()
    @State private var showCancelConfirm = false
    @State private var showEmergencyConfirm = false
    @State private var activeSheet: VolunteerSheet?
    let orderId: Int64
    let initialOrder: OrderDetailResponse?

    init(orderId: Int64, initialOrder: OrderDetailResponse? = nil) {
        self.orderId = orderId
        self.initialOrder = initialOrder
    }

    var body: some View {
        GeometryReader { proxy in
            let bottomPanelMaxHeight = proxy.size.height * 0.62
            let mapAnchor = CGPoint(
                x: 0.5,
                y: VolunteerServiceMapLayout.screenAnchorY(
                    viewportHeight: proxy.size.height,
                    topSafeAreaInset: proxy.safeAreaInsets.top,
                    bottomPanelMaxHeight: bottomPanelMaxHeight
                )
            )
            ZStack(alignment: .bottom) {
                if let order = viewModel.order {
                    VolunteerServiceMapBackdrop(
                        order: order,
                        screenAnchor: mapAnchor,
                        peerSample: viewModel.latestBlindSample
                    )
                } else {
                    AppColors.secondaryBackground
                        .ignoresSafeArea()
                }

                if viewModel.isLoading && viewModel.order == nil {
                    ProgressView("正在获取订单状态...")
                        .padding()
                        .background(.regularMaterial)
                        .cornerRadius(8)
                        .accessibilityLabel("正在获取订单状态")
                }

                if let order = viewModel.order {
                    if order.status == .completed {
                        completedTrackContent
                    } else {
                        VStack(spacing: 10) {
                            emergencySection(for: order)
                            VolunteerServiceBottomPanel(
                            order: order,
                            distanceText: distanceText(for: order),
                            errorMessage: viewModel.errorMessage,
                            transitionMessage: viewModel.transitionMessage,
                            isPerformingAction: viewModel.isPerformingAction,
                            transitionsDisabled: viewModel.isTransitionPending,
                            canRetryTransitionConfirmation: viewModel.canRetryTransitionConfirmation,
                            maxHeight: bottomPanelMaxHeight,
                            onNavigate: {
                                if let request = externalNavigationRequest(
                                    for: order,
                                    currentLocation: locationService.currentLocation,
                                    locationAuthorized: locationService.isAuthorized
                                ) {
                                    activeSheet = .navigation(request)
                                } else {
                                    let message = "不支持导航，等待后端补齐坐标"
                                    viewModel.errorMessage = message
                                    speechService.speakError(message)
                                }
                            },
                            onEnRoute: { Task { await viewModel.enRoute() } },
                            onArrive: { Task { await viewModel.arrive() } },
                            onStartService: { Task { await viewModel.startService() } },
                            onCancel: { showCancelConfirm = true },
                            onComplete: { activeSheet = .completion },
                            onRetryTransitionConfirmation: {
                                viewModel.retryTransitionConfirmation()
                            },
                            )
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                    }
                }
            }
        }
        .navigationTitle("服务中")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            viewModel.configure(with: appState, speechService: speechService, initialOrder: initialOrder)
            locationService.startUpdating()
            viewModel.startPolling(orderId: orderId)
        }
        .onDisappear {
            viewModel.stopPolling()
        }
        .task(id: viewModel.order?.status) {
            guard viewModel.order?.status == .completed else { return }
            await trackViewModel.load(orderID: orderId, appState: appState)
            if let summary = trackViewModel.track?.spokenSummary { speechService.speak(summary) }
        }
        .confirmationDialog("取消订单", isPresented: $showCancelConfirm) {
            Button("确认取消", role: .destructive) {
                Task {
                    await viewModel.cancel()
                    if viewModel.didCancelOrder {
                        dismiss()
                    }
                }
            }
            Button("不取消", role: .cancel) {}
        } message: {
            Text("确认取消本次预约？")
        }
        .emergencyConfirmationAlert(isPresented: $showEmergencyConfirm) {
            Task {
                await viewModel.enterEmergency(locate: { locationService.latestBackendSample() })
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .completion:
                CompleteServiceSheet(isPerformingAction: viewModel.isPerformingAction) { summary in
                    await viewModel.complete(summary: summary)
                    activeSheet = nil
                }
            case .navigation(let request):
                ExternalMapNavigationSheet(request: request)
            }
        }
    }

    /// 志愿者侧的两个紧急动作，都在服务进行中才有意义。
    ///
    /// 上半：被陪同者发出求助时的**唯一**响应「确认需要帮助」。**没有「误触」按钮** —— 后端对
    /// `action=FALSE_ALARM` 恒 403 `EMERGENCY_VOLUNTEER_CANNOT_DISMISS`：一对一陪跑里陪同者本身
    /// 可能就是威胁来源，撤销权只在受助者本人和客服手里。
    /// 下半：代盲人发起求助（后端 2026-07-31 起按订单参与方归属事件，不再回推给按按钮的人）。
    @ViewBuilder
    private func emergencySection(for order: OrderDetailResponse) -> some View {
        let coordinator = appState.emergencyCoordinator
        VStack(spacing: 10) {
            if let alert = coordinator.volunteerAlert, !alert.isAcknowledged {
                EmergencyStatusNotice(message: alert.message, isFailure: true)
                PrimaryButton(
                    EmergencySafetyCopy.volunteerNeedHelpButtonTitle,
                    isDestructive: true,
                    isLoading: viewModel.isAcknowledgingEmergency
                ) {
                    Task { await viewModel.acknowledgeEmergency(eventID: alert.eventID) }
                }
                .accessibilityLabel(EmergencySafetyCopy.volunteerNeedHelpButtonTitle)
                .accessibilityHint("确认被陪同者确实需要帮助，客服会介入")
            }

            if order.status.canVolunteerTriggerEmergency {
                EmergencyActionButton(isLoading: coordinator.state.isBusy) {
                    showEmergencyConfirm = true
                }
                if let message = coordinator.state.message {
                    EmergencyStatusNotice(message: message, isFailure: coordinator.state.isFailure)
                }
            }
        }
    }

    private func distanceText(for order: OrderDetailResponse) -> String? {
        guard locationService.isAuthorized,
              let deviceCoordinate = locationService.currentLocation,
              let coordinate = orderCoordinate(order) else { return nil }
        let meters = DistanceCalculator.distanceFromDeviceToBackend(
            deviceCoordinate: deviceCoordinate,
            backendCoordinate: coordinate
        )
        return DistanceCalculator.formattedDistance(meters)
    }

    @ViewBuilder
    private var completedTrackContent: some View {
        ScrollView {
            if let track = trackViewModel.track {
                CompletedTrackSummaryView(track: track, orderID: orderId) {
                    speechService.speak(track.spokenSummary)
                }
                .padding(20)
            } else if trackViewModel.isLoading {
                ProgressView("正在加载本次路线")
                    .padding(24)
                    .accessibilityLabel("正在加载本次路线")
                    .accessibilityIdentifier("volunteerCompletedTrackLoading")
            } else {
                let message = trackViewModel.errorMessage ?? "本次路线暂时无法加载。"
                VStack(alignment: .leading, spacing: 16) {
                    Text("服务已完成")
                        .font(AppFonts.title())
                        .accessibilityAddTraits(.isHeader)
                    Text(message)
                        .font(AppFonts.body())
                        .foregroundColor(AppColors.textSecondary)
                        .accessibilityLabel(message)

                    PrimaryButton("重试加载本次路线") {
                        Task {
                            await trackViewModel.load(orderID: orderId, appState: appState)
                            if let summary = trackViewModel.track?.spokenSummary {
                                speechService.speak(summary)
                            }
                        }
                    }
                    .accessibilityLabel("重试加载本次路线")
                    .accessibilityHint("重新获取已完成服务的路线和统计")
                    .accessibilityIdentifier("volunteerCompletedTrackRetry")

                    Button("重复当前状态") {
                        speechService.speak("服务已完成。\(message)")
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 64)
                    .accessibilityHint("朗读服务完成和本次路线暂时不可用状态")
                    .accessibilityIdentifier("volunteerCompletedTrackRepeatStatus")
                }
                .padding(20)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("volunteerCompletedTrackUnavailable")
            }
        }
        .background(AppColors.background)
    }
}

// MARK: - Service Records

@MainActor
final class VolunteerServiceRecordsViewModel: ObservableObject {
    @Published var records: [VolunteerServiceRecord] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private weak var appState: AppState?
    private var speechService: SpeechService?

    func configure(with appState: AppState, speechService: SpeechService) {
        self.appState = appState
        self.speechService = speechService
    }

    func load() async {
        guard let appState else { return }
        isLoading = records.isEmpty
        errorMessage = nil
        do {
            let paged: PagedOrderResponse = try await appState.apiClient.get("/api/orders/mine")
            records = paged.content
                .filter { [.completed, .cancelled].contains($0.status) }
                .map(VolunteerServiceRecord.init(order:))
                .sorted { $0.sortKey > $1.sortKey }
            isLoading = false
        } catch let error as APIError {
            isLoading = false
            if appState.handleAuthenticatedAPIError(error) {
                return
            }
            errorMessage = error.localizedMessage
            speechService?.speakError(error.localizedMessage)
        } catch {
            isLoading = false
            errorMessage = "加载失败，下拉重试"
            speechService?.speakError("加载失败，下拉重试")
        }
    }
}

struct VolunteerServiceRecordsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var speechService: SpeechService
    @StateObject private var viewModel = VolunteerServiceRecordsViewModel()

    var body: some View {
        List {
            if viewModel.isLoading {
                ProgressView("正在加载服务记录...")
                    .accessibilityLabel("正在加载服务记录")
            } else if viewModel.records.isEmpty {
                EmptyStateView(title: "暂无服务记录", message: "完成服务后记录将显示在这里。开启可服务状态后，系统会自动派单。")
            } else {
                ForEach(viewModel.records) { record in
                    NavigationLink {
                        VolunteerReadOnlyOrderView(order: record.order)
                    } label: {
                        VolunteerServiceRecordRow(record: record)
                    }
                    .accessibilityLabel(record.accessibilityLabel)
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundColor(AppColors.destructive)
                    .accessibilityLabel(errorMessage)
            }
        }
        .navigationTitle("服务记录")
        .task {
            viewModel.configure(with: appState, speechService: speechService)
            await viewModel.load()
        }
        .refreshable {
            await viewModel.load()
        }
    }
}

// MARK: - Points Placeholder

@MainActor
final class VolunteerPointsViewModel: ObservableObject {
    @Published var errorMessage: String?

    private weak var appState: AppState?

    func configure(with appState: AppState) {
        self.appState = appState
    }
}

struct VolunteerPointsPlaceholderView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = VolunteerPointsViewModel()

    private let products: [(name: String, icon: String)] = [
        ("运动腰包", "bag"),
        ("运动水壶", "waterbottle"),
        ("运动毛巾", "tshirt"),
        ("跑步腰灯", "flashlight.on.fill")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("--")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundColor(AppColors.textPrimary)
                    Text("积分")
                        .font(.headline)
                    Text("每完成一次服务 +100 积分")
                        .font(AppFonts.caption())
                        .foregroundColor(AppColors.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(AppColors.secondaryBackground)
                .cornerRadius(8)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("积分商城占位")

                VStack(spacing: 8) {
                    Image(systemName: "gift.fill")
                        .font(.system(size: 42))
                        .foregroundColor(AppColors.primary)
                    Text("积分商城即将上线，敬请期待")
                        .font(AppFonts.title())
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("积分商城即将上线，敬请期待")

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(products, id: \.name) { product in
                        VStack(spacing: 10) {
                            Image(systemName: product.icon)
                                .font(.title)
                                .foregroundColor(AppColors.primary)
                            Text(product.name)
                                .font(.headline)
                            Text("敬请期待")
                                .font(AppFonts.caption())
                                .foregroundColor(AppColors.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(AppColors.secondaryBackground)
                        .cornerRadius(8)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(product.name)，敬请期待")
                    }
                }

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .foregroundColor(AppColors.destructive)
                        .accessibilityLabel(errorMessage)
                }
            }
            .padding(20)
        }
        .navigationTitle("积分商城")
        .task {
            viewModel.configure(with: appState)
        }
    }
}

// MARK: - Settings

struct VolunteerSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var speechService: SpeechService
    @StateObject private var deletionViewModel = AccountDeletionViewModel()
    @State private var showLogoutConfirm = false
    @State private var showDeletionInitialConfirmation = false

    var body: some View {
        List {
            Section {
                settingsRow("昵称", value: appState.volunteerProfile?.name ?? "未填写")
                settingsRow("当前角色", value: "志愿者")
                settingsRow("资质审核", value: certificateState.displayName)
            }

            Section {
                NavigationLink("个人资料") {
                    VolunteerProfileView()
                }
                .accessibilityLabel("个人资料")
                .accessibilityHint("编辑志愿者资料")

                NavigationLink("资质证书") {
                    VolunteerCertificateUploadView()
                }
                .accessibilityLabel("资质证书，\(certificateState.displayName)")
                .accessibilityHint(certificateState.guidanceMessage)
                .accessibilityIdentifier("volunteerCertificateSettingsEntry")

                #if DEBUG
                if AppBuildChannel.current.allowsEnvironmentSwitcher {
                    Picker("API 环境", selection: $appState.currentEnvironment) {
                        ForEach(AppState.debugTestEnvironments, id: \.self) { environment in
                            Text(environment.displayName).tag(environment)
                        }
                    }
                    .accessibilityLabel("API 环境，\(appState.currentEnvironment.displayName)")
                }
                #endif

                NavigationLink("关于") {
                    AboutAidRunView()
                }
            }

            Section {
                Button("退出登录", role: .destructive) {
                    showLogoutConfirm = true
                }
                .accessibilityLabel("退出登录")
                .accessibilityHint("退出后需要重新登录，需要二次确认")

                Button("删除账户", role: .destructive) {
                    showDeletionInitialConfirmation = true
                }
                .disabled(appState.accountDeletionState == .inProgress)
                .accessibilityLabel("删除账户")
                .accessibilityHint("永久停用当前账户，需要再次确认")
            }

            if let message = deletionViewModel.preflightMessage {
                Section { Text(message).foregroundColor(AppColors.destructive).accessibilityLabel(message) }
            }
        }
        .navigationTitle("设置")
        .alert("确认退出", isPresented: $showLogoutConfirm) {
            Button("确认退出", role: .destructive) {
                Task { await appState.logout() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确认后将清除当前登录状态，返回登录页。")
        }
        .alert("确认删除账户", isPresented: $showDeletionInitialConfirmation) {
            Button("继续删除账户", role: .destructive) {
                Task {
                    await deletionViewModel.preflight(
                        appState: appState,
                        speechService: speechService
                    )
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("系统将先检查是否存在进行中的服务。检查通过后仍需再次确认，才会提交账户删除请求。")
        }
        .alert("最终确认删除账户", isPresented: $deletionViewModel.showFinalConfirmation) {
            Button("永久删除账户", role: .destructive) {
                Task { await appState.deleteCurrentAccount() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("账户将被软删除，所有登录令牌会失效。删除成功后手机号可以重新注册。此操作不可撤销。")
        }
    }

    /// 资料里的 `verificationStatus` 是后端 `VerificationStatus` 的四个取值之一；
    /// 尚未拉取到时按「状态未知」展示，不假装已提交或已通过。
    private var certificateState: VolunteerCertificateDisplayState {
        VolunteerCertificateDisplayState.from(
            status: VolunteerCertificateStatus.parse(appState.volunteerProfile?.verificationStatus),
            statusLoadFailed: false
        )
    }

    private func settingsRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(AppColors.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)：\(value)")
    }
}

/// 盲人端与志愿者端共用。法律条款入口放在这里，两个角色的设置页各挂一次「关于」即可覆盖。
struct AboutAidRunView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List {
            Section {
                Text("助盲跑 MVP")
                Text("iOS SwiftUI Demo")
                    .foregroundColor(AppColors.textSecondary)
            }

            LegalDocumentsSection(links: appState.legalLinks)
        }
        .navigationTitle("关于")
        // 进页面才拉，不在启动时打这个请求：它只影响这一页，而且失败了也有回退文案。
        .task { await appState.loadLegalLinksIfNeeded() }
    }
}

// MARK: - Reusable Views

struct VolunteerStatusBanner: View {
    let status: RunOrderStatus

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: status.statusSymbolName)
                .font(.title)
                .foregroundColor(status.statusColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(status.displayName)
                    .font(.headline)
                    .foregroundColor(AppColors.textPrimary)
                Text(status.volunteerDescription)
                    .font(AppFonts.caption())
                    .foregroundColor(AppColors.textSecondary)
            }
            Spacer()
        }
        .padding()
        .background(AppColors.secondaryBackground)
        .cornerRadius(8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(status.displayName)，\(status.volunteerDescription)")
    }
}

struct VolunteerOrderMap: View {
    @EnvironmentObject private var locationService: LocationService
    let order: OrderDetailResponse

    var body: some View {
        if let coordinate = orderCoordinate(order) {
            MapViewWrapper(
                centerCoordinate: coordinate,
                showsUserLocation: locationService.isAuthorized,
                annotations: [
                    MapAnnotationItem(
                        id: String(order.orderId),
                        coordinate: coordinate,
                        title: order.startAddress ?? "",
                        subtitle: order.blindName
                    )
                ],
                zoomLevel: 15
            )
            .frame(height: 210)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("地图，出发地点：\(order.startAddress ?? "地址待同步")")
            .accessibilityHint("地图用于视觉确认出发点；订单信息区域会读出地址和距离")
        }
    }
}

struct VolunteerServiceMapBackdrop: View {
    @EnvironmentObject private var locationService: LocationService
    let order: OrderDetailResponse
    let screenAnchor: CGPoint
    let peerSample: LocatedCoordinate?

    var body: some View {
        let presentation = VolunteerServiceMapPresentation(
            order: order,
            currentLocation: locationService.currentLocation,
            locationAuthorized: locationService.isAuthorized,
            fallbackCoordinate: locationService.effectiveBackendLocation,
            includesCurrentLocationMarker: false,
            centersOnCurrentAndStart: false
        )
        let peerAnnotations = peerSample.map { sample in
            [MapAnnotationItem(
                id: "associated-blind-runner",
                coordinate: sample.coordinate,
                title: "同行盲人跑者",
                subtitle: "位置刚刚更新",
                kind: .peer
            )]
        } ?? []
        MapViewWrapper(
            centerCoordinate: presentation.centerCoordinate,
            showsUserLocation: locationService.isAuthorized,
            annotations: presentation.annotations + peerAnnotations,
            zoomLevel: 15,
            screenAnchor: screenAnchor,
            tracksUserLocation: false,
            animatesCenterChanges: false
        )
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) {
            VolunteerMapLegend(
                showsCurrentLocation: presentation.isCurrentLocationAvailable,
                showsMissingLocationNotice: !presentation.isCurrentLocationAvailable
            )
            .padding(.top, 56)
            .padding(.horizontal, 16)
        }
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [.clear, Color.black.opacity(0.12)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 260)
            .allowsHitTesting(false)
        }
        .allowsHitTesting(false)
        .accessibilityLabel(
            presentation.isCurrentLocationAvailable
                ? "地图，显示我的位置和出发地点：\(order.startAddress ?? "地址待同步")"
                : "地图，出发地点：\(order.startAddress ?? "地址待同步")"
        )
        .accessibilityIdentifier("volunteerServiceMapBackdrop")
        .accessibilityHint("服务信息面板会读出出发地点和距离；同行位置过期后会自动隐藏")
    }
}

struct VolunteerMapLegend: View {
    let showsCurrentLocation: Bool
    let showsMissingLocationNotice: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsCurrentLocation {
                legendRow(color: .blue, title: "我的位置")
            } else if showsMissingLocationNotice {
                Text("定位不可用，仅显示出发地点")
                    .font(AppFonts.caption().weight(.semibold))
                    .foregroundColor(AppColors.warning)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel("定位不可用，仅显示出发地点")
            }

            legendRow(color: .red, title: "出发地点")
        }
        .accessibilityElement(children: .contain)
    }

    private func legendRow(color: Color, title: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(title)
                .font(AppFonts.caption().weight(.semibold))
                .foregroundColor(AppColors.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel(title)
    }
}

struct ExternalMapNavigationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: ExternalMapNavigationRequest

    private var providers: [ExternalMapNavigationProvider] {
        ExternalMapNavigationAvailability.availableProviders()
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(providers) { provider in
                        Button {
                            ExternalMapNavigationLauncher.open(provider: provider, request: request)
                            dismiss()
                        } label: {
                            Label(provider.displayName, systemImage: provider.systemImageName)
                                .font(AppFonts.body().weight(.semibold))
                        }
                        .accessibilityLabel("使用\(provider.displayName)导航到出发地点")
                        .accessibilityHint("打开外部地图进行步行导航")
                    }
                } footer: {
                    Text("默认使用步行导航。未安装的第三方地图不会显示。")
                }
            }
            .navigationTitle("选择地图导航")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct VolunteerServiceBottomPanel: View {
    let order: OrderDetailResponse
    let distanceText: String?
    let errorMessage: String?
    let transitionMessage: String?
    let isPerformingAction: Bool
    let transitionsDisabled: Bool
    let canRetryTransitionConfirmation: Bool
    let maxHeight: CGFloat
    let onNavigate: () -> Void
    let onEnRoute: () -> Void
    let onArrive: () -> Void
    let onStartService: () -> Void
    let onCancel: () -> Void
    let onComplete: () -> Void
    let onRetryTransitionConfirmation: () -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                VolunteerServiceStageHeader(status: order.status)
                VolunteerServiceRunnerCard(order: order)
                VolunteerServiceOrderEssentials(order: order, distanceText: distanceText)

                if let errorMessage {
                    Text(errorMessage)
                        .font(AppFonts.body())
                        .foregroundColor(AppColors.destructive)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(errorMessage)
                }

                if let transitionMessage {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(transitionMessage, systemImage: "clock.arrow.circlepath")
                            .font(AppFonts.body())
                            .foregroundColor(AppColors.warning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel(transitionMessage)
                        if canRetryTransitionConfirmation {
                            Button("重新确认状态", action: onRetryTransitionConfirmation)
                                .buttonStyle(.bordered)
                                .accessibilityHint("只重新查询订单状态，不会重复提交当前操作")
                        }
                    }
                }

                VolunteerServiceActions(
                    status: order.status,
                    isPerformingAction: isPerformingAction,
                    transitionsDisabled: transitionsDisabled,
                    onNavigate: onNavigate,
                    onEnRoute: onEnRoute,
                    onArrive: onArrive,
                    onStartService: onStartService,
                    onCancel: onCancel,
                    onComplete: onComplete,
                )
            }
            .padding(.horizontal, 22)
            .padding(.top, 26)
            .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: maxHeight)
        .background(AppColors.background)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Color.black.opacity(0.16), radius: 22, x: 0, y: -8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("volunteerServicePanel")
    }
}

struct VolunteerServiceStageHeader: View {
    let status: RunOrderStatus

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: status.statusSymbolName)
                    .foregroundColor(status.statusColor)
                    .accessibilityHidden(true)
                Text(status.volunteerServiceDisplayName)
                    .font(AppFonts.caption().weight(.semibold))
                    .foregroundColor(status.statusColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(status.statusColor.opacity(0.12))
            .cornerRadius(999)

            Text(status.serviceStageTitle)
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(AppColors.textPrimary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.72)
                .lineLimit(2)

            Text(status.serviceStageSubtitle)
                .font(AppFonts.body())
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(status.volunteerServiceDisplayName)，\(status.serviceStageTitle)，\(status.serviceStageSubtitle)")
    }
}

struct VolunteerServiceRunnerCard: View {
    @Environment(\.openURL) private var openURL
    let order: OrderDetailResponse

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.pink.opacity(0.18))
                Image(systemName: "person.fill")
                    .font(.title2)
                    .foregroundColor(.pink)
            }
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("盲人跑者")
                    .font(AppFonts.caption())
                    .foregroundColor(AppColors.textSecondary)
                Text(order.blindName ?? "盲人跑者")
                    .font(.title3.weight(.bold))
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 10)

            if let phone = order.blindPhone?.nilIfBlank {
                Button {
                    if let url = URL(string: "tel://\(phone)") {
                        openURL(url)
                    }
                } label: {
                    Label(phone, systemImage: "phone.fill")
                        .labelStyle(.titleAndIcon)
                        .font(AppFonts.body().weight(.semibold))
                        .foregroundColor(AppColors.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                .accessibilityLabel("拨打盲人电话 \(phone)")
            } else {
                Text("电话暂不可用")
                    .font(AppFonts.caption())
                    .foregroundColor(AppColors.textSecondary)
                    .accessibilityLabel("盲人电话暂不可用")
            }
        }
        .padding(16)
        .background(AppColors.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// 服务中面板的订单要点。**只被 `VolunteerServiceBottomPanel` 用**，那是接单之后的界面，
/// 所以这里的自由文本（路线备注 / 特殊说明）不加闸。
/// 要在接单前的界面复用它，先接 `RunOrderStatus.disclosesBlindRunnerNotesToVolunteer`。
struct VolunteerServiceOrderEssentials: View {
    let order: OrderDetailResponse
    let distanceText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            serviceRow(systemImage: "mappin.and.ellipse", title: "出发地点", value: order.startAddress ?? "")
            if let endAddress = order.endAddressForDisplay {
                serviceRow(systemImage: "flag.checkered", title: "结束地点", value: endAddress)
            }
            serviceRow(systemImage: "clock", title: "预约时间", value: (order.plannedStart ?? "").displayDateTime)

            if let distanceText {
                serviceRow(systemImage: "location", title: "当前位置距离", value: distanceText)
            }

            if let routeNotes = order.routeNotes?.nilIfBlank {
                serviceRow(systemImage: "point.topleft.down.curvedto.point.bottomright.up", title: "路线备注", value: routeNotes)
            }

            if let notes = order.specialNotes?.nilIfBlank {
                serviceRow(systemImage: "text.bubble", title: "特殊说明", value: notes)
            }
        }
        .padding(16)
        .background(AppColors.secondaryBackground.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func serviceRow(systemImage: String, title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundColor(AppColors.textPrimary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFonts.caption())
                    .foregroundColor(AppColors.textSecondary)
                Text(value)
                    .font(AppFonts.body())
                    .foregroundColor(AppColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)：\(value)")
    }
}

enum VolunteerServiceActionKind: Hashable {
    case navigateToStart
    case markEnRoute
    case markArrived
    case startService
    case cancelOrder
    case completeService
    case completedMessage
    case terminalMessage

    var title: String {
        switch self {
        case .navigateToStart:
            return "导航到出发地点"
        case .markEnRoute:
            return "我已出发"
        case .markArrived:
            return "我已到达约定地点"
        case .startService:
            return "开始服务"
        case .cancelOrder:
            return "取消订单"
        case .completeService:
            return "结束服务"
        case .completedMessage:
            return "服务完成，获得 +100 积分"
        case .terminalMessage:
            return "订单已结束"
        }
    }
}

struct VolunteerServiceActions: View {
    let status: RunOrderStatus
    let isPerformingAction: Bool
    let transitionsDisabled: Bool
    let onNavigate: () -> Void
    let onEnRoute: () -> Void
    let onArrive: () -> Void
    let onStartService: () -> Void
    let onCancel: () -> Void
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ForEach(Self.actionKinds(for: status), id: \.self) { action in
                actionView(action)
            }
        }
    }

    static func actionKinds(for status: RunOrderStatus) -> [VolunteerServiceActionKind] {
        switch status {
        case .pendingAccept:
            return [.navigateToStart, .markEnRoute, .cancelOrder]
        case .driverEnRoute:
            return [.navigateToStart, .markArrived, .cancelOrder]
        case .driverArrived:
            return [.startService, .cancelOrder]
        case .inProgress:
            return [.completeService, .cancelOrder]
        case .completed:
            return [.completedMessage]
        case .cancelled, .noVolunteer:
            return [.terminalMessage]
        case .pendingMatch, .rematching:
            return []
        // 认不出状态就一个按钮都不给：宁可让志愿者刷新，也不能在未知状态上放出取消/结束这类不可逆操作。
        case .unknown:
            return []
        }
    }

    @ViewBuilder
    private func actionView(_ action: VolunteerServiceActionKind) -> some View {
        switch action {
        case .navigateToStart:
            navigationButton(action: onNavigate)
        case .markEnRoute:
            PrimaryButton(action.title, isLoading: isPerformingAction, action: onEnRoute)
                .disabled(transitionsDisabled)
                .accessibilityLabel(action.title)
                .accessibilityHint("点击后通知盲人您正在前往")
        case .markArrived:
            PrimaryButton(action.title, isLoading: isPerformingAction, action: onArrive)
                .disabled(transitionsDisabled)
                .accessibilityLabel(action.title)
                .accessibilityHint("点击后通知盲人您已到达")
        case .startService:
            PrimaryButton(action.title, isLoading: isPerformingAction, action: onStartService)
                .disabled(transitionsDisabled)
                .accessibilityLabel(action.title)
                .accessibilityHint("点击后通知盲人服务已开始")
        case .cancelOrder:
            secondaryDangerButton(action.title, hint: "取消当前订单", action: onCancel)
        case .completeService:
            PrimaryButton(action.title, isDestructive: true, isLoading: isPerformingAction, action: onComplete)
                .disabled(transitionsDisabled)
                .accessibilityLabel(action.title)
                .accessibilityHint("需要使用二次确认")
        case .completedMessage:
            Text(action.title)
                .font(AppFonts.body().weight(.semibold))
                .foregroundColor(AppColors.success)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 64)
                .background(AppColors.success.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityLabel("服务完成，获得一百积分")
        case .terminalMessage:
            Text(status.volunteerDescription)
                .font(AppFonts.body().weight(.semibold))
                .foregroundColor(AppColors.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 64)
                .background(AppColors.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityLabel(status.volunteerDescription)
        }
    }

    private func navigationButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("导航到出发地点", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                .font(AppFonts.body().weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 52)
                .background(AppColors.primary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .accessibilityLabel("导航到出发地点")
        .accessibilityHint("选择高德、百度或苹果地图进行步行导航")
    }

    private func secondaryDangerButton(_ title: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Text(title)
                .font(AppFonts.body().weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 52)
                .background(AppColors.destructive.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(isPerformingAction)
        .accessibilityLabel(title)
        .accessibilityHint(hint)
    }
}

struct VolunteerBlindRunnerInfoCard: View {
    @Environment(\.openURL) private var openURL
    let order: OrderDetailResponse
    let showPhone: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("盲人跑者")
                .font(.headline)
                .foregroundColor(AppColors.textPrimary)
            Text(order.blindName ?? "盲人跑者")
                .font(AppFonts.body())
                .foregroundColor(AppColors.textPrimary)
                .accessibilityLabel("盲人：\(order.blindName ?? "")")

            if showPhone, let phone = order.blindPhone {
                Button {
                    if let url = URL(string: "tel://\(phone)") {
                        openURL(url)
                    }
                } label: {
                    Label(phone, systemImage: "phone.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityLabel("拨打盲人电话 \(phone)")
            } else {
                Text("联系方式将在接单后显示")
                    .font(AppFonts.caption())
                    .foregroundColor(AppColors.textSecondary)
                    .accessibilityLabel("联系方式将在接单后显示")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.secondaryBackground)
        .cornerRadius(8)
    }
}

struct VolunteerOrderInfoSection: View {
    let order: OrderDetailResponse
    let distanceText: String?

    /// 盲人填的自由文本（路线备注 / 特殊说明）只在**接单后**展示。判据集中在
    /// `RunOrderStatus.disclosesBlindRunnerNotesToVolunteer`（穷举 switch，含 `.unknown` 默认关），
    /// 不在这里就地写 `!= .pendingMatch` —— 这个视图的两个调用点里，
    /// `VolunteerOrderDetailView:921` 是从「可接订单」列表点进来的，那里的订单任何志愿者都能浏览。
    private var showsSensitiveNotes: Bool {
        order.status.disclosesBlindRunnerNotesToVolunteer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("订单信息")
                .font(.headline)
                .foregroundColor(AppColors.textPrimary)
            infoRow("出发地点", order.startAddress ?? "")
            if let endAddress = order.endAddressForDisplay {
                infoRow("结束地点", endAddress)
            }
            infoRow("预约时间", (order.plannedStart ?? "").displayDateTime)
            if let distanceText {
                infoRow("距离", distanceText)
            }
            if showsSensitiveNotes, let routeNotes = order.routeNotes?.nilIfBlank {
                infoRow("路线备注", routeNotes)
            }
            if let minutes = order.expectedDurationMinutes {
                infoRow("预计时长", "\(minutes) 分钟")
            }
            if let pace = order.pacePreference {
                infoRow("配速偏好", pace.displayName)
            }
            if let route = order.routePreference {
                infoRow("路线偏好", route.displayName)
            }
            if order.hasGuideDogThisRun == true {
                infoRow("导盲犬", "本次携带")
            }
            if showsSensitiveNotes, let notes = order.specialNotes?.nilIfBlank {
                infoRow("特殊说明", notes)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.secondaryBackground)
        .cornerRadius(8)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
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
}

struct VolunteerServiceRecordRow: View {
    let record: VolunteerServiceRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(record.sortKey.displayDateTime)
                    .font(.headline)
                Spacer()
                Text(record.order.status.displayName)
                    .font(AppFonts.caption().weight(.semibold))
                    .foregroundColor(record.order.status == .completed ? AppColors.success : AppColors.textSecondary)
            }
            Text("盲人：\(record.order.blindName ?? "")")
                .font(AppFonts.body())
            Text(record.order.startAddress ?? "")
                .font(AppFonts.caption())
                .foregroundColor(AppColors.textSecondary)
            Text(record.pointsText)
                .font(AppFonts.caption().weight(.semibold))
                .foregroundColor(record.order.status == .completed ? AppColors.success : AppColors.textSecondary)
        }
        .padding(.vertical, 4)
    }
}

struct VolunteerReadOnlyOrderView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var speechService: SpeechService
    @StateObject private var trackViewModel = CompletedTrackSummaryViewModel()
    let order: OrderDetailResponse

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VolunteerStatusBanner(status: order.status)
                VolunteerBlindRunnerInfoCard(order: order, showPhone: order.status != .pendingMatch && order.blindPhone?.trimmed.isEmpty == false)
                VolunteerOrderInfoSection(order: order, distanceText: nil)
                if order.status == .completed, let track = trackViewModel.track {
                    CompletedTrackSummaryView(track: track, orderID: order.orderId) {
                        speechService.speak(track.spokenSummary)
                    }
                } else if trackViewModel.isLoading {
                    ProgressView("正在加载本次路线")
                } else if let error = trackViewModel.errorMessage {
                    Text(error).foregroundColor(AppColors.textSecondary)
                }
            }
            .padding(20)
        }
        .navigationTitle("订单详情")
        .task {
            guard order.status == .completed else { return }
            await trackViewModel.load(orderID: order.orderId, appState: appState)
        }
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundColor(AppColors.textPrimary)
            Text(message)
                .font(AppFonts.body())
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，\(message)")
    }
}

// MARK: - Complete Service Sheet

struct CompleteServiceSheet: View {
    let isPerformingAction: Bool
    let onComplete: (String) async -> Void
    @State private var summaryText = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Text("服务已结束")
                    .font(.largeTitle.bold())
                    .foregroundColor(AppColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                Text("如果有需要记录的内容，可以在下方添加服务总结。")
                    .font(AppFonts.body())
                    .foregroundColor(AppColors.textSecondary)

                TextEditor(text: $summaryText)
                    .frame(minHeight: 120)
                    .padding(8)
                    .background(AppColors.secondaryBackground)
                    .cornerRadius(8)
                    .accessibilityLabel("服务总结，选填")
                    .accessibilityHint("可以记录本次服务的要点")

                PrimaryButton("确认完成服务", isLoading: isPerformingAction) {
                    Task { await onComplete(summaryText) }
                }
                .accessibilityLabel("确认完成服务")
                .accessibilityHint("确认后订单标记为已完成")

                Spacer()
            }
            .padding(24)
            .navigationTitle("结束服务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}
