import Contacts
import Combine
import CoreLocation
import Foundation

/// Resolves one location at meeting start. Each attempt owns its native resources,
/// so a late delegate callback cannot attach another meeting's location.
@MainActor
final class MeetingLocationService: NSObject, ObservableObject, MeetingLocationResolving, CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var isRequestingAuthorization = false
    private let authorizationManager: CLLocationManager
    private let settings: SettingsStore

    init(settings: SettingsStore = .shared) {
        self.settings = settings
        let manager = CLLocationManager()
        self.authorizationManager = manager
        self.authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    func setEnabled(_ enabled: Bool) {
        self.settings.meetingLocationEnabled = enabled
        if enabled { self.requestAuthorization() }
        else { self.cancelLocationLookup() }
    }

    /// Permission is shared by onboarding, Settings and capture, without geocoding
    /// or acquiring a location while the user is deciding whether to opt in.
    func requestAuthorization() {
        self.refreshAuthorization()
        guard self.authorizationStatus == .notDetermined, !self.isRequestingAuthorization else { return }
        self.isRequestingAuthorization = true
        self.authorizationManager.requestWhenInUseAuthorization()
    }

    func refreshAuthorization() {
        self.authorizationStatus = self.authorizationManager.authorizationStatus
        if self.authorizationStatus != .notDetermined { self.isRequestingAuthorization = false }
    }

    func cancelLocationLookup() {
        if let attempt = self.attempt { self.finish(id: attempt.id, result: nil) }
    }
    private final class Attempt {
        let id: UUID
        let startedAt: Date
        let languages: [PichiInterfaceLanguage]
        let manager: CLLocationManager
        let geocoder = CLGeocoder()
        let continuation: CheckedContinuation<MeetingLocation?, Never>
        var timeout: Task<Void, Never>?
        var location: CLLocation?
        var addresses: [String: String] = [:]
        var languageIndex = 0
        var locationRequestCount = 0
        var requestingLocation = false
        var requestedAuthorization = false

        init(
            id: UUID,
            startedAt: Date,
            languages: [PichiInterfaceLanguage],
            continuation: CheckedContinuation<MeetingLocation?, Never>
        ) {
            self.id = id
            self.startedAt = startedAt
            self.languages = languages
            self.manager = CLLocationManager()
            self.continuation = continuation
        }

        var result: MeetingLocation? {
            guard let location else { return nil }
            return MeetingLocation(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                horizontalAccuracy: location.horizontalAccuracy,
                capturedAt: location.timestamp,
                addresses: self.addresses
            )
        }
    }

    private var attempt: Attempt?

    func locate(startedAt: Date, languages: [PichiInterfaceLanguage]) async -> MeetingLocation? {
        guard Task.isCancelled == false else { return nil }
        // Historical sessions must never receive the device's current location.
        guard abs(startedAt.timeIntervalSinceNow) <= 30 else { return nil }
        let id = UUID()
        var seenLanguages = Set<String>()
        let uniqueLanguages = languages.filter { seenLanguages.insert($0.rawValue).inserted }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard Task.isCancelled == false else {
                    continuation.resume(returning: nil)
                    return
                }
                if let previous = self.attempt {
                    self.finish(id: previous.id, result: nil)
                }
                let attempt = Attempt(
                    id: id,
                    startedAt: startedAt,
                    languages: uniqueLanguages,
                    continuation: continuation
                )
                self.attempt = attempt
                attempt.manager.delegate = self
                attempt.manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
                attempt.timeout = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: 15_000_000_000)
                    } catch {
                        return
                    }
                    guard let self, self.attempt?.id == id else { return }
                    self.finish(id: id, result: self.attempt?.result)
                }
                self.updateAuthorization(for: attempt)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(id: id, result: nil)
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager === self.authorizationManager {
            self.refreshAuthorization()
            return
        }
        guard let attempt = self.attempt, attempt.manager === manager else { return }
        self.authorizationStatus = manager.authorizationStatus
        if self.authorizationStatus != .notDetermined { self.isRequestingAuthorization = false }
        self.updateAuthorization(for: attempt)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let attempt = self.attempt,
              attempt.manager === manager,
              attempt.location == nil else { return }
        attempt.requestingLocation = false
        guard let location = locations.reversed().first(where: {
            Self.isUsable($0, startedAt: attempt.startedAt, now: Date())
        }) else {
            self.requestLocation(for: attempt)
            return
        }
        attempt.location = location
        manager.stopUpdatingLocation()
        self.resolveNextAddress(for: attempt)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard let attempt = self.attempt,
              attempt.manager === manager,
              attempt.location == nil else { return }
        attempt.requestingLocation = false
        if (error as? CLError)?.code == .locationUnknown {
            self.requestLocation(for: attempt)
        } else {
            self.finish(id: attempt.id, result: nil)
        }
    }

    private func updateAuthorization(for attempt: Attempt) {
        guard self.attempt?.id == attempt.id else { return }
        switch attempt.manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            self.requestLocation(for: attempt)
        case .notDetermined:
            guard attempt.requestedAuthorization == false else { return }
            attempt.requestedAuthorization = true
            attempt.manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            self.finish(id: attempt.id, result: nil)
        @unknown default:
            self.finish(id: attempt.id, result: nil)
        }
    }

    private func requestLocation(for attempt: Attempt) {
        guard self.attempt?.id == attempt.id,
              attempt.location == nil,
              attempt.requestingLocation == false else { return }
        // A stale or inaccurate first fix may be cached. Keep retries bounded.
        guard attempt.locationRequestCount < 3 else {
            self.finish(id: attempt.id, result: nil)
            return
        }
        attempt.locationRequestCount += 1
        attempt.requestingLocation = true
        attempt.manager.requestLocation()
    }

    private func resolveNextAddress(for attempt: Attempt) {
        guard self.attempt?.id == attempt.id, let location = attempt.location else { return }
        guard attempt.languageIndex < attempt.languages.count else {
            self.finish(id: attempt.id, result: attempt.result)
            return
        }
        let languageIndex = attempt.languageIndex
        let language = attempt.languages[languageIndex]
        let id = attempt.id
        attempt.geocoder.reverseGeocodeLocation(location, preferredLocale: language.locale) { [weak self] placemarks, error in
            let address = error == nil ? placemarks?.first.flatMap(Self.compactAddress) : nil
            Task { @MainActor [weak self] in
                guard let self,
                      let current = self.attempt,
                      current.id == id,
                      current.languageIndex == languageIndex else { return }
                if let address {
                    current.addresses[language.rawValue] = address
                }
                current.languageIndex += 1
                self.resolveNextAddress(for: current)
            }
        }
    }

    private func finish(id: UUID, result: MeetingLocation?) {
        guard let attempt = self.attempt, attempt.id == id else { return }
        self.attempt = nil
        attempt.timeout?.cancel()
        attempt.timeout = nil
        attempt.manager.delegate = nil
        attempt.manager.stopUpdatingLocation()
        attempt.geocoder.cancelGeocode()
        attempt.continuation.resume(returning: result)
    }

    nonisolated static func isUsable(_ location: CLLocation, startedAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(location.timestamp)
        let fromStart = location.timestamp.timeIntervalSince(startedAt)
        return CLLocationCoordinate2DIsValid(location.coordinate)
            && location.horizontalAccuracy.isFinite
            && location.horizontalAccuracy >= 0
            && location.horizontalAccuracy <= 100
            && age >= -2 && age <= 10
            && fromStart >= -5 && fromStart <= 30
    }

    nonisolated static func compactAddress(_ placemark: CLPlacemark) -> String? {
        let address = CNMutablePostalAddress()
        let postal = placemark.postalAddress
        if let street = Self.nonempty(postal?.street) {
            address.street = street
        } else if let thoroughfare = Self.nonempty(placemark.thoroughfare) {
            address.street = [Self.nonempty(placemark.subThoroughfare), thoroughfare]
                .compactMap { $0 }.joined(separator: " ")
        }
        address.city = Self.nonempty(placemark.locality) ?? Self.nonempty(postal?.city) ?? ""
        address.isoCountryCode = placemark.isoCountryCode ?? postal?.isoCountryCode ?? ""
        // Keep only actual geocoder fields. A city-only result stays a city.
        guard address.street.isEmpty == false || address.city.isEmpty == false else { return nil }
        let formatted = CNPostalAddressFormatter.string(from: address, style: .mailingAddress)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined(separator: ", ")
        return Self.nonempty(formatted)
    }

    nonisolated private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
