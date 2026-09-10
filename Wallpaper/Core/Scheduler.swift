import Foundation

/// Drives the wallpaper rotation.
///
/// Uses `NSBackgroundActivityScheduler` rather than a `Timer` so macOS can
/// coalesce wakeups with other system activity — the app costs nothing while
/// idle. The next due date is persisted, so a change missed while the Mac was
/// asleep or shut down fires on the next launch instead of being skipped.
@Observable
final class Scheduler {
    private static let nextChangeKey = "nextChangeDate"
    private static let activityIdentifier = "com.barackilic.Wallpaper.rotate"

    private(set) var nextChangeDate: Date?

    private var activity: NSBackgroundActivityScheduler?
    private let defaults: UserDefaults
    private var interval: ChangeInterval = .manual
    private var onFire: (() async -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.nextChangeDate = defaults.object(forKey: Self.nextChangeKey) as? Date
    }

    /// Starts (or restarts) rotation. Call again whenever the interval changes.
    func start(interval: ChangeInterval, onFire: @escaping () async -> Void) {
        self.interval = interval
        self.onFire = onFire

        activity?.invalidate()
        activity = nil

        guard let duration = interval.duration else {
            nextChangeDate = nil
            defaults.removeObject(forKey: Self.nextChangeKey)
            return
        }

        if nextChangeDate == nil {
            scheduleNext(after: duration)
        }

        let scheduler = NSBackgroundActivityScheduler(identifier: Self.activityIdentifier)
        scheduler.repeats = true
        scheduler.interval = duration
        // A generous tolerance lets macOS batch our wakeup with others instead
        // of waking the CPU just for us.
        scheduler.tolerance = min(duration * 0.2, 30 * 60)
        scheduler.qualityOfService = .background

        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                await self?.fire()
                completion(.finished)
            }
        }

        activity = scheduler
    }

    func stop() {
        activity?.invalidate()
        activity = nil
    }

    /// Runs a change now and pushes the next one a full interval out. Used by
    /// the "change now" menu item so a manual skip doesn't leave an automatic
    /// change moments behind it.
    func fireNow() async {
        await fire()
    }

    /// Fires immediately if the scheduled change came due while the app was not
    /// running. Call once at launch and on wake.
    func fireIfOverdue() async {
        guard interval.duration != nil, let due = nextChangeDate, Date() >= due else { return }
        await fire()
    }

    private func fire() async {
        await onFire?()

        if let duration = interval.duration {
            scheduleNext(after: duration)
        }
    }

    private func scheduleNext(after duration: TimeInterval) {
        let next = Date().addingTimeInterval(duration)
        nextChangeDate = next
        defaults.set(next, forKey: Self.nextChangeKey)
    }
}
