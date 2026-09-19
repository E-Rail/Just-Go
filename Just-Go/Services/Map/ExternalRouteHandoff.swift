import CoreLocation
import Foundation
import MapKit
import UIKit

/// Handing one leg of a trip to an app that routes it better: **bike and car legs only**. Trains,
/// walks and exits are what this app is for; live road navigation and hailing a car are not.
///
/// Every destination carries an https fallback for an installed app that rejects the URL built for
/// it (uninstalled apps are already dropped by `destinations(for:)`). It is the only branch
/// testable off-device: no simulator has these apps.
///
/// Coordinates go out in GCJ-02, which the app holds and all three Chinese services expect.
enum ExternalRouteHandoff {
    enum Destination: String, CaseIterable, Identifiable {
        case appleMaps
        case amap
        case baiduMaps
        case didi

        var id: String { rawValue }

        var title: String {
            switch self {
            case .appleMaps:
                return AppLocalization.text(english: "Apple Maps", simplified: "苹果地图", traditional: "蘋果地圖")
            case .amap:
                return AppLocalization.text(english: "Amap", simplified: "高德地图", traditional: "高德地圖")
            case .baiduMaps:
                return AppLocalization.text(english: "Baidu Maps", simplified: "百度地图", traditional: "百度地圖")
            case .didi:
                return AppLocalization.text(english: "DiDi", simplified: "滴滴出行", traditional: "滴滴出行")
            }
        }

        var symbolName: String {
            switch self {
            case .appleMaps, .amap, .baiduMaps: return "map"
            case .didi: return "car.fill"
            }
        }

        /// Must also appear in `LSApplicationQueriesSchemes`, or `canOpenURL` answers false however
        /// installed the app is. Apple Maps has none: it is reached through `MKMapItem`.
        var queryScheme: String? {
            switch self {
            case .appleMaps: return nil
            case .amap: return "iosamap"
            case .baiduMaps: return "baidumap"
            case .didi: return "diditaxi"
            }
        }

        /// Hailing is only a car, so it is not offered beside a bicycle.
        func handles(_ mode: AccessLegMode) -> Bool {
            switch self {
            case .appleMaps, .amap, .baiduMaps: return true
            case .didi: return mode == .driving
            }
        }
    }

    /// Opens a scanner, so a rider can unlock a shared bike, which is how every shared bike in
    /// mainland China is unlocked. Not a `Destination`: it goes nowhere.
    ///
    /// **Just-Go has no bike-share data and this button claims none**: not that a bike is there,
    /// nor which operator serves the street. It never tells anyone to photograph anything either;
    /// station photography is restricted in parts of mainland China.
    ///
    /// **These two schemes are not documented by Tencent or Ant for third-party use** and may stop
    /// working. Offered only when `canOpenURL` says the app is installed, with no web fallback (a
    /// browser cannot open a camera). If one breaks, delete it.
    enum BikeScanner: String, CaseIterable, Identifiable {
        case alipay
        case weChat

        var id: String { rawValue }

        var title: String {
            switch self {
            case .alipay:
                return AppLocalization.text(english: "Scan in Alipay", simplified: "用支付宝扫码", traditional: "用支付寶掃碼")
            case .weChat:
                return AppLocalization.text(english: "Scan in WeChat", simplified: "用微信扫码", traditional: "用微信掃碼")
            }
        }

        /// Must also appear in `LSApplicationQueriesSchemes` or `canOpenURL` answers false however
        /// installed the app is.
        var queryScheme: String {
            switch self {
            case .alipay: return "alipay"
            case .weChat: return "weixin"
            }
        }

        var url: URL? {
            switch self {
            case .alipay: return URL(string: "alipays://platformapi/startapp?saId=10000007")
            case .weChat: return URL(string: "weixin://dl/scan")
            }
        }
    }

    /// The scanners actually installed, in the order a rider is most likely to want them.
    @MainActor
    static func bikeScanners() -> [BikeScanner] {
        BikeScanner.allCases.filter { scanner in
            guard let probe = URL(string: "\(scanner.queryScheme)://") else { return false }
            return UIApplication.shared.canOpenURL(probe)
        }
    }

    @MainActor
    static func open(_ scanner: BikeScanner) {
        guard let url = scanner.url, UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }

    /// Which destinations to show for this leg. Apple Maps always, since it cannot be missing; the
    /// rest only when installed.
    @MainActor
    static func destinations(for mode: AccessLegMode) -> [Destination] {
        Destination.allCases.filter { destination in
            guard destination.handles(mode) else { return false }
            guard let scheme = destination.queryScheme else { return true }
            guard let probe = URL(string: "\(scheme)://") else { return false }
            return UIApplication.shared.canOpenURL(probe)
        }
    }

    @MainActor
    static func open(
        _ destination: Destination,
        from origin: CLLocationCoordinate2D,
        originName: String,
        to target: CLLocationCoordinate2D,
        destinationName: String,
        mode: AccessLegMode
    ) {
        if destination == .appleMaps {
            // Both ends, and both named. `openInMaps` on one item routes from wherever the rider is
            // standing, but an access leg starts at a station they have not reached. An `MKMapItem`
            // built from a bare coordinate has no name, and Maps silently substitutes the rider's
            // location for a start it cannot label.
            let start = MKMapItem(placemark: MKPlacemark(coordinate: origin))
            start.name = originName
            let item = MKMapItem(placemark: MKPlacemark(coordinate: target))
            item.name = destinationName
            MKMapItem.openMaps(with: [start, item], launchOptions: [
                MKLaunchOptionsDirectionsModeKey: mode == .driving
                    ? MKLaunchOptionsDirectionsModeDriving
                    : MKLaunchOptionsDirectionsModeWalking
            ])
            return
        }

        let app = url(for: destination, from: origin, to: target, destinationName: destinationName, mode: mode)
        let web = webURL(for: destination, from: origin, to: target, destinationName: destinationName, mode: mode)
        if let app, UIApplication.shared.canOpenURL(app) {
            UIApplication.shared.open(app)
        } else if let web {
            UIApplication.shared.open(web)
        }
    }

    static func url(
        for destination: Destination,
        from origin: CLLocationCoordinate2D,
        to target: CLLocationCoordinate2D,
        destinationName: String,
        mode: AccessLegMode
    ) -> URL? {
        let name = encoded(destinationName)
        switch destination {
        case .appleMaps:
            return nil
        case .amap:
            // `t`: 0 drive, 2 walk, 3 ride. `dev=0` says the coordinates are already GCJ-02.
            let travel = mode == .driving ? "0" : "3"
            return URL(string:
                "iosamap://path?sourceApplication=Just-Go&sid=&slat=\(origin.latitude)&slon=\(origin.longitude)"
                    + "&did=&dlat=\(target.latitude)&dlon=\(target.longitude)&dname=\(name)&dev=0&t=\(travel)")
        case .baiduMaps:
            let travel = mode == .driving ? "driving" : "riding"
            return URL(string:
                "baidumap://map/direction?origin=\(origin.latitude),\(origin.longitude)"
                    + "&destination=\(target.latitude),\(target.longitude)"
                    + "&mode=\(travel)&coord_type=gcj02&src=Just-Go")
        case .didi:
            return URL(string:
                "diditaxi://router?fromlat=\(origin.latitude)&fromlng=\(origin.longitude)"
                    + "&tolat=\(target.latitude)&tolng=\(target.longitude)&toname=\(name)")
        }
    }

    static func webURL(
        for destination: Destination,
        from origin: CLLocationCoordinate2D,
        to target: CLLocationCoordinate2D,
        destinationName: String,
        mode: AccessLegMode
    ) -> URL? {
        let name = encoded(destinationName)
        switch destination {
        case .appleMaps:
            return nil
        case .amap:
            let travel = mode == .driving ? "car" : "ride"
            return URL(string:
                "https://uri.amap.com/navigation?from=\(origin.longitude),\(origin.latitude)"
                    + "&to=\(target.longitude),\(target.latitude),\(name)"
                    + "&mode=\(travel)&coordinate=gaode&src=Just-Go")
        case .baiduMaps:
            let travel = mode == .driving ? "driving" : "riding"
            return URL(string:
                "https://api.map.baidu.com/direction?origin=\(origin.latitude),\(origin.longitude)"
                    + "&destination=\(target.latitude),\(target.longitude)"
                    + "&mode=\(travel)&coord_type=gcj02&output=html&src=Just-Go")
        case .didi:
            // Their own web entry, which is what a rider without the app can actually use.
            return URL(string:
                "https://common.diditaxi.com.cn/general/webEntry?fromlat=\(origin.latitude)"
                    + "&fromlng=\(origin.longitude)&tolat=\(target.latitude)&tolng=\(target.longitude)")
        }
    }

    /// Percent-encodes everything a query value must not carry raw: ASCII unreserved (RFC 3986
    /// §2.3) and nothing else. `.alphanumerics` is the wrong set: CJK ideographs are letters to it
    /// and pass through unencoded.
    private static let queryValueAllowed: CharacterSet = {
        var allowed = CharacterSet(charactersIn: "A"..."Z")
        allowed.formUnion(CharacterSet(charactersIn: "a"..."z"))
        allowed.formUnion(CharacterSet(charactersIn: "0"..."9"))
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    private static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? ""
    }
}
