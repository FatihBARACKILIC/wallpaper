import SwiftUI

/// Read-only view of one API's hourly quota.
///
/// The numbers only refresh when the app makes a request, so the reading is
/// shown with its age — refreshing it on demand would itself cost a request.
struct RateLimitGauge: View {
    let name: String
    let rateLimit: RateLimit?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(name) quota")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(headline)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(tint)
            }

            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(tint)

            Text(footnote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var headline: String {
        guard let rateLimit, !rateLimit.isStale else { return "—" }
        return "\(rateLimit.remaining) / \(rateLimit.limit) left"
    }

    private var fraction: Double {
        guard let rateLimit, !rateLimit.isStale, rateLimit.limit > 0 else { return 1 }
        return Double(rateLimit.remaining) / Double(rateLimit.limit)
    }

    private var tint: Color {
        switch fraction {
        case ..<0.1: .red
        case ..<0.25: .orange
        default: .accentColor
        }
    }

    private var footnote: String {
        guard let rateLimit else {
            return "No requests made yet."
        }
        if rateLimit.isStale {
            return "Quota has reset since the last request."
        }

        let age = RelativeDateTimeFormatter()
        age.unitsStyle = .full
        let observed = age.localizedString(for: rateLimit.observedAt, relativeTo: Date())
        let resets = rateLimit.resetsAt.formatted(date: .omitted, time: .shortened)
        return "Measured \(observed) · resets at \(resets)"
    }
}
