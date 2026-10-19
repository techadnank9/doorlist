import Foundation
import CoreLocation
import EventKit

/// Where the person is, as a town rather than a point. Saved so a search
/// never waits on GPS.
struct SavedPlace: Codable, Equatable {
    var city: String?
    var region: String?
    /// Two-letter country code.
    var country: String?
    var timezone: String?
    var latitude: Double
    var longitude: Double
    var updatedAt: Date
    /// Typed by the person instead of read from the phone.
    var isManual = false

    var label: String {
        [city, region].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// Reads the phone's location once per search (city level is all search needs).
@MainActor
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()

    @Published private(set) var status: CLAuthorizationStatus
    @Published private(set) var place: SavedPlace?

    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<CLLocation?, Never>] = []
    /// Bumped on every resolve, so an old request's timeout can't end a newer one.
    private var generation = 0
    private static let key = "savedPlace"

    override init() {
        status = manager.authorizationStatus
        place = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder.iso.decode(SavedPlace.self, from: $0) }
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    var isAllowed: Bool { status == .authorizedWhenInUse || status == .authorizedAlways }
    var wasDenied: Bool { status == .denied || status == .restricted }
    /// Search can say where to look: location allowed, or a city typed in.
    var isReady: Bool { isAllowed || place?.isManual == true }

    func requestPermission() { manager.requestWhenInUseAuthorization() }

    /// A fresh place when location is allowed and the saved one is over an hour old.
    func current() async -> SavedPlace? {
        if let place, place.isManual { return place }
        guard isAllowed else { return place }
        if let place, Date().timeIntervalSince(place.updatedAt) < 3600 { return place }
        guard let location = await locate() else { return place }
        let mark = (try? await CLGeocoder().reverseGeocodeLocation(location))?.first
        let fresh = SavedPlace(city: mark?.locality ?? mark?.subAdministrativeArea, region: mark?.administrativeArea,
                               country: mark?.isoCountryCode,
                               timezone: mark?.timeZone?.identifier ?? TimeZone.current.identifier,
                               latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                               updatedAt: Date())
        save(fresh)
        return fresh
    }

    /// The person typed a city instead. Empty goes back to the phone's location.
    func setManual(_ city: String) async {
        let trimmed = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if place?.isManual == true { save(nil) }
            return
        }
        let mark = (try? await CLGeocoder().geocodeAddressString(trimmed))?.first
        save(SavedPlace(city: mark?.locality ?? trimmed, region: mark?.administrativeArea, country: mark?.isoCountryCode,
                        timezone: mark?.timeZone?.identifier ?? TimeZone.current.identifier,
                        latitude: mark?.location?.coordinate.latitude ?? 0,
                        longitude: mark?.location?.coordinate.longitude ?? 0,
                        updatedAt: Date(), isManual: true))
    }

    private func save(_ new: SavedPlace?) {
        place = new
        if let new, let data = try? JSONEncoder.iso.encode(new) {
            UserDefaults.standard.set(data, forKey: Self.key)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.key)
        }
    }

    private func locate() async -> CLLocation? {
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
            if waiting.count == 1 { manager.requestLocation() }
            // Give up after 6 seconds rather than hold the search.
            let request = generation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard let self, self.generation == request else { return }
                self.resolve(nil)
            }
        }
    }

    private func resolve(_ location: CLLocation?) {
        generation += 1
        let all = waiting
        waiting = []
        all.forEach { $0.resume(returning: location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in self.resolve(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.resolve(nil) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.status = status }
    }
}

/// Times the person is already busy, so search can skip clashing events.
/// Off until they turn it on; needs full Calendar access to read.
enum CalendarGuard {
    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: "skipBusyTimes") }
        set { UserDefaults.standard.set(newValue, forKey: "skipBusyTimes") }
    }

    static var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    static func requestAccess() async -> Bool {
        (try? await EKEventStore().requestFullAccessToEvents()) ?? false
    }

    /// Busy, timed (not all-day) blocks in the next 60 days.
    static func busy() -> [DateInterval] {
        guard isOn, hasAccess else { return [] }
        let store = EKEventStore()
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(60 * 86_400), calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.availability != .free && $0.endDate > $0.startDate }
            .map { DateInterval(start: $0.startDate, end: $0.endDate) }
    }

    /// Overlaps a busy block by more than 15 minutes.
    static func clashes(start: Date?, end: Date?, busy: [DateInterval]) -> Bool {
        guard let start else { return false }
        let finish = max(end ?? start.addingTimeInterval(2 * 3600), start.addingTimeInterval(60))
        let event = DateInterval(start: start, end: finish)
        return busy.contains { ($0.intersection(with: event)?.duration ?? 0) > 15 * 60 }
    }
}

/// A short, answer-free summary of what the person books, so results lean their way.
enum TasteProfile {
    static func recent(limit: Int = 12) -> [String] {
        Array(HistoryStore.shared.all().filter { $0.status != .declined }.prefix(limit).map(\.eventName))
    }
}
