import CoreLocation
import Foundation
import OSLog

/// Asks macOS where this Mac is, once.
///
/// One-shot on purpose. A live `CLLocationManager` is exactly the kind of
/// always-running resource this app does not keep: the manager is built for the
/// request, and released the moment an answer arrives. Sunrise moves by four
/// seconds for every kilometre of longitude, so three-kilometre accuracy is
/// already far finer than the question needs — and it is the least the app can
/// ask for and still get an answer.
///
/// The coordinate is stored in the user's settings and nothing else; it is
/// never sent anywhere, because every calculation that uses it runs on this Mac.
enum CurrentLocation {

    enum Failure: LocalizedError {
        case denied
        case servicesOff
        /// macOS was asked for permission and never put a prompt on screen.
        case promptNotShown
        case unavailable(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .denied:
                "Location access is off for Wallpaper. Turn it on in System Settings \u{203A} Privacy & Security \u{203A} Location Services, or enter a location by hand below."
            case .servicesOff:
                "Location Services is switched off for this Mac, in System Settings \u{203A} Privacy & Security \u{203A} Location Services. Turn it on, or enter a location by hand below."
            case .promptNotShown:
                "macOS never showed the permission prompt. Look for Wallpaper in System Settings \u{203A} Privacy & Security \u{203A} Location Services and switch it on, or enter a location by hand below."
            case .unavailable(let reason):
                "Couldn't work out where this Mac is: \(reason). Enter a location by hand below."
            case .timedOut:
                "Location lookup timed out. Try again, or enter a location by hand below."
            }
        }
    }

    /// Whether macOS has been asked yet. The settings row uses it to explain
    /// the wait: a first lookup includes however long the user takes to answer
    /// a permission prompt, and a spinner with no reason given is exactly what
    /// "stuck" looks like.
    static var isUnasked: Bool {
        CLLocationManager().authorizationStatus == .notDetermined
    }

    /// Resolves the current coordinate, prompting for permission the first time.
    ///
    /// Always returns, which is not a given: the timeout has to resume the
    /// delegate's continuation itself rather than cancel whoever is awaiting
    /// it. `withCheckedThrowingContinuation` ignores cancellation entirely, so
    /// a timeout that only cancels leaves the continuation unresumed and the
    /// caller waiting for ever.
    @MainActor
    static func request() async throws -> GeoCoordinate {
        // Cheap to check, and a common reason for a lookup that would otherwise
        // do nothing but time out. Off the main thread, because this one can
        // block.
        let servicesOn = await Task.detached { CLLocationManager.locationServicesEnabled() }.value
        guard servicesOn else { throw Failure.servicesOff }

        return try await OneShotDelegate().resolve()
    }
}

/// Holds the manager alive for exactly one answer.
///
/// `CLLocationManager` keeps only a weak reference to its delegate, so the
/// delegate owns the manager rather than the other way round — which also means
/// both go away together when the call returns.
@MainActor
private final class OneShotDelegate: NSObject, CLLocationManagerDelegate {
    /// A human has to click the permission prompt, so this one is generous —
    /// but not endless, because the prompt failing to appear at all is a real
    /// macOS outcome and has its own answer.
    private static let authorizationWindow = Duration.seconds(45)
    /// Once permission is settled a fix is a Wi-Fi scan, and should be quick.
    private static let fixWindow = Duration.seconds(15)

    private var manager: CLLocationManager?
    private var continuation: CheckedContinuation<GeoCoordinate, any Error>?
    private var timeout: Task<Void, Never>?

    func resolve() async throws -> GeoCoordinate {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let manager = CLLocationManager()
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
            self.manager = manager

            // A first run has no answer yet: ask, and wait to be told. Asking
            // for a location before the prompt is answered simply fails.
            if manager.authorizationStatus == .notDetermined {
                armTimeout(Self.authorizationWindow)
                manager.requestWhenInUseAuthorization()
            } else {
                start(manager)
            }
        }
    }

    private func start(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            finish(.failure(CurrentLocation.Failure.denied))
        case .notDetermined:
            break  // Still waiting on the prompt; its own timeout is running.
        default:
            armTimeout(Self.fixWindow)
            manager.requestLocation()
        }
    }

    /// The only thing standing between a silent CoreLocation and a spinner that
    /// never stops. It resumes the continuation rather than cancelling whoever
    /// is awaiting it, because a checked continuation does not notice
    /// cancellation and would simply never be resumed.
    private func armTimeout(_ duration: Duration) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            // Still unasked after all that means no prompt was ever put on
            // screen — a different problem from a fix that would not come, and
            // one the user can only fix in System Settings.
            let stillUnasked = manager?.authorizationStatus == .notDetermined
            finish(.failure(stillUnasked
                ? CurrentLocation.Failure.promptNotShown
                : CurrentLocation.Failure.timedOut))
        }
    }

    /// Resumes once and once only — the delegate can be called again while the
    /// manager is being torn down, and resuming a continuation twice traps.
    private func finish(_ result: Result<GeoCoordinate, any Error>) {
        timeout?.cancel()
        timeout = nil

        guard let continuation else { return }
        self.continuation = nil
        manager?.delegate = nil
        manager = nil

        if case .failure(let error) = result {
            Log.wallpaper.info("location lookup failed: \(error.localizedDescription, privacy: .public)")
        }
        continuation.resume(with: result)
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { start(manager) }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        MainActor.assumeIsolated {
            guard let location = locations.last else {
                finish(.failure(CurrentLocation.Failure.unavailable("no fix returned")))
                return
            }
            let coordinate = GeoCoordinate(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )
            guard coordinate.isValid else {
                finish(.failure(CurrentLocation.Failure.unavailable("the fix was not usable")))
                return
            }
            finish(.success(coordinate))
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: any Error
    ) {
        MainActor.assumeIsolated {
            if (error as? CLError)?.code == .denied {
                finish(.failure(CurrentLocation.Failure.denied))
            } else {
                finish(.failure(CurrentLocation.Failure.unavailable(error.localizedDescription)))
            }
        }
    }
}
