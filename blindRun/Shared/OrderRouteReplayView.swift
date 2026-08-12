import CoreLocation
import SwiftUI

// MARK: - Route Map

/// 已完成订单的轨迹地图。订单详情内嵌、全屏回放、盲人跑步记录三个入口共用一份，
/// 起终点标记和视口对齐只写在这里 —— 此前「志愿者服务记录有轨迹、近期服务没有」
/// 正是因为两个详情页各写各的（见 `docs/research/run-track-replay-ui-20260812.md` §3）。
///
/// 地图中心取的是轨迹外接矩形的中心而非起点，理由见
/// `OrderTrackResponse.primaryRouteBoundingCenter` 的注释 —— 传起点会让路线跑出屏幕。
struct TrackRouteMap: View {
    let track: OrderTrackResponse

    var body: some View {
        let coordinates = track.primaryRouteCoordinates
        if coordinates.count >= 2,
           let center = track.primaryRouteBoundingCenter,
           let start = coordinates.first,
           let end = coordinates.last {
            MapViewWrapper(
                centerCoordinate: center,
                showsUserLocation: false,
                annotations: [
                    MapAnnotationItem(id: "route-start", coordinate: start, title: "起点", subtitle: nil, kind: .routeStart),
                    MapAnnotationItem(id: "route-end", coordinate: end, title: "终点", subtitle: nil, kind: .routeEnd)
                ],
                polylines: [MapPolylineItem(id: "blind-primary-route", coordinates: coordinates, isPrimary: true)],
                tracksUserLocation: false,
                animatesCenterChanges: false
            )
            .accessibilityIdentifier("trackRouteMap")
        }
    }
}

// MARK: - Stats

/// 里程 / 时长 / 平均配速三列并排，数字大、标签小在下 —— 对标悦跑圈与 Strava 的活动详情页
/// （`docs/research/run-track-replay-ui-20260812.md` §2）。
///
/// 两点没有跟着对标产品照抄：
/// - **无障碍标签按「标签 值」的语序**。视觉是「值在上、标签在下」，
///   `children: .combine` 会照着视觉顺序读成「10.44 公里 里程」，语序是反的。
/// - **辅助功能字号下换成竖排**，不靠 `minimumScaleFactor` 压字。
///   缩字正是低视力用户最不需要的处理（见记忆 `low-vision-visual-channel-unaudited`）。
struct TrackStatsRow: View {
    let stats: TrackStats

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var items: [(label: String, value: String)] {
        var result: [(label: String, value: String)] = []
        if let value = stats.distanceText { result.append(("里程", value)) }
        if let value = stats.durationText { result.append(("时长", value)) }
        if let value = stats.averagePaceText { result.append(("平均配速", value)) }
        return result
    }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 8))

        layout {
            ForEach(items, id: \.label) { item in
                VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .center, spacing: 4) {
                    Text(item.value)
                        .font(.title3.weight(.bold))
                        .foregroundColor(AppColors.textPrimary)
                    Text(item.label)
                        .font(AppFonts.caption())
                        .foregroundColor(AppColors.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .center)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.label) \(item.value)")
            }
        }
    }
}

// MARK: - Full Screen Replay

/// 「大屏地图」回放页：地图占满统计卡片以外的全部高度，对标同类产品把地图放在
/// 顶部 35–45% 的做法，我们没有社交/海拔那几块内容，所以给得更满。
///
/// 数据来源二选一：调用方已经拉过轨迹就把 `preloadedTrack` 传进来，
/// 否则自己按 `orderID` 拉一次。合成一个类型是为了不让「订单详情点进来」
/// 和「跑步记录点进来」再次分叉成两份实现 —— 那正是这个功能一开始只做了一半的原因。
struct OrderRouteReplayView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var speechService: SpeechService
    @StateObject private var viewModel = CompletedTrackSummaryViewModel()

    let orderID: Int64
    var preloadedTrack: OrderTrackResponse?

    private var track: OrderTrackResponse? { preloadedTrack ?? viewModel.track }

    var body: some View {
        VStack(spacing: 0) {
            content
            if let track {
                summaryCard(track)
            }
        }
        .background(AppColors.background)
        .navigationTitle("本次路线")
        .navigationBarTitleDisplayMode(.inline)
        // `children: .contain` 不能省。`accessibilityIdentifier` 加在容器上会**向下覆盖**
        // 每个子元素的标识符：2026-08-12 实测这一页的按钮和三个统计格全部变成了
        // `orderRouteReplay`，`app.buttons["routeReplayRepeatStatus"]` 因此永远落空。
        // `CompletedTrackSummaryView` 一直没踩到，就是因为它本来就写了这一行。
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("orderRouteReplay")
        .task {
            guard preloadedTrack == nil else { return }
            await viewModel.load(orderID: orderID, appState: appState)
            if let summary = viewModel.track?.spokenSummary {
                speechService.speak(summary)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let track {
            if let emptyText = track.emptyStateText {
                centeredMessage(emptyText)
            } else {
                // ponytail: 地图吃掉统计卡片以外的全部高度，下限 200pt。
                // 上限交给布局而不是写死屏高比例 —— 写比例要引 GeometryReader 重排整页，
                // 而 AX5 字号下统计卡片本来就该往上挤地图。
                TrackRouteMap(track: track)
                    .frame(minHeight: 200, maxHeight: .infinity)
            }
        } else if viewModel.isLoading {
            centeredMessage("正在加载本次路线")
        } else if let error = viewModel.errorMessage {
            centeredMessage(error)
        } else {
            centeredMessage("本次路线暂时无法加载。")
        }
    }

    private func centeredMessage(_ text: String) -> some View {
        VStack {
            Spacer(minLength: 0)
            Text(text)
                .font(AppFonts.body())
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .accessibilityLabel(text)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func summaryCard(_ track: OrderTrackResponse) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if track.emptyStateText == nil {
                TrackStatsRow(stats: track.blindStats)
            }

            // 地图对看不见的人是零信息。这个按钮是他们拿到里程/时长/配速的唯一通道，
            // 所以它跟随页面本身存在，不跟随地图画没画出来。
            // 标识符**直接挂在 Button 上**，放在 `.frame` 外面时 XCUITest 找不到
            // （`app.buttons["routeReplayRepeatStatus"]` 落空，2026-08-12 实测）——
            // `.frame(maxWidth:)` 会包一层布局容器，标识符落到容器而不是按钮元素上。
            Button("重复当前状态") {
                speechService.speak(track.spokenSummary)
            }
            .accessibilityIdentifier("routeReplayRepeatStatus")
            .accessibilityHint("朗读本次路线的里程、时长和平均配速")
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, minHeight: 64)
        }
        .padding(20)
        .background(AppColors.secondaryBackground)
    }
}
