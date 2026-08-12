import CoreLocation
import Foundation

struct TrackPoint: Codable, Sendable, Equatable, Identifiable {
    let lat: Double
    let lng: Double
    let recordedAt: String

    var id: String { "\(recordedAt):\(lat):\(lng)" }

    var backendCoordinate: LocatedCoordinate? {
        BackendCoordinateNormalizer.backend(latitude: lat, longitude: lng)
    }
}

struct TrackStats: Codable, Sendable, Equatable {
    let distanceMeters: Double?
    let durationSeconds: Int64?
    let avgPaceSecPerKm: Double?

    var distanceText: String? {
        guard let distanceMeters else { return nil }
        if distanceMeters >= 1_000 {
            return String(format: "%.2f 公里", distanceMeters / 1_000)
        }
        return "\(Int(distanceMeters.rounded())) 米"
    }

    var durationText: String? {
        guard let durationSeconds else { return nil }
        let minutes = durationSeconds / 60
        let seconds = durationSeconds % 60
        return minutes > 0 ? "\(minutes) 分 \(seconds) 秒" : "\(seconds) 秒"
    }

    var averagePaceText: String? {
        guard let avgPaceSecPerKm, avgPaceSecPerKm > 0 else { return nil }
        let totalSeconds = Int(avgPaceSecPerKm.rounded())
        return "\(totalSeconds / 60) 分 \(totalSeconds % 60) 秒每公里"
    }
}

struct OrderTrackResponse: Codable, Sendable, Equatable {
    let status: RunOrderStatus
    let volunteerTrack: [TrackPoint]
    let volunteerStats: TrackStats
    let blindTrack: [TrackPoint]
    let blindStats: TrackStats

    var primaryRouteCoordinates: [CLLocationCoordinate2D] {
        blindTrack.compactMap { $0.backendCoordinate?.coordinate }
    }

    /// 轨迹外接矩形的中心，给地图当 `centerCoordinate` 用。
    ///
    /// **不能传起点。** `AMapContainer` 一边在折线落地时 fit 到外接矩形
    /// （`AMapContainer.swift:185-192`），一边在每次 `updateUIView` 里把地图中心拉回传入坐标
    /// （`:102-110`，阈值 1e-4 度）。传起点的话后者会持续覆盖前者，
    /// 结果是路线只剩起点附近一小段留在屏幕上 —— 看起来就像「轨迹没画出来」。
    ///
    /// 用经纬度算术中心而不是 `MAMapRect` 的墨卡托中心：两者的纬度差在城市尺度下约 1e-5 度，
    /// 比上面那个阈值小一个数量级，够不着触发条件。
    var primaryRouteBoundingCenter: CLLocationCoordinate2D? {
        let coordinates = primaryRouteCoordinates
        guard let first = coordinates.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLng = first.longitude, maxLng = first.longitude
        for point in coordinates.dropFirst() {
            minLat = min(minLat, point.latitude)
            maxLat = max(maxLat, point.latitude)
            minLng = min(minLng, point.longitude)
            maxLng = max(maxLng, point.longitude)
        }
        return CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLng + maxLng) / 2
        )
    }

    var emptyStateText: String? {
        guard blindTrack.count < 2 else { return nil }
        switch status {
        case .pendingMatch, .pendingAccept, .driverEnRoute, .driverArrived, .rematching, .noVolunteer:
            return "本次路线尚未开始。"
        case .inProgress:
            return "本次路线仍在采集，暂时没有足够的轨迹点。"
        case .completed, .cancelled:
            return blindTrack.isEmpty
                ? "该历史订单暂无轨迹。"
                : "本次轨迹点不足，暂时无法绘制路线。"
        // 认不出状态时不猜「尚未开始」还是「已结束」，只陈述看得见的事实。
        case .unknown:
            return "暂时没有足够的轨迹点。"
        }
    }

    var spokenSummary: String {
        if let emptyStateText { return emptyStateText }
        var parts = ["本次路线"]
        if let value = blindStats.distanceText { parts.append("里程 \(value)") }
        if let value = blindStats.durationText { parts.append("时长 \(value)") }
        if let value = blindStats.averagePaceText { parts.append("平均配速 \(value)") }
        return parts.joined(separator: "，") + "。"
    }
}
