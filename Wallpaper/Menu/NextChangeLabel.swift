import SwiftUI

/// "Next change in four minutes."
///
/// Its own view because it is the only thing in the menu that has to redraw
/// while the menu simply sits there. "Now" is not something SwiftUI observes and
/// `nextChangeDate` only moves once an interval, so the countdown needs a tick
/// of its own — and keeping that tick down here is what stops it from
/// invalidating the whole panel once a second. The attribution, the history and
/// the quota gauges are redrawn when they change, not on the clock.
///
/// The tick is driven by `.task`, so it is cancelled with the view: a closed
/// menu still costs nothing.
struct NextChangeLabel: View {
    let nextChangeDate: Date?
    let isChanging: Bool

    @State private var now = Date()

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .task {
                while !Task.isCancelled {
                    now = Date()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
    }

    private var text: String {
        if isChanging { return "Changing…" }
        guard let nextChangeDate else { return "Changes manually only" }

        // A due date in the past means the change is on its way in — saying
        // "5 minutes ago" for the *next* change reads as a stuck clock.
        guard nextChangeDate.timeIntervalSince(now) > 0 else { return "Next change any moment now" }

        return "Next change \(Self.formatter.localizedString(for: nextChangeDate, relativeTo: now))"
    }

    /// Held rather than built per tick: this text is rebuilt every second the
    /// menu is open, and a date formatter is expensive to make.
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}
