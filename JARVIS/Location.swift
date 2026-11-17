import CoreLocation
import Foundation

/// Where Aryak is, asked of the phone only when a question needs it: where he is, or the weather without a place
/// named. Same rule as JARVIS's web page. The position goes to JARVIS on the Mac, which turns it into a town and
/// drops the coordinates; only the town is kept or sent anywhere.
@MainActor
final class Location: NSObject, CLLocationManagerDelegate {
    static let shared = Location()
    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<CLLocation?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer   // a town is all JARVIS needs
    }

    private static let whereQ = try! NSRegularExpression(
        pattern: #"\b(where (am i|are we|is this|do i live)|my location|current location|near(by| me| here)|(what|which) (town|city|place|state|country) (am i|are we|is this))\b"#,
        options: [.caseInsensitive])
    private static let weatherQ = try! NSRegularExpression(
        pattern: #"\b(weather|forecast|temperature|how (hot|cold|warm)|rain\w*|snow\w*|umbrella|jacket|coat|humid\w*|windy|sunny|storm\w*)\b"#,
        options: [.caseInsensitive])
    private static let placeNamed = try! NSRegularExpression(pattern: #"\b(in|at|for|near|around)\s+[A-Z]"#)

    /// Does this question need to know where he is?
    static func needed(for text: String) -> Bool {
        let all = NSRange(text.startIndex..., in: text)
        if whereQ.firstMatch(in: text, range: all) != nil { return true }
        return weatherQ.firstMatch(in: text, range: all) != nil && placeNamed.firstMatch(in: text, range: all) == nil
    }

    /// One fix, or nil if he said no, it's off, or it took over 8 seconds. The first time, iOS asks his permission.
    func now() async -> CLLocation? {
        switch manager.authorizationStatus {
        case .denied, .restricted: return nil
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: break
        }
        if let recent = manager.location, -recent.timestamp.timeIntervalSinceNow < 600 { return recent }
        return await withCheckedContinuation { c in
            waiting.append(c)
            if waiting.count == 1 { manager.requestLocation() }
            Task { try? await Task.sleep(nanoseconds: 8_000_000_000); self.finish(nil) }
        }
    }

    private func finish(_ loc: CLLocation?) {
        let w = waiting; waiting = []
        w.forEach { $0.resume(returning: loc) }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        let last = locs.last
        Task { @MainActor in self.finish(last) }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let s = m.authorizationStatus
        Task { @MainActor in
            if s == .authorizedWhenInUse || s == .authorizedAlways {
                if !self.waiting.isEmpty { self.manager.requestLocation() }
            } else if s == .denied || s == .restricted {
                self.finish(nil)
            }
        }
    }
}
