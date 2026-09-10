import Testing
@testable import Wallpaper

/// The request estimate is what warns a user before they outrun a 50/hour demo
/// key. It was wrong once already — it multiplied by the screen count when
/// `/photos/random?count=N` in fact fetches every photo in a single request.
@Suite("Request estimate")
struct RequestEstimateTests {

    @Test("One change costs one search plus one download report per photo")
    func costPerChange() {
        let hourly = ChangeInterval.seconds(60 * 60)
        #expect(hourly.estimatedRequestsPerHour(photosPerChange: 1) == 2)
        #expect(hourly.estimatedRequestsPerHour(photosPerChange: 2) == 3)
        #expect(hourly.estimatedRequestsPerHour(photosPerChange: 3) == 4)
    }

    @Test("Shorter intervals scale the cost")
    func scalesWithFrequency() {
        #expect(ChangeInterval.seconds(30 * 60).estimatedRequestsPerHour(photosPerChange: 1) == 4)
        #expect(ChangeInterval.seconds(5 * 60).estimatedRequestsPerHour(photosPerChange: 1) == 24)
    }

    @Test("Long intervals round up rather than reporting zero cost")
    func roundsUp() {
        #expect(ChangeInterval.seconds(24 * 60 * 60).estimatedRequestsPerHour(photosPerChange: 1) == 1)
    }

    @Test("Manual changes cost nothing on a schedule")
    func manualIsFree() {
        #expect(ChangeInterval.manual.estimatedRequestsPerHour(photosPerChange: 1) == 0)
    }

    @Test("A zero screen count is still charged for one photo")
    func atLeastOnePhoto() {
        #expect(ChangeInterval.seconds(60 * 60).estimatedRequestsPerHour(photosPerChange: 0) == 2)
    }
}

@Suite("Storage limit")
struct StorageLimitTests {

    @Test("Defaults are the ones the UI promises")
    func defaults() {
        let limit = StorageLimit()
        #expect(limit.isEnabled)
        #expect(limit.maxPhotos == 100)
        #expect(limit.maxBytes == 1_073_741_824)
    }

    @Test("Unlimited means eviction is off")
    func unlimited() {
        #expect(!StorageLimit.unlimited.isEnabled)
    }
}
