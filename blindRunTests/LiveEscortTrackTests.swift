import Combine
import CoreLocation
import XCTest
@testable import blindRun

final class LiveEscortTrackTests: XCTestCase {
    func testWGS84BeijingConvertsToKnownGCJ02Coordinate() throws {
        let sample = LocatedCoordinate(
            coordinate: CLLocationCoordinate2D(latitude: 39.908823, longitude: 116.397470),
            system: .wgs84Device,
            capturedAt: Date(timeIntervalSince1970: 100)
        )
        let normalized = try XCTUnwrap(BackendCoordinateNormalizer.normalize(sample))
        XCTAssertEqual(normalized.coordinate.latitude, 39.910226, accuracy: 0.00001)
        XCTAssertEqual(normalized.coordinate.longitude, 116.403714, accuracy: 0.00001)
        XCTAssertEqual(normalized.system, .gcj02Backend)
        XCTAssertEqual(normalized.capturedAt, sample.capturedAt)
    }

    func testOverseasDeviceCoordinateIsNotShifted() throws {
        let paris = CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)
        let normalized = try XCTUnwrap(BackendCoordinateNormalizer.normalize(
            LocatedCoordinate(coordinate: paris, system: .wgs84Device)
        ))
        XCTAssertEqual(normalized.coordinate.latitude, paris.latitude, accuracy: 0.0000001)
        XCTAssertEqual(normalized.coordinate.longitude, paris.longitude, accuracy: 0.0000001)
    }

    func testBackendGCJ02IsNeverConvertedTwice() throws {
        let gcj = CLLocationCoordinate2D(latitude: 39.910226, longitude: 116.403714)
        let normalized = try XCTUnwrap(BackendCoordinateNormalizer.normalize(
            LocatedCoordinate(coordinate: gcj, system: .gcj02Backend)
        ))
        XCTAssertEqual(normalized.coordinate.latitude, gcj.latitude)
        XCTAssertEqual(normalized.coordinate.longitude, gcj.longitude)
    }

    func testFlatProductionAppNotificationDecodesOuterIdentityAndBody() throws {
        let data = try XCTUnwrap(#"{"type":"APP_NOTIFICATION","messageId":"7D42C6B2-54C8-4609-8B46-C465C2B443C0","eventType":"ESCORT_DISTANCE_ALERT","timestamp":"2026-07-21T08:00:00Z","body":"与志愿者的距离似乎有点远","ttsText":"你和志愿者的距离似乎有点远，请留在原地，志愿者正在确认位置","priority":"HIGH"}"#.data(using: .utf8))
        let message = try JSONDecoder().decode(WSAppNotification.self, from: data)
        XCTAssertEqual(message.type, "APP_NOTIFICATION")
        XCTAssertEqual(message.messageId, "7D42C6B2-54C8-4609-8B46-C465C2B443C0")
        XCTAssertEqual(message.eventType, "ESCORT_DISTANCE_ALERT")
        XCTAssertEqual(message.body, "与志愿者的距离似乎有点远")
        XCTAssertEqual(message.timestamp, "2026-07-21T08:00:00Z")
    }

    @MainActor
    func testAlertWithoutOrderIDRequiresOneInProgressOrderAndDeduplicatesMessageID() {
        let coordinator = AppRealtimeCoordinator(notificationDuration: 60)
        let service = WebSocketService()
        coordinator.attach(to: service, role: .blind)
        coordinator.registerActiveOrder(42, status: .inProgress)
        let message = WSAppNotification(
            type: WSMessageType.appNotification.rawValue,
            eventId: nil,
            messageId: "7D42C6B2-54C8-4609-8B46-C465C2B443C0",
            eventType: "ESCORT_SIGNAL_LOST",
            title: nil,
            body: "暂时无法获取对方位置，正在为你确认安全",
            ttsText: "暂时无法获取志愿者位置，请留在原地，我们正在为你确认安全",
            priority: "HIGH",
            timestamp: "2026-07-21T08:00:00Z"
        )
        coordinator.simulateIncomingEventForTesting(.notification(message))
        coordinator.simulateIncomingEventForTesting(.notification(message))
        XCTAssertEqual(coordinator.latestSeparationAlert?.orderID, 42)
        XCTAssertEqual(coordinator.latestSeparationAlert?.eventType, "ESCORT_SIGNAL_LOST")
        XCTAssertEqual(coordinator.currentNotification?.stableEventID, "escort:7D42C6B2-54C8-4609-8B46-C465C2B443C0")
    }

    @MainActor
    func testSafetyLookingNotificationIsNotShownWithoutExactlyOneInProgressOrder() {
        let coordinator = AppRealtimeCoordinator(notificationDuration: 60)
        let service = WebSocketService()
        coordinator.attach(to: service, role: .blind)
        coordinator.registerActiveOrder(42, status: .completed)
        coordinator.simulateIncomingEventForTesting(.notification(WSAppNotification(
            type: WSMessageType.appNotification.rawValue,
            eventId: nil,
            messageId: "1F7C8719-0AB3-4F19-949C-5E966307350B",
            eventType: "ESCORT_DISTANCE_ALERT",
            title: nil,
            body: "与志愿者的距离似乎有点远",
            ttsText: "你和志愿者的距离似乎有点远，请留在原地，志愿者正在确认位置",
            priority: "HIGH",
            timestamp: "2026-07-21T08:00:00Z"
        )))
        XCTAssertNil(coordinator.currentNotification)
        XCTAssertNil(coordinator.latestSeparationAlert)
    }

    @MainActor
    func testEventTypeRoutesSafetyWithoutDependingOnDisplayCopy() {
        let coordinator = AppRealtimeCoordinator(notificationDuration: 60)
        let service = WebSocketService()
        coordinator.attach(to: service, role: .volunteer)
        coordinator.registerActiveOrder(84, status: .inProgress)

        coordinator.simulateIncomingEventForTesting(.notification(WSAppNotification(
            type: WSMessageType.appNotification.rawValue,
            eventId: nil,
            messageId: "B244E7BD-AECB-46B7-8330-615EF1988D17",
            eventType: "ESCORT_DISTANCE_ALERT",
            title: nil,
            body: "后端未来调整后的安全展示文案",
            ttsText: "后端未来调整后的安全朗读文案",
            priority: "HIGH",
            timestamp: "2026-07-21T08:00:01Z"
        )))
        XCTAssertEqual(coordinator.latestSeparationAlert?.eventType, "ESCORT_DISTANCE_ALERT")
        XCTAssertEqual(coordinator.currentNotification?.stableEventID, "escort:B244E7BD-AECB-46B7-8330-615EF1988D17")
    }

    @MainActor
    func testAllFourFrozenRoleSpecificEscortTemplatesRoute() {
        let cases: [(WSRole, String, String, String)] = [
            (
                .blind,
                "与志愿者的距离似乎有点远",
                "你和志愿者的距离似乎有点远，请留在原地，志愿者正在确认位置",
                "ESCORT_DISTANCE_ALERT"
            ),
            (
                .volunteer,
                "与盲人用户的距离似乎有点远",
                "你和盲人用户的距离似乎有点远，请尽快确认对方位置",
                "ESCORT_DISTANCE_ALERT"
            ),
            (
                .blind,
                "暂时无法获取对方位置，正在为你确认安全",
                "暂时无法获取志愿者位置，请留在原地，我们正在为你确认安全",
                "ESCORT_SIGNAL_LOST"
            ),
            (
                .volunteer,
                "暂时无法获取对方位置，正在为你确认安全",
                "暂时无法获取盲人用户位置，请尽快确认对方安全",
                "ESCORT_SIGNAL_LOST"
            )
        ]

        let messageIDs = [
            "00A66495-F821-4FF2-B08F-6BB3F49C6364",
            "4BB9E3C1-C78F-42D7-9EA8-1CEDCAEB32F0",
            "51498EE6-CF31-49D2-A341-A5D8583B8AD2",
            "F571EEA9-933B-4A6F-9DB0-F9A25024D347"
        ]
        for (index, item) in cases.enumerated() {
            let coordinator = AppRealtimeCoordinator(notificationDuration: 60)
            coordinator.attach(to: WebSocketService(), role: item.0)
            coordinator.registerActiveOrder(100 + Int64(index), status: .inProgress)
            coordinator.simulateIncomingEventForTesting(.notification(WSAppNotification(
                type: WSMessageType.appNotification.rawValue,
                eventId: nil,
                messageId: messageIDs[index],
                eventType: item.3,
                title: nil,
                body: item.1,
                ttsText: item.2,
                priority: "HIGH",
                timestamp: "2026-07-21T08:00:00Z"
            )))
            XCTAssertEqual(coordinator.latestSeparationAlert?.eventType, item.3)
            XCTAssertEqual(coordinator.currentNotification?.displayText, item.1)
            XCTAssertEqual(coordinator.currentNotification?.speechText, item.2)
        }
    }

    @MainActor
    func testWrongOrderPeerLocationIsRejected() async {
        let realtime = AppRealtimeCoordinator()
        let service = WebSocketService()
        realtime.attach(to: service, role: .volunteer)
        service.simulateIncomingEventForTesting(.blindLocation(WSBlindLocationUpdate(
            type: "BLIND_LOCATION_UPDATE", orderId: 5, lat: 39.9, lng: 116.4,
            timestamp: Int64(Date().timeIntervalSince1970 * 1_000)
        )))
        await Task.yield()
        XCTAssertNil(realtime.latestPeerLocation(orderID: 5, ownerRole: .blind))

        realtime.registerActiveOrder(5, status: .inProgress)
        service.simulateIncomingEventForTesting(.blindLocation(WSBlindLocationUpdate(
            type: "BLIND_LOCATION_UPDATE", orderId: 6, lat: 39.9, lng: 116.4,
            timestamp: Int64(Date().timeIntervalSince1970 * 1_000)
        )))
        await Task.yield()
        XCTAssertNil(realtime.latestPeerLocation(orderID: 5, ownerRole: .blind))

        service.simulateIncomingEventForTesting(.blindLocation(WSBlindLocationUpdate(
            type: "BLIND_LOCATION_UPDATE", orderId: 5, lat: 39.9, lng: 116.4,
            timestamp: Int64(Date().timeIntervalSince1970 * 1_000)
        )))
        await Task.yield()
        XCTAssertNotNil(realtime.latestPeerLocation(orderID: 5, ownerRole: .blind))
    }

    func testTrackDecodesPartialStatsAndUsesBlindTrackAsPrimaryRoute() throws {
        let json = #"{"status":"COMPLETED","volunteerTrack":[{"lat":39.91,"lng":116.41,"recordedAt":"2026-07-21T08:00:00Z"},{"lat":39.92,"lng":116.42,"recordedAt":"2026-07-21T08:01:00Z"}],"volunteerStats":{"distanceMeters":null,"durationSeconds":null,"avgPaceSecPerKm":null},"blindTrack":[{"lat":39.90,"lng":116.40,"recordedAt":"2026-07-21T08:00:00Z"},{"lat":39.905,"lng":116.405,"recordedAt":"2026-07-21T08:05:00Z"}],"blindStats":{"distanceMeters":820,"durationSeconds":1440,"avgPaceSecPerKm":1756}}"#
        let response = try JSONDecoder().decode(OrderTrackResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.primaryRouteCoordinates.count, 2)
        XCTAssertEqual(response.primaryRouteCoordinates.first?.latitude, 39.90)
        XCTAssertEqual(response.blindStats.distanceText, "820 米")
        XCTAssertTrue(response.spokenSummary.contains("平均配速"))
        XCTAssertNil(response.volunteerStats.distanceText)
    }

    func testEmptyTrackMessageUsesStatusWithoutInventingAnomaly() {
        let response = OrderTrackResponse(
            status: .inProgress,
            volunteerTrack: [],
            volunteerStats: TrackStats(distanceMeters: 0, durationSeconds: 0, avgPaceSecPerKm: nil),
            blindTrack: [],
            blindStats: TrackStats(distanceMeters: 0, durationSeconds: 0, avgPaceSecPerKm: nil)
        )
        XCTAssertEqual(response.emptyStateText, "本次路线仍在采集，暂时没有足够的轨迹点。")
        XCTAssertFalse(response.spokenSummary.contains("异常"))
    }

    func testSingleRawTrackPointIsRetainedButNotDrawable() throws {
        let json = #"{"status":"COMPLETED","volunteerTrack":[],"volunteerStats":{"distanceMeters":0,"durationSeconds":0,"avgPaceSecPerKm":null},"blindTrack":[{"lat":39.90,"lng":116.40,"recordedAt":"2026-07-21T08:00:00Z"}],"blindStats":{"distanceMeters":0,"durationSeconds":0,"avgPaceSecPerKm":null}}"#
        let response = try JSONDecoder().decode(OrderTrackResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.blindTrack.count, 1)
        XCTAssertEqual(response.primaryRouteCoordinates.count, 1)
        XCTAssertEqual(response.emptyStateText, "本次轨迹点不足，暂时无法绘制路线。")
        XCTAssertEqual(response.blindStats.distanceMeters, 0)
        XCTAssertEqual(response.blindStats.durationSeconds, 0)
        XCTAssertNil(response.blindStats.avgPaceSecPerKm)
    }

    /// 地图中心必须是外接矩形中心，不能是起点 —— 传起点时 `AMapContainer` 的重定位
    /// 会持续覆盖折线的 fit，路线跑出屏幕，现象就是「点进去看不到轨迹」。
    /// 这条钉的是「中心不等于起点，且落在轨迹的经纬度跨度之内」。
    func testPrimaryRouteBoundingCenterIsRouteCenterNotStartPoint() throws {
        let json = #"{"status":"COMPLETED","volunteerTrack":[],"volunteerStats":{"distanceMeters":null,"durationSeconds":null,"avgPaceSecPerKm":null},"blindTrack":[{"lat":39.900,"lng":116.400,"recordedAt":"2026-07-21T08:00:00Z"},{"lat":39.940,"lng":116.470,"recordedAt":"2026-07-21T08:10:00Z"},{"lat":39.920,"lng":116.500,"recordedAt":"2026-07-21T08:20:00Z"}],"blindStats":{"distanceMeters":5200,"durationSeconds":1200,"avgPaceSecPerKm":230}}"#
        let response = try JSONDecoder().decode(OrderTrackResponse.self, from: Data(json.utf8))
        let center = try XCTUnwrap(response.primaryRouteBoundingCenter)
        let start = try XCTUnwrap(response.primaryRouteCoordinates.first)

        // 纬度跨度 39.900–39.940，经度跨度 116.400–116.500
        XCTAssertEqual(center.latitude, 39.920, accuracy: 1e-9)
        XCTAssertEqual(center.longitude, 116.450, accuracy: 1e-9)

        // `AMapContainer` 的重定位阈值是 1e-4 度；中心与起点的差必须**大于**它，
        // 否则这个属性等于没做事。
        XCTAssertGreaterThan(abs(center.latitude - start.latitude), 1e-4)
        XCTAssertGreaterThan(abs(center.longitude - start.longitude), 1e-4)
    }

    func testBoundingCenterIsNilForEmptyTrackAndExactForSinglePoint() throws {
        let empty = OrderTrackResponse(
            status: .completed,
            volunteerTrack: [],
            volunteerStats: TrackStats(distanceMeters: nil, durationSeconds: nil, avgPaceSecPerKm: nil),
            blindTrack: [],
            blindStats: TrackStats(distanceMeters: nil, durationSeconds: nil, avgPaceSecPerKm: nil)
        )
        XCTAssertNil(empty.primaryRouteBoundingCenter)

        let single = OrderTrackResponse(
            status: .completed,
            volunteerTrack: [],
            volunteerStats: TrackStats(distanceMeters: nil, durationSeconds: nil, avgPaceSecPerKm: nil),
            blindTrack: [TrackPoint(lat: 39.9, lng: 116.4, recordedAt: "2026-07-21T08:00:00Z")],
            blindStats: TrackStats(distanceMeters: nil, durationSeconds: nil, avgPaceSecPerKm: nil)
        )
        let center = try XCTUnwrap(single.primaryRouteBoundingCenter)
        XCTAssertEqual(center.latitude, 39.9, accuracy: 1e-9)
        XCTAssertEqual(center.longitude, 116.4, accuracy: 1e-9)
    }

    func testPolylineIdentityAndSignatureAreStable() {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 39.9, longitude: 116.4),
            CLLocationCoordinate2D(latitude: 39.91, longitude: 116.41)
        ]
        let first = MapPolylineItem(id: "blind-primary-route", coordinates: coordinates, isPrimary: true)
        let second = MapPolylineItem(id: "blind-primary-route", coordinates: coordinates, isPrimary: true)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.signature, second.signature)
        XCTAssertTrue(first.isPrimary)
    }

    @MainActor
    func testBothRolesHeartbeatAndCollisionQueuePreservesMessages() {
        XCTAssertTrue(WebSocketService.shouldStartHeartbeat(for: .blind))
        XCTAssertTrue(WebSocketService.shouldStartHeartbeat(for: .volunteer))
        XCTAssertTrue(WSConnectionState.connecting.canSendOrQueueMessages)
        XCTAssertTrue(WSConnectionState.connected.canSendOrQueueMessages)
        XCTAssertFalse(WSConnectionState.reconnecting(attempt: 1).canSendOrQueueMessages)
        XCTAssertFalse(WSConnectionState.disconnected.canSendOrQueueMessages)
        let base = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(
            WebSocketService.requiredSendDelay(lastSend: base, now: base.addingTimeInterval(0.1)),
            0.4,
            accuracy: 0.0001
        )
        let service = WebSocketService()
        service.simulateQueuedMessagesForTesting(count: 2)
        XCTAssertEqual(service.queuedMessageCountForTesting, 2)
        service.disconnect()
        XCTAssertEqual(service.queuedMessageCountForTesting, 0)
    }

    @MainActor
    func testConnectingLocationQueueRetainsOnlyLatestSampleWithoutDroppingReliableMessages() {
        let service = WebSocketService()
        service.simulateQueuedMessagesForTesting(count: 2)
        service.simulateLocationUpdatesForTesting([
            (39.90, 116.40),
            (39.91, 116.41),
            (39.92, 116.42)
        ])
        XCTAssertEqual(
            service.queuedMessageCountForTesting,
            3,
            "Two reliable messages plus only the latest location must remain queued"
        )
        service.disconnect()
        XCTAssertEqual(service.queuedMessageCountForTesting, 0)
    }

    @MainActor
    func testSessionLifecycleEnablesBackgroundOnlyInProgressAndClearsOnTerminalOrIdentityChange() async {
        let realtime = AppRealtimeCoordinator()
        let coordinator = LiveEscortSessionCoordinator(realtimeCoordinator: realtime)
        let service = WebSocketService()
        let location = LocationService()
        coordinator.configure(identityKey: "account-a:blind:token", role: .blind, webSocketService: service)
        coordinator.attachLocationService(location)
        coordinator.updateOwnedOrder(orderID: 8, status: .driverEnRoute)
        await Task.yield()
        XCTAssertTrue(coordinator.isSessionEligible)
        XCTAssertFalse(location.isEscortBackgroundModeEnabled)

        coordinator.updateOwnedOrder(orderID: 8, status: .inProgress)
        // 正向条件：轮询等待后台定位真正开启，避免固定 sleep 在负载抖动时提前断言
        let didEnableBackground = await waitUntil { location.isEscortBackgroundModeEnabled }
        XCTAssertTrue(didEnableBackground, "进入 IN_PROGRESS 后应开启护航后台定位")
        let didSettleHealthState = await waitUntil {
            coordinator.healthState == .permissionRequired || coordinator.healthState == .networkDisconnected
        }
        XCTAssertTrue(didSettleHealthState, "健康状态应落在 permissionRequired 或 networkDisconnected")

        coordinator.updateOwnedOrder(orderID: 8, status: .completed)
        await Task.yield()
        XCTAssertNil(coordinator.activeOrderID)
        XCTAssertFalse(location.isEscortBackgroundModeEnabled)

        coordinator.updateOwnedOrder(orderID: 9, status: .driverArrived)
        coordinator.configure(identityKey: "account-b:blind:new-token", role: .blind, webSocketService: service)
        await Task.yield()
        XCTAssertNil(coordinator.activeOrderID)
    }

    @MainActor
    func testDuplicateStatusSchedulesOneEscortReconciliationAndReturnsBeforeHungSend() async {
        let realtime = AppRealtimeCoordinator()
        let service = WebSocketService()
        service.simulateConnectionStateForTesting(.connected)
        let location = LocationService()
        location.simulateDeviceLocationForTesting(
            CLLocationCoordinate2D(latitude: 39.9, longitude: 116.4),
            capturedAt: Date()
        )
        let coordinator = LiveEscortSessionCoordinator(
            realtimeCoordinator: realtime,
            reportInterval: 60,
            sendLocation: { _, _ in
                await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
            }
        )
        coordinator.configure(
            identityKey: "anonymous-session",
            role: .volunteer,
            webSocketService: service,
            locationService: location
        )

        coordinator.updateOwnedOrder(orderID: 88, status: .driverEnRoute)
        coordinator.updateOwnedOrder(orderID: 88, status: .driverEnRoute)
        // 正向条件：先等第一次对账真的排到
        let didReconcile = await waitUntil { coordinator.reconciliationCountForTesting >= 1 }
        XCTAssertTrue(didReconcile, "重复状态应至少触发一次护航对账")
        // 反向条件：再留一个真实时间窗，确认重复状态没有排出第二次对账
        try? await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(coordinator.activeStatus, .driverEnRoute)
        XCTAssertEqual(coordinator.reconciliationCountForTesting, 1)
    }

    @MainActor
    func testRepeatedHealthRefreshPublishesOnlyRealStateChanges() async {
        let realtime = AppRealtimeCoordinator()
        let service = WebSocketService()
        service.simulateConnectionStateForTesting(.connected)
        let location = LocationService()
        location.simulateDeviceLocationForTesting(
            CLLocationCoordinate2D(latitude: 39.9, longitude: 116.4),
            capturedAt: Date(),
            authorized: false
        )
        let coordinator = LiveEscortSessionCoordinator(
            realtimeCoordinator: realtime,
            reportInterval: 60
        )
        var publishedStates: [LiveEscortHealthState] = []
        let cancellable = coordinator.$healthState
            .dropFirst()
            .sink { publishedStates.append($0) }
        coordinator.configure(
            identityKey: "anonymous-session",
            role: .volunteer,
            webSocketService: service,
            locationService: location
        )
        coordinator.updateOwnedOrder(orderID: 90, status: .driverEnRoute)
        // 正向条件：等第一次健康状态真的发布出来
        let didPublishFirstState = await waitUntil { !publishedStates.isEmpty }
        XCTAssertTrue(didPublishFirstState, "配置后应发布一次健康状态变化")
        XCTAssertEqual(publishedStates, [.permissionRequired])

        for _ in 0..<50 {
            service.simulateConnectionStateForTesting(.connected)
        }
        // 反向条件：重复的同值刷新在一个真实时间窗内不得产生任何新发布，保留固定 sleep
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(publishedStates, [.permissionRequired])
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testRepeatedIdenticalDeviceSamplesDoNotRepublishLocationEnvironment() {
        let service = LocationService()
        var presentationChanges = 0
        let cancellable = service.objectWillChange.sink {
            presentationChanges += 1
        }
        let coordinate = CLLocationCoordinate2D(latitude: 25.0402, longitude: 102.7123)

        service.simulateDeviceLocationForTesting(
            coordinate,
            capturedAt: Date(timeIntervalSince1970: 1_000)
        )
        service.simulateDeviceLocationForTesting(
            coordinate,
            capturedAt: Date(timeIntervalSince1970: 1_005)
        )

        XCTAssertEqual(presentationChanges, 1)
        XCTAssertEqual(
            service.latestDeviceSample?.capturedAt,
            Date(timeIntervalSince1970: 1_005)
        )
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testInFlightLocationSendRetainsOnlyLatestSampleForNextSend() async {
        let realtime = AppRealtimeCoordinator()
        let service = WebSocketService()
        service.simulateConnectionStateForTesting(.connected)
        let location = LocationService()
        location.simulateDeviceLocationForTesting(
            CLLocationCoordinate2D(latitude: 39.9, longitude: 116.4),
            capturedAt: Date()
        )
        var sent: [LocatedCoordinate] = []
        var firstSendContinuation: CheckedContinuation<Void, Never>?
        let coordinator = LiveEscortSessionCoordinator(
            realtimeCoordinator: realtime,
            reportInterval: 60,
            sendLocation: { _, sample in
                sent.append(sample)
                if sent.count == 1 {
                    await withCheckedContinuation { continuation in
                        firstSendContinuation = continuation
                    }
                }
            }
        )
        coordinator.configure(
            identityKey: "anonymous-session",
            role: .volunteer,
            webSocketService: service,
            locationService: location
        )
        coordinator.updateOwnedOrder(orderID: 89, status: .driverEnRoute)
        // 正向条件：等首次上报真的发出（此时它会被 continuation 卡住）
        let didStartFirstSend = await waitUntil { sent.count >= 1 }
        XCTAssertTrue(didStartFirstSend, "进入活跃订单后应发起首次位置上报")
        XCTAssertEqual(sent.count, 1)

        location.simulateDeviceLocationForTesting(
            CLLocationCoordinate2D(latitude: 39.91, longitude: 116.41),
            capturedAt: Date()
        )
        location.simulateDeviceLocationForTesting(
            CLLocationCoordinate2D(latitude: 39.92, longitude: 116.42),
            capturedAt: Date()
        )
        // 反向条件：首个上报仍在飞行中时，一个真实时间窗内不得再发出新的上报，保留固定 sleep
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(sent.count, 1)

        firstSendContinuation?.resume()
        // 正向条件：等补发的第二次上报真的发出
        let didSendCoalescedSample = await waitUntil { sent.count >= 2 }
        XCTAssertTrue(didSendCoalescedSample, "首个上报完成后应补发一次最新样本")
        // 反向条件：两个待发样本必须被合并成一次，留固定时间窗确认没有第三次上报
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(sent.count, 2)
        XCTAssertNotEqual(sent.first?.coordinate.latitude, sent.last?.coordinate.latitude)
    }

    @MainActor
    func testPeerFreshnessExpiresAfterFifteenSeconds() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let realtime = AppRealtimeCoordinator()
        let service = WebSocketService()
        realtime.attach(to: service, role: .volunteer)
        let coordinator = LiveEscortSessionCoordinator(realtimeCoordinator: realtime)
        coordinator.configure(identityKey: "account:volunteer:token", role: .volunteer, webSocketService: service)
        coordinator.updateOwnedOrder(orderID: 77, status: .inProgress)
        realtime.simulateIncomingEventForTesting(.blindLocation(WSBlindLocationUpdate(
            type: "BLIND_LOCATION_UPDATE",
            orderId: 77,
            lat: 39.9,
            lng: 116.4,
            timestamp: Int64(now.timeIntervalSince1970 * 1_000)
        )))
        XCTAssertNotNil(coordinator.freshPeerCoordinate(now: now.addingTimeInterval(15)))
        XCTAssertNil(coordinator.freshPeerCoordinate(now: now.addingTimeInterval(15.01)))
    }

    @MainActor
    func testStationaryRealLocationContinuesUntilExplicitFailureAndThenRecovers() async {
        let realtime = AppRealtimeCoordinator()
        var sent: [LocatedCoordinate] = []
        let coordinator = LiveEscortSessionCoordinator(
            realtimeCoordinator: realtime,
            reportInterval: 0.05,
            sendLocation: { _, sample in sent.append(sample) }
        )
        let service = WebSocketService()
        service.simulateConnectionStateForTesting(.connecting)
        let location = LocationService()
        location.simulateDeviceLocationForTesting(
            CLLocationCoordinate2D(latitude: 39.9, longitude: 116.4),
            capturedAt: Date().addingTimeInterval(-60)
        )
        coordinator.configure(identityKey: "account:blind:token", role: .blind, webSocketService: service)
        coordinator.attachLocationService(location)
        coordinator.updateOwnedOrder(orderID: 78, status: .inProgress)
        // 正向条件：等首次上报真的发出
        let didSendFirstReport = await waitUntil { sent.count >= 1 }
        XCTAssertTrue(didSendFirstReport, "进入 IN_PROGRESS 后应上报一次位置")

        // 正向条件：位置静止也要继续按周期上报，等第二次上报到达
        let didKeepReportingWhileStationary = await waitUntil { sent.count >= 2 }
        XCTAssertTrue(didKeepReportingWhileStationary, "位置静止时应继续周期上报第二次")

        service.simulateConnectionStateForTesting(.connected)
        await Task.yield()
        let beforeFailure = sent.count
        location.simulateLocationFailureForTesting()
        // 正向条件：等健康状态切到 waitingForLocation
        let didEnterWaitingForLocation = await waitUntil { coordinator.healthState == .waitingForLocation }
        XCTAssertTrue(didEnterWaitingForLocation, "显式定位失败后应进入 waitingForLocation")
        // 反向条件：定位失败期间必须在一个真实时间窗内确实没有新增上报，保留固定 sleep
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(sent.count, beforeFailure)
        XCTAssertEqual(coordinator.healthState, .waitingForLocation)

        location.simulateDeviceLocationForTesting(
            CLLocationCoordinate2D(latitude: 39.9001, longitude: 116.4001),
            capturedAt: Date()
        )
        // 正向条件：等定位恢复后重新出现新的上报
        let didResumeReporting = await waitUntil { sent.count > beforeFailure }
        XCTAssertTrue(didResumeReporting, "定位恢复后应重新上报位置")
        let didReturnToActive = await waitUntil { coordinator.healthState == .active(background: true) }
        XCTAssertTrue(didReturnToActive, "定位恢复后健康状态应回到 active(background: true)")

        location.simulateDeviceLocationForTesting(
            CLLocationCoordinate2D(latitude: 39.9, longitude: 116.4),
            capturedAt: Date(),
            authorized: false
        )
        service.simulateConnectionStateForTesting(.disconnected)
        service.simulateConnectionStateForTesting(.connected)
        // 正向条件：等权限被撤销后的健康状态落到 permissionRequired
        let didRequirePermission = await waitUntil { coordinator.healthState == .permissionRequired }
        XCTAssertTrue(didRequirePermission, "定位权限被撤销后应进入 permissionRequired")
        XCTAssertNil(location.latestEscortBackendSample())
    }

    @MainActor
    func testImmediatePeriodicReconnectSendAndTerminalStop() async {
        let realtime = AppRealtimeCoordinator()
        var sent: [LocatedCoordinate] = []
        let coordinator = LiveEscortSessionCoordinator(
            realtimeCoordinator: realtime,
            reportInterval: 0.05,
            sendLocation: { _, sample in sent.append(sample) }
        )
        let service = WebSocketService()
        service.simulateConnectionStateForTesting(.connected)
        let location = LocationService()
        location.simulateDeviceLocationForTesting(
            CLLocationCoordinate2D(latitude: 39.908823, longitude: 116.397470),
            capturedAt: Date()
        )
        coordinator.configure(identityKey: "account:blind:token", role: .blind, webSocketService: service)
        coordinator.attachLocationService(location)
        coordinator.updateOwnedOrder(orderID: 88, status: .driverEnRoute)
        // 这里的 10ms 窗口断言的是"立刻上报"：上报周期是 50ms，改成轮询等待会让即时性失去意义，故保留固定 sleep
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertGreaterThanOrEqual(sent.count, 1)
        XCTAssertEqual(sent.last?.system, .gcj02Backend)
        XCTAssertEqual(LiveEscortSessionCoordinator.reportInterval, 5)

        // 正向条件：等周期上报产生第二个样本
        let didSendPeriodicReport = await waitUntil { sent.count >= 2 }
        XCTAssertTrue(didSendPeriodicReport, "应按周期上报出第二次位置")
        let beforeReconnect = sent.count
        service.simulateConnectionStateForTesting(.reconnecting(attempt: 1))
        service.simulateConnectionStateForTesting(.connecting)
        // 同上：重连后的"立刻补发"必须快于 50ms 的上报周期，保留固定 sleep
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertGreaterThan(sent.count, beforeReconnect)

        coordinator.updateOwnedOrder(orderID: 88, status: .cancelled)
        let stoppedCount = sent.count
        // 反向条件：终态订单之后在一个真实时间窗内不得再有上报，保留固定 sleep
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(sent.count, stoppedCount)
    }

    @MainActor
    func testCompletedTrackRetryRecoversWithoutRepeatingFinish() async {
        let client = RecoveringTrackAPIClient()
        let appState = AppState(apiClient: client)
        let viewModel = CompletedTrackSummaryViewModel()

        await viewModel.load(orderID: 94, appState: appState)
        XCTAssertNil(viewModel.track)
        XCTAssertEqual(viewModel.errorMessage, "本次路线暂时无法加载。")

        await viewModel.load(orderID: 94, appState: appState)
        XCTAssertEqual(viewModel.track?.status, .completed)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(client.requestedPaths, ["/api/orders/94/track", "/api/orders/94/track"])
        XCTAssertEqual(client.requestedMethods, [.get, .get])
    }

    /// 轮询等待某个正向条件成立，替代"固定 sleep 之后直接断言"的写法。
    /// 与 blindRunTests.swift 中的同名私有助手保持一致；本类不是 @MainActor，故显式标注。
    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }
}

private final class RecoveringTrackAPIClient: APIClientProtocol, @unchecked Sendable {
    private(set) var requestedPaths: [String] = []
    private(set) var requestedMethods: [HTTPMethod] = []

    func request<T: Decodable>(
        method: HTTPMethod,
        path: String,
        query: [String: String]?,
        body: (any Encodable & Sendable)?,
        requiresAuth: Bool
    ) async throws -> T {
        requestedMethods.append(method)
        requestedPaths.append(path)
        guard requestedPaths.count > 1 else {
            throw APIError.serverError(
                ErrorResponse(code: "TRACK_UNAVAILABLE", message: "轨迹暂时不可用")
            )
        }
        let json = #"{"status":"COMPLETED","volunteerTrack":[],"volunteerStats":{"distanceMeters":0,"durationSeconds":0,"avgPaceSecPerKm":null},"blindTrack":[],"blindStats":{"distanceMeters":0,"durationSeconds":0,"avgPaceSecPerKm":null}}"#
        return try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    func upload<T: Decodable>(
        path: String,
        query: [String: String]?,
        fields: [String: String]?,
        files: [MultipartFile],
        requiresAuth: Bool
    ) async throws -> T {
        throw APIError.invalidURL
    }
}
