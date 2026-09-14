import Foundation

/// What to do about a change that failed.
///
/// A decision table and nothing else: it reads an error and answers with a
/// plan. Kept apart from `WallpaperManager` because that is what makes it
/// readable in one screen and testable without the app around it — and because
/// none of these answers depends on anything the manager holds except how many
/// failures have already piled up.
nonisolated enum FailureRecovery {
    /// What to do about a failed change. Some failures fix themselves, some
    /// need the user, and waiting a whole interval to find out which is no good
    /// when the interval is a week.
    enum Plan {
        case retry(after: TimeInterval)
        case waitForNetwork
        case userMustAct

        /// Only worth reaching for the cache when the network is unreachable,
        /// not when the key or the sources are wrong.
        var allowsCacheFallback: Bool {
            switch self {
            case .retry, .waitForNetwork: true
            case .userMustAct: false
            }
        }
    }

    /// Reads a failed change and answers with what to do about it.
    static func plan(for error: any Error, consecutiveFailures: Int) -> Plan {
        switch error {
        case is MeteredNetworkError:
            // Nothing is wrong and nothing will fix itself with time: wait for
            // the connection to change, which is exactly what the monitor does.
            return .waitForNetwork

        case let error as UnsplashError:
            switch error {
            case .missingAccessKey, .invalidAccessKey, .noPhotosFound:
                // Nothing retrying can fix — the key or the source has to change.
                return .userMustAct

            case .rateLimited(let resetsAt):
                // Retrying before the quota rolls over just wastes requests.
                return .retry(after: waitForQuota(until: resetsAt))

            case .unexpectedStatus:
                return .retry(after: backoffDelay(after: consecutiveFailures))

            case .transport(let underlying):
                return isOffline(underlying) ? .waitForNetwork : .retry(after: backoffDelay(after: consecutiveFailures))
            }

        case let error as NASAError:
            switch error {
            case .missingAPIKey, .invalidAPIKey:
                return .userMustAct

            case .noPhotosFound:
                // Today's random draw was all videos. A fresh draw is a
                // different set of days, so this really does fix itself.
                return .retry(after: backoffDelay(after: consecutiveFailures))

            case .rateLimited(let resetsAt):
                return .retry(after: waitForQuota(until: resetsAt))

            case .unexpectedStatus:
                return .retry(after: backoffDelay(after: consecutiveFailures))

            case .transport(let underlying):
                return isOffline(underlying) ? .waitForNetwork : .retry(after: backoffDelay(after: consecutiveFailures))
            }

        case let error as WallhavenError:
            switch error {
            case .invalidAPIKey:
                // Wallhaven is never sent a key, so this cannot be the user's
                // to fix; treat it as the server misbehaving.
                return .retry(after: backoffDelay(after: consecutiveFailures))

            case .noPhotosFound:
                // The search matched nothing even without a minimum size, so a
                // fresh draw will match nothing either.
                return .userMustAct

            case .rateLimited:
                // 45 a minute, and it clears on a rolling window rather than on
                // the hour, so the ordinary backoff is already long enough.
                return .retry(after: backoffDelay(after: consecutiveFailures))

            case .unexpectedStatus:
                return .retry(after: backoffDelay(after: consecutiveFailures))

            case .transport(let underlying):
                return isOffline(underlying) ? .waitForNetwork : .retry(after: backoffDelay(after: consecutiveFailures))
            }

        // A folder that is gone and a setup with no usable source both need the
        // user: no amount of retrying will plug a drive back in or type a key.
        case is LocalFolderError, is SetupError:
            return .userMustAct

        default:
            return .retry(after: backoffDelay(after: consecutiveFailures))
        }
    }

    /// Long enough for the quota to roll over, never shorter than a minute.
    private static func waitForQuota(until resetsAt: Date?) -> TimeInterval {
        max(60, (resetsAt?.timeIntervalSinceNow ?? 3600) + 60)
    }

    private static func isOffline(_ error: any Error) -> Bool {
        [
            NSURLErrorNotConnectedToInternet,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorDNSLookupFailed,
        ].contains((error as NSError).code)
    }

    /// 30s, 1m, 2m, 5m, 15m, then flat. Long enough not to hammer a provider,
    /// short enough that a week-long interval isn't stuck for a week.
    private static func backoffDelay(after failures: Int) -> TimeInterval {
        let ladder: [TimeInterval] = [30, 60, 120, 300, 900]
        return ladder[min(max(0, failures - 1), ladder.count - 1)]
    }
}
