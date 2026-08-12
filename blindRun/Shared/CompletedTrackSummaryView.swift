import Combine
import SwiftUI

@MainActor
final class CompletedTrackSummaryViewModel: ObservableObject {
    @Published private(set) var track: OrderTrackResponse?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    func load(orderID: Int64, appState: AppState) async {
        isLoading = true
        errorMessage = nil
        do {
            let response: OrderTrackResponse = try await appState.apiClient.get("/api/orders/\(orderID)/track")
            track = response
        } catch let error as APIError {
            if !appState.handleAuthenticatedAPIError(error) {
                errorMessage = "本次路线暂时无法加载。"
            }
        } catch {
            errorMessage = "本次路线暂时无法加载。"
        }
        isLoading = false
    }
}

/// 订单详情里内嵌的轨迹摘要 —— 对标 Strava 列表页那个压缩版式（窄地图 + 一行统计），
/// 大屏回放在 `OrderRouteReplayView`，由下面那条链接进入。
struct CompletedTrackSummaryView: View {
    let track: OrderTrackResponse
    let orderID: Int64
    let repeatSummary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("本次路线")
                .font(AppFonts.title())
                .accessibilityAddTraits(.isHeader)

            if let emptyText = track.emptyStateText {
                Text(emptyText).font(AppFonts.body())
            } else {
                TrackRouteMap(track: track)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilitySortPriority(-1)
                    .accessibilityIdentifier("completedTrackAuxiliaryMap")

                TrackStatsRow(stats: track.blindStats)

                // 独立成行而不是把地图本身做成链接：`MAMapView` 自己吃掉平移手势，
                // 包在 NavigationLink 里点不动。这一行同时也是读屏用户唯一能对上的入口。
                NavigationLink {
                    OrderRouteReplayView(orderID: orderID, preloadedTrack: track)
                } label: {
                    Label("查看大图路线", systemImage: "map")
                        .font(AppFonts.body())
                }
                .frame(minHeight: 44)
                .accessibilityHint("全屏查看本次跑步轨迹")
                .accessibilityIdentifier("completedTrackFullScreenLink")
            }

            Button("重复当前状态", action: repeatSummary)
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 64)
                .accessibilityHint("朗读本次路线的里程、时长和平均配速")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("completedTrackSummary")
    }
}
