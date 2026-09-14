import Foundation
import Testing
@testable import Wallpaper

/// Pausing downloads on a hotspot touches two things worth pinning: which
/// sources may still run, and — far more dangerous — the settings migration
/// that adding the toggle required.
@Suite("Metered network")
struct MeteredNetworkTests {

    // MARK: - Which sources still cost nothing

    @Test("Only a folder downloads nothing")
    func onlyFolderIsFree() {
        #expect(Artwork.Provider.local.needsDownload == false)
        #expect(Artwork.Provider.unsplash.needsDownload == true)
        #expect(Artwork.Provider.apod.needsDownload == true)
        #expect(Artwork.Provider.wallhaven.needsDownload == true)
    }

    @Test("A hotspot and Low Data Mode both count as metered")
    func meteredCases() {
        let hotspot = NetworkPath.Snapshot(isSatisfied: true, isExpensive: true, isConstrained: false)
        let lowData = NetworkPath.Snapshot(isSatisfied: true, isExpensive: false, isConstrained: true)
        let wifi = NetworkPath.Snapshot(isSatisfied: true, isExpensive: false, isConstrained: false)

        #expect(hotspot.isMetered)
        #expect(lowData.isMetered)
        #expect(wifi.isMetered == false)
    }

    // MARK: - The settings migration

    /// The one that would have cost a real user everything. `SettingsStore`
    /// answers a decode failure by falling back to `AppSettings()`, and the
    /// synthesized decoder throws `keyNotFound` for a field a previous build
    /// never wrote — so adding `pauseOnExpensiveNetwork` without a tolerant
    /// decoder would have silently wiped every source on upgrade.
    @Test("Settings written before this toggle existed still load")
    func settingsFromAnOlderBuildSurvive() throws {
        let legacy = """
        {
          "sources": [{"kind":"topic","value":"nature","id":"99BD5089-DC46-4123-A96E-C5FEDEB01C61"}],
          "applicationName": "Wallpaper",
          "interval": {"seconds":{"_0":300}},
          "monitorMode": "sameOnAllScreens",
          "photoResolution": "largestScreen",
          "storageLimit": {"isEnabled":true,"maxPhotos":100,"maxBytes":1073741824},
          "fadeTransition": true,
          "launchAtLogin": false,
          "hasCompletedOnboarding": true
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacy)

        #expect(decoded.sources.count == 1)
        #expect(decoded.sources.first?.value == "nature")
        #expect(decoded.interval == .seconds(300))
        #expect(decoded.hasCompletedOnboarding)
        // The new field takes its default rather than failing the whole decode.
        #expect(decoded.pauseOnExpensiveNetwork)
        // And so does every one added since — this blob predates them all.
        #expect(decoded.sunlight == SunlightMatching())
        #expect(!decoded.sunlight.isEnabled)
    }

    @Test("An empty object decodes to the defaults instead of throwing")
    func emptyObjectIsTolerated() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(decoded == AppSettings())
    }

    @Test("A stored choice of off survives a round trip")
    func roundTrip() throws {
        var settings = AppSettings()
        settings.pauseOnExpensiveNetwork = false

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(decoded.pauseOnExpensiveNetwork == false)
        #expect(decoded == settings)
    }

    @Test("A location survives a round trip, typed or resolved")
    func sunlightRoundTrip() throws {
        var settings = AppSettings()
        settings.sunlight = SunlightMatching(
            isEnabled: true,
            coordinate: GeoCoordinate(latitude: 41.0082, longitude: 28.9784),
            updatedAt: Date(timeIntervalSince1970: 1_789_000_000),
            isAutomatic: false
        )

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(decoded.sunlight == settings.sunlight)
        #expect(decoded.sunlight.isUsable)
    }

    @Test("Sky matching stays off until there is somewhere to compute from")
    func sunlightNeedsALocation() {
        #expect(!SunlightMatching().isUsable)
        // On, but nowhere to put the sun.
        #expect(!SunlightMatching(isEnabled: true).isUsable)
        // A coordinate CoreLocation could not resolve is not a location.
        #expect(!SunlightMatching(
            isEnabled: true, coordinate: GeoCoordinate(latitude: 0, longitude: 0)
        ).isUsable)
        #expect(SunlightMatching(
            isEnabled: true, coordinate: GeoCoordinate(latitude: 41, longitude: 29)
        ).isUsable)
    }

    @Test("Only a resolved location goes stale; a typed one is never overwritten")
    func staleness() {
        let old = Date().addingTimeInterval(-60 * 24 * 60 * 60)
        #expect(SunlightMatching(
            isEnabled: true,
            coordinate: GeoCoordinate(latitude: 41, longitude: 29),
            updatedAt: old,
            isAutomatic: true
        ).isStale)

        // Typed by hand: the user meant it, and no launch re-resolves over it.
        #expect(!SunlightMatching(
            isEnabled: true,
            coordinate: GeoCoordinate(latitude: 41, longitude: 29),
            updatedAt: old,
            isAutomatic: false
        ).isStale)

        #expect(!SunlightMatching(
            isEnabled: true,
            coordinate: GeoCoordinate(latitude: 41, longitude: 29),
            updatedAt: Date(),
            isAutomatic: true
        ).isStale)
    }
}
