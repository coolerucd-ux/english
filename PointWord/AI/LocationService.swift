import Foundation
import CoreLocation

// Turns "where am I right now" into a human city/country string for the footprint
// feature. Deliberately lightweight:
//
//   • WHEN-IN-USE only — we never track in the background. A fix is pulled on
//     demand at save time and immediately released.
//   • FREE — CoreLocation + CLGeocoder reverse-geocoding cost nothing (no API
//     key, no per-call charge), unlike the Qwen calls elsewhere.
//   • NON-BLOCKING & BEST-EFFORT — every entry point returns "" (unknown place)
//     on denial, timeout, airplane mode, or geocoder failure, so a missing city
//     never blocks or slows down saving a word.
//   • CHEAP — the last good placemark is cached for a few minutes; saves in the
//     same spot reuse it instead of waking the GPS + geocoder each time.
//
// The permission prompt only appears the FIRST time currentPlace() is called
// with an image save — i.e. the user has already opted into the experience by
// saving a word — never at launch.
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    private let manager = CLLocationManager()

    // One in-flight one-shot request's continuation, plus a watchdog so a fix that
    // never arrives resolves to "" instead of hanging the save's enrichment task.
    private var pending: CheckedContinuation<CLLocation?, Never>?
    private var timeoutTask: Task<Void, Never>?

    // Cache the last resolved place so repeated saves in one sitting don't re-hit
    // GPS/geocoder. Reverse geocoding especially is rate-limited by iOS.
    private var cachedPlace: ResolvedPlace?
    private struct ResolvedPlace { let city: String; let country: String; let at: Date }
    private let cacheTTL: TimeInterval = 5 * 60

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer   // city-level is all we need
    }

    // A resolved city + country for the current location, or ("", "") if we can't
    // get one for any reason. Never throws, never blocks the caller meaningfully.
    struct Place { let city: String; let country: String }

    func currentPlace() async -> Place {
        // Serve from cache when it's fresh — avoids waking GPS on every save.
        if let c = cachedPlace, Date().timeIntervalSince(c.at) < cacheTTL {
            return Place(city: c.city, country: c.country)
        }

        // Ask permission lazily. If the user has denied/restricted, give up quietly.
        let status = manager.authorizationStatus
        switch status {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            // The prompt is async; a fix requested right now would fail. Return
            // unknown for THIS save — the next save (after they tap Allow) will
            // resolve. We don't block the save waiting on a modal dialog.
            return Place(city: "", country: "")
        case .denied, .restricted:
            return Place(city: "", country: "")
        default:
            break
        }

        guard let location = await requestOneShot() else {
            return Place(city: "", country: "")
        }

        let place = await reverseGeocode(location)
        if !place.city.isEmpty || !place.country.isEmpty {
            cachedPlace = ResolvedPlace(city: place.city, country: place.country, at: Date())
        }
        return place
    }

    // MARK: - One-shot fix

    private func requestOneShot() async -> CLLocation? {
        // Only one in-flight request at a time; if one's already pending, bail.
        if pending != nil { return nil }

        return await withCheckedContinuation { (cont: CheckedContinuation<CLLocation?, Never>) in
            pending = cont
            manager.requestLocation()   // delivers once to the delegate, then stops

            // Watchdog: GPS can take a while (or never resolve indoors). Cap the
            // wait so the save's enrichment doesn't hang.
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6 * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.resolvePending(with: nil)
            }
        }
    }

    private func resolvePending(with location: CLLocation?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        pending?.resume(returning: location)
        pending = nil
    }

    // MARK: - Reverse geocode

    private func reverseGeocode(_ location: CLLocation) async -> Place {
        let geocoder = CLGeocoder()
        // Ask iOS to phrase place names in the app's own display language later;
        // CLGeocoder localizes using the device/app locale automatically.
        guard let marks = try? await geocoder.reverseGeocodeLocation(location),
              let mark = marks.first else {
            return Place(city: "", country: "")
        }
        // Prefer city (locality); fall back to sub-admin / admin area (e.g. a rural
        // spot with no locality). Country is the full name, not the ISO code.
        let city = mark.locality
            ?? mark.subAdministrativeArea
            ?? mark.administrativeArea
            ?? ""
        let country = mark.country ?? ""
        return Place(city: city, country: country)
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let loc = locations.last
        Task { @MainActor in self.resolvePending(with: loc) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.resolvePending(with: nil) }
    }
}
