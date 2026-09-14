import Foundation
import Testing
@testable import Wallpaper

/// The sun, worked out on this Mac.
///
/// Pure arithmetic with no macOS in the loop, which makes it exactly the kind
/// of thing this suite is for — and worth pinning hard, because a sign error
/// here is invisible in the UI until the desktop goes dark at breakfast.
/// Every expectation below is an independently published time, not a value
/// this code produced.
@Suite("Solar position")
struct SolarPositionTests {

    private func date(_ iso: String, _ zone: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: zone)!
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func localTime(_ date: Date, _ zone: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: zone)!
        return formatter.string(from: date)
    }

    private func check(
        _ name: String,
        _ coordinate: GeoCoordinate,
        zone: String,
        on iso: String,
        sunrise: String,
        sunset: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let times = SolarPosition.sunriseAndSunset(
            at: coordinate, on: date(iso, zone), calendar: calendar(zone)
        ) else {
            Issue.record("\(name): expected the sun to rise", sourceLocation: sourceLocation)
            return
        }
        #expect(localTime(times.sunrise, zone) == sunrise, sourceLocation: sourceLocation)
        #expect(localTime(times.sunset, zone) == sunset, sourceLocation: sourceLocation)
    }

    // MARK: - Against published times

    @Test("Greenwich at the summer solstice")
    func greenwichSolstice() {
        // The reference case: 51.4769°N on the prime meridian, in UTC, so
        // nothing about the answer can be hidden by a time zone.
        check(
            "Greenwich", GeoCoordinate(latitude: 51.4769, longitude: 0),
            zone: "UTC", on: "2026-06-21T12:00:00Z",
            sunrise: "2026-06-21 03:42", sunset: "2026-06-21 20:20"
        )
    }

    @Test("Tokyo, nine hours the other side of UTC")
    func tokyo() {
        check(
            "Tokyo", GeoCoordinate(latitude: 35.6762, longitude: 139.6503),
            zone: "Asia/Tokyo", on: "2026-06-21T12:00:00+09:00",
            sunrise: "2026-06-21 04:25", sunset: "2026-06-21 19:00"
        )
    }

    @Test("Auckland at +13, where the UTC day is not the local day")
    func aucklandCrossesTheDateLine() {
        // Local noon here is 23:00 UTC the *previous* day. Anchoring the
        // calculation to that UTC day gives yesterday's sunrise, which is the
        // one thing about this that is easy to get wrong and hard to notice.
        check(
            "Auckland", GeoCoordinate(latitude: -36.8485, longitude: 174.7633),
            zone: "Pacific/Auckland", on: "2026-01-15T12:00:00+13:00",
            sunrise: "2026-01-15 06:18", sunset: "2026-01-15 20:42"
        )
    }

    @Test("Honolulu at -10, the other extreme")
    func honolulu() {
        check(
            "Honolulu", GeoCoordinate(latitude: 21.3069, longitude: -157.8583),
            zone: "Pacific/Honolulu", on: "2026-03-20T12:00:00-10:00",
            sunrise: "2026-03-20 06:34", sunset: "2026-03-20 18:42"
        )
    }

    @Test("A day at the equinox is a little over twelve hours, everywhere")
    func equinoxDayLength() throws {
        // Not exactly twelve: sunrise is when the sun's *upper edge* clears the
        // horizon, and refraction lifts it into view before it geometrically
        // gets there. Both are in the 90.833° the calculation uses, and their
        // absence would show up here as a flat 12.00.
        for (name, coordinate, zone) in [
            ("Quito", GeoCoordinate(latitude: -0.1807, longitude: -78.4678), "America/Guayaquil"),
            ("Honolulu", GeoCoordinate(latitude: 21.3069, longitude: -157.8583), "Pacific/Honolulu"),
            ("London", GeoCoordinate(latitude: 51.5072, longitude: -0.1276), "Europe/London"),
        ] {
            let times = try #require(SolarPosition.sunriseAndSunset(
                at: coordinate, on: date("2026-03-20T12:00:00Z", "UTC"), calendar: calendar(zone)
            ), "\(name)")
            let hours = times.sunset.timeIntervalSince(times.sunrise) / 3600
            #expect(hours > 12.0 && hours < 12.3, "\(name) day length \(hours)")
        }
    }

    // MARK: - The poles

    @Test("Inside the Arctic circle the sun does not always rise, and that is not an error")
    func polarDayAndNight() {
        let tromso = GeoCoordinate(latitude: 69.6492, longitude: 18.9553)

        // Polar night: the sun stays down all day.
        #expect(SolarPosition.sunriseAndSunset(
            at: tromso, on: date("2026-12-21T12:00:00+01:00", "Europe/Oslo"),
            calendar: calendar("Europe/Oslo")
        ) == nil)

        // Midnight sun: it stays up all day.
        #expect(SolarPosition.sunriseAndSunset(
            at: tromso, on: date("2026-06-21T12:00:00+02:00", "Europe/Oslo"),
            calendar: calendar("Europe/Oslo")
        ) == nil)
    }

    @Test("Elevation keeps working where sunrise has no answer")
    func elevationSurvivesThePoles() {
        // This is why the brightness target is built on elevation rather than
        // on sunrise: at Tromsø in December there is no sunrise to be relative
        // to, but there is still more light at noon than at midnight.
        let tromso = GeoCoordinate(latitude: 69.6492, longitude: 18.9553)
        let noon = SolarPosition.elevation(
            at: tromso, date: date("2026-12-21T12:00:00+01:00", "Europe/Oslo")
        )
        let midnight = SolarPosition.elevation(
            at: tromso, date: date("2026-12-21T00:00:00+01:00", "Europe/Oslo")
        )

        #expect(noon < 0)          // Never clears the horizon…
        #expect(noon > -5)         // …but only just fails to.
        #expect(midnight < noon - 10)
    }

    @Test("Solar noon is the high point of the day")
    func elevationPeaksAtNoon() {
        let istanbul = GeoCoordinate(latitude: 41.0082, longitude: 28.9784)
        let elevations = stride(from: 0, through: 23, by: 1).map { hour in
            SolarPosition.elevation(
                at: istanbul,
                date: date(String(format: "2026-09-14T%02d:30:00+03:00", hour), "Europe/Istanbul")
            )
        }

        let peak = elevations.firstIndex(of: elevations.max()!)!
        // 12:30 local, give or take the equation of time and the longitude
        // offset from the middle of the time zone.
        #expect(peak == 12 || peak == 13)
        #expect(elevations.min()! < -40)
    }

    // MARK: - Brightness target

    @Test("The target slides through dawn instead of flipping")
    func targetBrightnessIsContinuous() {
        #expect(Sunlight(elevation: -30).targetBrightness == 0)
        #expect(Sunlight(elevation: -6).targetBrightness == 0)
        #expect(Sunlight(elevation: 2).targetBrightness == 0.5)
        #expect(Sunlight(elevation: 10).targetBrightness == 1)
        #expect(Sunlight(elevation: 60).targetBrightness == 1)

        // Strictly increasing in between, which is what "slides" means.
        let ramp = stride(from: -6.0, through: 10.0, by: 1).map { Sunlight(elevation: $0).targetBrightness }
        #expect(zip(ramp, ramp.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test("The three words the menu uses line up with the target")
    func phases() {
        #expect(Sunlight(elevation: -20).phase == .night)
        #expect(Sunlight(elevation: -6.1).phase == .night)
        #expect(Sunlight(elevation: -5.9).phase == .twilight)
        #expect(Sunlight(elevation: 5.9).phase == .twilight)
        #expect(Sunlight(elevation: 6).phase == .day)
        #expect(Sunlight(elevation: 80).phase == .day)
    }

    // MARK: - Coordinates

    @Test("A coordinate that cannot be real is refused")
    func validity() {
        #expect(GeoCoordinate(latitude: 41.0082, longitude: 28.9784).isValid)
        #expect(GeoCoordinate(latitude: -90, longitude: 180).isValid)
        #expect(!GeoCoordinate(latitude: 91, longitude: 0).isValid)
        #expect(!GeoCoordinate(latitude: 0, longitude: 181).isValid)
        // CoreLocation reports a failed fix as 0,0; so does an empty form.
        #expect(!GeoCoordinate(latitude: 0, longitude: 0).isValid)
    }
}
