import CoreLocation
import MAMapKit
import SwiftUI
import UIKit

// MARK: - Map Annotation Item

/// 地图标注数据模型
enum MapAnnotationKind: Equatable, Sendable {
    case orderStart
    case currentLocation
    case peer
    case generic
    /// 历史轨迹的两端。与 `orderStart` 分开：那个标的是订单**约定**的出发地，
    /// 这两个标的是实际**跑出来**的第一个和最后一个轨迹点，两者可以差出几百米。
    case routeStart
    case routeEnd
}

struct MapAnnotationItem: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?
    var kind: MapAnnotationKind = .orderStart
}

struct MapPolylineItem: Identifiable {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
    var isPrimary = false

    var signature: String {
        coordinates.map { String(format: "%.6f,%.6f", $0.latitude, $0.longitude) }.joined(separator: ";")
    }
}

// MARK: - AMap Container

/// 高德地图 UIViewRepresentable 桥接组件。
/// 将 MAMapView 嵌入 SwiftUI 视图层级，支持用户位置、标注和缩放控制。
struct AMapContainer: UIViewRepresentable {

    let centerCoordinate: CLLocationCoordinate2D
    var showsUserLocation: Bool = true
    var annotations: [MapAnnotationItem] = []
    var polylines: [MapPolylineItem] = []
    var zoomLevel: CGFloat = 15.0
    var recenterToken: Int = 0
    var showsCompass: Bool = false
    var screenAnchor: CGPoint = CGPoint(x: 0.5, y: 0.5)
    var tracksUserLocation: Bool = true
    var animatesCenterChanges: Bool = true

    func makeUIView(context: Context) -> AMapHostView {
        let mapView = MAMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = showsUserLocation
        mapView.userTrackingMode = desiredUserTrackingMode
        mapView.setZoomLevel(zoomLevel, animated: false)
        mapView.screenAnchor = screenAnchor
        mapView.setCenter(centerCoordinate, animated: false)
        mapView.showsCompass = showsCompass
        mapView.showsScale = true
        // AidRun updates peer/order markers at multi-second cadence and does not
        // perform in-app turn-by-turn navigation. A 10 fps ceiling is sufficient
        // for panning while preventing an idle home map from driving the main
        // run loop at 60 fps. Default mode also yields rendering while a parent
        // ScrollView is actively tracking a vertical gesture.
        mapView.maxRenderFrame = 10
        mapView.isAllowDecreaseFrame = true
        mapView.runLoopMode = .default
        // MAMapView continuously mutates a large UIKit subview/accessibility tree
        // while rendering. Exposing those implementation details through a
        // UIViewRepresentable makes SwiftUI rebuild accessibility attributes on
        // every map frame. SwiftUI supplies one stable summary element below.
        mapView.isAccessibilityElement = false
        mapView.accessibilityElementsHidden = true
        return AMapHostView(mapView: mapView)
    }

    func updateUIView(_ hostView: AMapHostView, context: Context) {
        let mapView = hostView.mapView
        // 更新用户位置显示
        if mapView.showsUserLocation != showsUserLocation {
            mapView.showsUserLocation = showsUserLocation
        }
        if mapView.userTrackingMode != desiredUserTrackingMode {
            mapView.userTrackingMode = desiredUserTrackingMode
        }

        if mapView.showsCompass != showsCompass {
            mapView.showsCompass = showsCompass
        }

        let screenAnchorDidChange =
            abs(context.coordinator.lastScreenAnchor.x - screenAnchor.x) > 0.001 ||
            abs(context.coordinator.lastScreenAnchor.y - screenAnchor.y) > 0.001
        if screenAnchorDidChange {
            mapView.screenAnchor = screenAnchor
            context.coordinator.lastScreenAnchor = screenAnchor
        }

        // 更新地图中心（仅在坐标变化超过阈值时移动，避免频繁跳动）。
        // recenterToken 变化时强制回到传入坐标，用于“回到当前位置”。
        let currentCenter = mapView.centerCoordinate
        let threshold: Double = 0.0001
        if context.coordinator.lastRecenterToken != recenterToken ||
           screenAnchorDidChange ||
           abs(currentCenter.latitude - centerCoordinate.latitude) > threshold ||
           abs(currentCenter.longitude - centerCoordinate.longitude) > threshold {
            mapView.setCenter(centerCoordinate, animated: animatesCenterChanges)
            context.coordinator.lastRecenterToken = recenterToken
        }

        // 同步标注
        if syncAnnotations(on: mapView, coordinator: context.coordinator) {
            ClientFlowDiagnostics.record(event: "applied", operation: "map-annotations")
        }
        syncPolylines(on: mapView, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ hostView: AMapHostView, coordinator: Coordinator) {
        hostView.mapView.delegate = nil
        hostView.mapView.showsUserLocation = false
        coordinator.styledAnnotationsByID.removeAll()
        coordinator.polylinesByID.removeAll()
        coordinator.lastFittedPrimarySignature = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Private

    private var desiredUserTrackingMode: MAUserTrackingMode {
        showsUserLocation && tracksUserLocation ? .follow : .none
    }

    private func syncAnnotations(on mapView: MAMapView, coordinator: Coordinator) -> Bool {
        var didChange = false
        let incomingIDs = Set(annotations.map(\.id))
        let removedIDs = coordinator.styledAnnotationsByID.keys.filter { !incomingIDs.contains($0) }
        for id in removedIDs {
            if let annotation = coordinator.styledAnnotationsByID.removeValue(forKey: id) {
                mapView.removeAnnotation(annotation)
                didChange = true
            }
        }

        for item in annotations {
            if let existing = coordinator.styledAnnotationsByID[item.id] {
                didChange = existing.update(with: item) || didChange
            } else {
                let annotation = StyledMapPointAnnotation(item: item)
                coordinator.styledAnnotationsByID[item.id] = annotation
                mapView.addAnnotation(annotation)
                didChange = true
            }
        }
        return didChange
    }

    private func syncPolylines(on mapView: MAMapView, coordinator: Coordinator) {
        let drawablePolylines = polylines.filter { $0.coordinates.count >= 2 }
        let incomingIDs = Set(drawablePolylines.map(\.id))
        for id in coordinator.polylinesByID.keys.filter({ !incomingIDs.contains($0) }) {
            if let removed = coordinator.polylinesByID.removeValue(forKey: id) {
                mapView.remove(removed.overlay)
                if removed.isPrimary {
                    coordinator.lastFittedPrimarySignature = nil
                }
            }
        }

        for item in drawablePolylines {
            if coordinator.polylinesByID[item.id]?.signature == item.signature { continue }
            if let previous = coordinator.polylinesByID.removeValue(forKey: item.id) {
                mapView.remove(previous.overlay)
            }
            var coordinates = item.coordinates
            guard let overlay = MAPolyline(coordinates: &coordinates, count: UInt(coordinates.count)) else {
                continue
            }
            coordinator.polylinesByID[item.id] = (overlay, item.signature, item.isPrimary)
            mapView.add(overlay)

            if item.isPrimary, coordinator.lastFittedPrimarySignature != item.signature {
                mapView.setVisibleMapRect(
                    overlay.boundingMapRect,
                    edgePadding: UIEdgeInsets(top: 32, left: 24, bottom: 32, right: 24),
                    animated: false
                )
                coordinator.lastFittedPrimarySignature = item.signature
            }
        }
    }

    final class StyledMapPointAnnotation: MAPointAnnotation {
        let id: String
        var kind: MapAnnotationKind

        init(item: MapAnnotationItem) {
            self.id = item.id
            self.kind = item.kind
            super.init()
            update(with: item)
        }

        @discardableResult
        func update(with item: MapAnnotationItem) -> Bool {
            let changed =
                kind != item.kind ||
                abs(coordinate.latitude - item.coordinate.latitude) > 0.0000001 ||
                abs(coordinate.longitude - item.coordinate.longitude) > 0.0000001 ||
                title != item.title ||
                subtitle != item.subtitle
            guard changed else { return false }
            kind = item.kind
            coordinate = item.coordinate
            title = item.title
            subtitle = item.subtitle
            return true
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MAMapViewDelegate {
        var lastRecenterToken = 0
        var lastScreenAnchor = CGPoint(x: 0.5, y: 0.5)
        var styledAnnotationsByID: [String: StyledMapPointAnnotation] = [:]
        var polylinesByID: [String: (overlay: MAPolyline, signature: String, isPrimary: Bool)] = [:]
        var lastFittedPrimarySignature: String?

        func mapView(_ mapView: MAMapView!, viewFor annotation: MAAnnotation!) -> MAAnnotationView! {
            // 用户位置使用默认蓝点
            if annotation is MAUserLocation {
                return nil
            }

            let kind = (annotation as? StyledMapPointAnnotation)?.kind ?? .generic
            let reuseID = "OrderPin-\(kind)"
            var annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: reuseID) as? MAPinAnnotationView
            if annotationView == nil {
                annotationView = MAPinAnnotationView(annotation: annotation, reuseIdentifier: reuseID)
            } else {
                annotationView?.annotation = annotation
            }
            annotationView?.canShowCallout = true
            annotationView?.animatesDrop = false
            annotationView?.pinColor = kind.pinColor
            return annotationView
        }

        func mapView(_ mapView: MAMapView!, rendererFor overlay: MAOverlay!) -> MAOverlayRenderer! {
            guard let polyline = overlay as? MAPolyline else { return nil }
            let renderer = MAPolylineRenderer(polyline: polyline)
            let isPrimary = polylinesByID.values.first(where: { $0.overlay === polyline })?.isPrimary == true
            renderer?.lineWidth = isPrimary ? 7 : 4
            renderer?.strokeColor = isPrimary ? UIColor.systemBlue : UIColor.systemGray
            return renderer
        }
    }
}

/// SwiftUI owns this stable shell, while MAMapView performs its continuous
/// renderer/layout work as an internal UIKit child. Returning MAMapView itself
/// allows those internal invalidations to propagate to the representable root
/// and can keep AttributeGraph evaluating the entire home page.
final class AMapHostView: UIView {
    let mapView: MAMapView

    init(mapView: MAMapView) {
        self.mapView = mapView
        super.init(frame: .zero)
        clipsToBounds = true
        mapView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mapView)
        NSLayoutConstraint.activate([
            mapView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: trailingAnchor),
            mapView.topAnchor.constraint(equalTo: topAnchor),
            mapView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }
}

private extension MapAnnotationKind {
    var pinColor: MAPinAnnotationColor {
        switch self {
        case .orderStart:
            return .red
        case .currentLocation:
            return .green
        case .peer:
            return .purple
        case .generic:
            return .purple
        // 绿起红终是跑步类产品的通用约定，不自创配色。
        case .routeStart:
            return .green
        case .routeEnd:
            return .red
        }
    }
}

// MARK: - Map View Wrapper

/// 显示 AMap；仅在 Key 缺失或 UI 测试显式禁用地图时呈现配置故障降级视图。
struct MapViewWrapper: View {
    let centerCoordinate: CLLocationCoordinate2D
    var showsUserLocation: Bool = true
    var annotations: [MapAnnotationItem] = []
    var polylines: [MapPolylineItem] = []
    var zoomLevel: CGFloat = 15.0
    var recenterToken: Int = 0
    var showsCompass: Bool = false
    var screenAnchor: CGPoint = CGPoint(x: 0.5, y: 0.5)
    var tracksUserLocation: Bool = true
    var animatesCenterChanges: Bool = true

    var body: some View {
        #if DEBUG || DEMO
        if ProcessInfo.processInfo.environment["AIDRUN_UI_TEST_DISABLE_MAP"] == "1" {
            MapPlaceholderView()
        } else if AMapManager.isConfigured {
            AMapContainer(
                centerCoordinate: centerCoordinate,
                showsUserLocation: showsUserLocation,
                annotations: annotations,
                polylines: polylines,
                zoomLevel: zoomLevel,
                recenterToken: recenterToken,
                showsCompass: showsCompass,
                screenAnchor: screenAnchor,
                tracksUserLocation: tracksUserLocation,
                animatesCenterChanges: animatesCenterChanges
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("地图，显示当前位置和订单地点")
            .accessibilityHint("地图为辅助显示，主要操作请使用下方按钮")
        } else {
            MapPlaceholderView()
        }
        #else
        if AMapManager.isConfigured {
            AMapContainer(
                centerCoordinate: centerCoordinate,
                showsUserLocation: showsUserLocation,
                annotations: annotations,
                polylines: polylines,
                zoomLevel: zoomLevel,
                recenterToken: recenterToken,
                showsCompass: showsCompass,
                screenAnchor: screenAnchor,
                tracksUserLocation: tracksUserLocation,
                animatesCenterChanges: animatesCenterChanges
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("地图，显示当前位置和订单地点")
            .accessibilityHint("地图为辅助显示，主要操作请使用下方按钮")
        } else {
            MapPlaceholderView()
        }
        #endif
    }
}
