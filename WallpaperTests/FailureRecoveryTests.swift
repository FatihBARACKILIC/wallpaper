import Foundation
import Testing

@testable import Wallpaper

/// The recovery table decides what a failed change does next, and the wrong
/// answer is expensive in both directions: retrying a bad key burns requests
/// for ever, and telling the user to fix a passing cloud freezes the desktop.
/// It is pure, so it can be checked outright.
@Suite("Failure recovery")
struct FailureRecoveryTests {
    private let folder = Source.folder(at: URL(fileURLWithPath: "/tmp/photos"))

    // MARK: - Who has to act

    @Test("A key the provider rejected is the user's to fix, not something to retry")
    func badKeyNeedsTheUser() {
        for error in [UnsplashError.missingAccessKey, .invalidAccessKey] {
            guard case .userMustAct = FailureRecovery.plan(for: error, consecutiveFailures: 1) else {
                Issue.record("expected userMustAct for \(error)")
                return
            }
        }

        guard case .userMustAct = FailureRecovery.plan(for: NASAError.invalidAPIKey, consecutiveFailures: 1) else {
            Issue.record("expected userMustAct for a bad NASA key")
            return
        }
    }

    @Test("An unplugged folder needs the user — retrying will not plug it back in")
    func missingFolderNeedsTheUser() {
        let error = LocalFolderError.unavailable("/Volumes/Photos")
        guard case .userMustAct = FailureRecovery.plan(for: error, consecutiveFailures: 1) else {
            Issue.record("expected userMustAct")
            return
        }
    }

    @Test("A Wallhaven search that matched nothing will match nothing next time either")
    func emptyWallhavenSearchNeedsTheUser() {
        let error = WallhavenError.noPhotosFound(.wallhaven(query: "nothing at all"))
        guard case .userMustAct = FailureRecovery.plan(for: error, consecutiveFailures: 1) else {
            Issue.record("expected userMustAct")
            return
        }
    }

    // MARK: - Waiting rather than failing

    @Test("Being offline waits for the network instead of burning retries")
    func offlineWaits() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        guard case .waitForNetwork = FailureRecovery.plan(
            for: UnsplashError.transport(offline), consecutiveFailures: 1
        ) else {
            Issue.record("expected waitForNetwork")
            return
        }
    }

    @Test("A hotspot waits for a different connection, not for a timer")
    func meteredWaits() {
        for error in [MeteredNetworkError.expensive, .constrained] {
            guard case .waitForNetwork = FailureRecovery.plan(for: error, consecutiveFailures: 1) else {
                Issue.record("expected waitForNetwork for \(error)")
                return
            }
        }
    }

    @Test("A transport error that is not an outage retries rather than waiting for a network that is already up")
    func otherTransportErrorsRetry() {
        let refused = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse)
        guard case .retry = FailureRecovery.plan(for: NASAError.transport(refused), consecutiveFailures: 1) else {
            Issue.record("expected retry")
            return
        }
    }

    // MARK: - Retrying

    @Test("A rate limit waits for the quota to roll over, plus a minute")
    func rateLimitWaitsForTheQuota() {
        let resetsAt = Date().addingTimeInterval(600)
        guard case .retry(let delay) = FailureRecovery.plan(
            for: UnsplashError.rateLimited(resetsAt: resetsAt), consecutiveFailures: 1
        ) else {
            Issue.record("expected retry")
            return
        }
        #expect(delay > 600)
        #expect(delay < 700)
    }

    @Test("A rate limit that has already rolled over still waits a minute")
    func rateLimitNeverRetriesImmediately() {
        let passed = Date().addingTimeInterval(-600)
        guard case .retry(let delay) = FailureRecovery.plan(
            for: NASAError.rateLimited(resetsAt: passed), consecutiveFailures: 1
        ) else {
            Issue.record("expected retry")
            return
        }
        #expect(delay == 60)
    }

    @Test("Wallhaven's rate limit takes the ordinary backoff: it clears within a minute anyway")
    func wallhavenRateLimitUsesBackoff() {
        guard case .retry(let delay) = FailureRecovery.plan(
            for: WallhavenError.rateLimited, consecutiveFailures: 1
        ) else {
            Issue.record("expected retry")
            return
        }
        #expect(delay == 30)
    }

    @Test("The backoff climbs with each failure and then flattens")
    func backoffClimbsThenFlattens() {
        let delays = (1...8).map { failures -> TimeInterval in
            guard case .retry(let delay) = FailureRecovery.plan(
                for: UnsplashError.unexpectedStatus(500), consecutiveFailures: failures
            ) else { return -1 }
            return delay
        }

        #expect(delays == [30, 60, 120, 300, 900, 900, 900, 900])
    }

    @Test("A day APOD filled with videos fixes itself, so it retries")
    func apodVideosRetry() {
        guard case .retry = FailureRecovery.plan(
            for: NASAError.noPhotosFound, consecutiveFailures: 1
        ) else {
            Issue.record("expected retry")
            return
        }
    }

    // MARK: - The cache fallback

    @Test("The cache is reached for when the network is the problem, never when the setup is")
    func cacheFallbackFollowsTheCause() {
        #expect(FailureRecovery.Plan.waitForNetwork.allowsCacheFallback)
        #expect(FailureRecovery.Plan.retry(after: 30).allowsCacheFallback)
        #expect(!FailureRecovery.Plan.userMustAct.allowsCacheFallback)
    }

    @Test("An unknown failure retries rather than stopping the rotation for good")
    func unknownFailuresRetry() {
        struct Mystery: Error {}
        guard case .retry = FailureRecovery.plan(for: Mystery(), consecutiveFailures: 1) else {
            Issue.record("expected retry")
            return
        }
    }
}
