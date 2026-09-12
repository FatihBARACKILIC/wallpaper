import Testing
@testable import Wallpaper

/// The request estimate is what warns a user before they outrun a 50/hour demo
/// key. It was wrong once already — it multiplied by the screen count when
/// `/photos/random?count=N` in fact fetches every photo in a single request.
@Suite("Request estimate")
struct RequestEstimateTests {

    private func unsplash(_ photos: Int) -> Int {
        Artwork.Provider.unsplash.requestCost(photosPerChange: photos)
    }

    @Test("One Unsplash change costs one search plus one download report per photo")
    func costPerChange() {
        let hourly = ChangeInterval.seconds(60 * 60)
        #expect(hourly.estimatedRequestsPerHour(costPerChange: unsplash(1)) == 2)
        #expect(hourly.estimatedRequestsPerHour(costPerChange: unsplash(2)) == 3)
        #expect(hourly.estimatedRequestsPerHour(costPerChange: unsplash(3)) == 4)
    }

    @Test("Shorter intervals scale the cost")
    func scalesWithFrequency() {
        #expect(ChangeInterval.seconds(30 * 60).estimatedRequestsPerHour(costPerChange: unsplash(1)) == 4)
        #expect(ChangeInterval.seconds(5 * 60).estimatedRequestsPerHour(costPerChange: unsplash(1)) == 24)
    }

    @Test("Long intervals round up rather than reporting zero cost")
    func roundsUp() {
        #expect(ChangeInterval.seconds(24 * 60 * 60).estimatedRequestsPerHour(costPerChange: unsplash(1)) == 1)
    }

    @Test("Manual changes cost nothing on a schedule")
    func manualIsFree() {
        #expect(ChangeInterval.manual.estimatedRequestsPerHour(costPerChange: unsplash(1)) == 0)
    }

    @Test("A zero screen count is still charged for one photo")
    func atLeastOnePhoto() {
        #expect(ChangeInterval.seconds(60 * 60).estimatedRequestsPerHour(costPerChange: unsplash(0)) == 2)
    }

    @Test("APOD costs one request however many screens there are")
    func apodIsFlat() {
        // Unlike Unsplash it has no download to report, so the screen count
        // cannot inflate it.
        #expect(Artwork.Provider.apod.requestCost(photosPerChange: 1) == 1)
        #expect(Artwork.Provider.apod.requestCost(photosPerChange: 4) == 1)
        #expect(ChangeInterval.seconds(60 * 60).estimatedRequestsPerHour(costPerChange: 1) == 1)
    }

    @Test("A folder on this Mac costs nothing at any interval")
    func foldersAreFree() {
        let cost = Artwork.Provider.local.requestCost(photosPerChange: 4)
        #expect(cost == 0)
        #expect(ChangeInterval.seconds(5 * 60).estimatedRequestsPerHour(costPerChange: cost) == 0)
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
