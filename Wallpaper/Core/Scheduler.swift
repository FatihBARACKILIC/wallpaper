import Foundation

/// Drives the wallpaper rotation.
///
/// Fires from a single run-loop timer armed for the next due date — one wakeup
/// per interval, nothing in between. The next due date is persisted, so a change
/// missed while the Mac was asleep or shut down fires on the next launch instead
/// of being skipped.
///
/// This used to be an `NSBackgroundActivityScheduler`, which was the wrong tool:
/// that schedules *discretionary* work, so `dasd` scores every run against system
/// policy and on battery answers `Decision: MNP` — may not proceed. Measured on a
/// discharging Mac, a 5 minute interval was stretched to 23–28 minutes and often
/// skipped outright. Rotation is something the user set on a clock, not a chore
/// the system may defer, so it owns its own timer.
@Observable
final class Scheduler {
    private static let nextChangeKey = "nextChangeDate"

    private(set) var nextChangeDate: Date?

    private var timer: Timer?
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

        disarm()

        guard let duration = interval.duration else {
            nextChangeDate = nil
            defaults.removeObject(forKey: Self.nextChangeKey)
            return
        }

        // A shorter interval has to take effect now. Keeping a due date left over
        // from a longer one would make the change the user just asked for wait out
        // the old interval — switch from weekly to 5 minutes and nothing happens
        // for a week.
        if let due = nextChangeDate, due.timeIntervalSinceNow <= duration {
            arm(for: due)
        } else {
            scheduleNext(after: duration)
        }
    }

    func stop() {
        disarm()
    }

    /// Forgets when the next change was due. Used when setup finishes: a due
    /// date left over from an earlier configuration would fire a change on top
    /// of the one setup triggers itself.
    func reset() {
        disarm()
        nextChangeDate = nil
        defaults.removeObject(forKey: Self.nextChangeKey)
    }

    /// Runs a change now and pushes the next one a full interval out. Used by
    /// the "change now" menu item so a manual skip doesn't leave an automatic
    /// change moments behind it.
    func fireNow() async {
        await fire()
    }

    /// Pushes the next change a full interval out without firing one.
    ///
    /// For a wallpaper the user chose by hand — one picked out of the history
    /// or the favourites. Rotation carrying on regardless would wipe their
    /// choice off the screen seconds later, which is not what picking a photo
    /// means. Does nothing on `.manual`: there is no interval to push out.
    func postpone() {
        guard let duration = interval.duration else { return }
        scheduleNext(after: duration)
    }

    /// Fires immediately if the scheduled change came due while the app was not
    /// running, or while the Mac was asleep. Call once at launch and on wake.
    func fireIfOverdue() async {
        guard interval.duration != nil, let due = nextChangeDate, Date() >= due else { return }
        await fire()
    }

    private func fire() async {
        disarm()

        await onFire?()

        if let duration = interval.duration {
            scheduleNext(after: duration)
        }
    }

    private func scheduleNext(after duration: TimeInterval) {
        let next = Date().addingTimeInterval(duration)
        nextChangeDate = next
        defaults.set(next, forKey: Self.nextChangeKey)
        arm(for: next)
    }

    private func arm(for date: Date) {
        disarm()
        guard onFire != nil else { return }

        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.fire()
            }
        }
        // Enough slack for the system to coalesce our wakeup with others, but
        // bounded so a short interval stays recognisably the interval the user
        // picked: 30 s on a 5 minute rotation, 5 minutes on a daily one.
        timer.tolerance = min((interval.duration ?? 0) * 0.1, 5 * 60)
        // .common so the timer still fires while a menu is tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func disarm() {
        timer?.invalidate()
        timer = nil
    }
}
