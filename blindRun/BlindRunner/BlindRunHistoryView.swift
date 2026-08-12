import Combine
import SwiftUI

// MARK: - View Model

/// 盲人端的历史跑步记录。此前**整条路都不存在** —— `/api/orders/mine` 只被首页用来
/// 找当前进行中的那一单（`BlindRunnerHomeView.swift:165-169`），订单一旦完成就再也回不去，
/// 于是 `BlindOrderStatusView` 里那段已完成轨迹实际上只在「跑完那一刻恰好还停在该页」时露过面。
@MainActor
final class BlindRunHistoryViewModel: ObservableObject {
    @Published private(set) var records: [OrderDetailResponse] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

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
            // 只留已完成：这一页的名字是「跑步记录」，而取消掉的订单没有轨迹可看。
            // 未知状态一并排除 —— 后端新增状态时把它当成「跑过了」是在替用户下结论。
            records = paged.content
                .filter { $0.status == .completed }
                .sorted { ($0.createdAt ?? $0.plannedStart ?? "") > ($1.createdAt ?? $1.plannedStart ?? "") }
            isLoading = false
        } catch let error as APIError {
            isLoading = false
            if appState.handleAuthenticatedAPIError(error) { return }
            errorMessage = error.localizedMessage
            speechService?.speakError(error.localizedMessage)
        } catch {
            isLoading = false
            let message = "加载失败，下拉重试"
            errorMessage = message
            speechService?.speakError(message)
        }
    }
}

// MARK: - List

struct BlindRunHistoryView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var speechService: SpeechService
    @StateObject private var viewModel = BlindRunHistoryViewModel()

    var body: some View {
        List {
            if viewModel.isLoading {
                ProgressView("正在加载跑步记录...")
                    .accessibilityLabel("正在加载跑步记录")
            } else if viewModel.records.isEmpty {
                EmptyStateView(title: "暂无跑步记录", message: "完成一次陪跑后，这里会显示当时的路线。")
            } else {
                ForEach(viewModel.records, id: \.orderId) { order in
                    NavigationLink {
                        OrderRouteReplayView(orderID: order.orderId)
                    } label: {
                        BlindRunHistoryRow(order: order)
                    }
                    .accessibilityHint("查看这次陪跑的路线、里程和用时")
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundColor(AppColors.destructive)
                    .accessibilityLabel(errorMessage)
            }
        }
        .navigationTitle("我的跑步记录")
        .accessibilityIdentifier("blindRunHistoryList")
        .task {
            viewModel.configure(with: appState, speechService: speechService)
            await viewModel.load()
        }
        .refreshable {
            await viewModel.load()
        }
    }
}

private struct BlindRunHistoryRow: View {
    let order: OrderDetailResponse

    private var dateText: String {
        (order.createdAt ?? order.plannedStart ?? "").displayDateTime
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(dateText)
                .font(AppFonts.body().weight(.semibold))
                .foregroundColor(AppColors.textPrimary)
            Text(order.startAddress ?? "地点未记录")
                .font(AppFonts.caption())
                .foregroundColor(AppColors.textSecondary)
        }
        .padding(.vertical, 4)
        // 行里不放里程 —— 那要为每一行单独打一次 `/track`。
        // ponytail: 需要的话再让后端在列表响应里带上，不在客户端拿 N 个请求换一行小字。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(dateText)，出发地 \(order.startAddress ?? "未记录")")
    }
}
