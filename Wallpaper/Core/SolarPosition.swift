import Foundation

/// Where on Earth the user is. Two numbers, and nothing else — the app has no
/// use for an address and never asks for one.
nonisolated struct GeoCoordinate: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double

    /// Rejects the values CoreLocation uses to mean "no fix", and anything a
    /// typed-in coordinate could not be.
    var isValid: Bool {
        latitude >= -90 && latitude <= 90
            && longitude >= -180 && longitude <= 180
            && !(latitude == 0 && longitude == 0)
    }

    /// `41.008°N, 28.978°E` — what the settings row shows back.
    var displayName: String {
        let ns = latitude >= 0 ? "N" : "S"
        let ew = longitude >= 0 ? "E" : "W"
        return String(format: "%.3f°%@, %.3f°%@", abs(latitude), ns, abs(longitude), ew)
    }
}

/// How much daylight there is, in the only three words worth saying about it.
nonisolated enum SolarPhase: String, Sendable {
    case night
    case twilight
    case day

    var displayName: String {
        switch self {
        case .night: "Night"
        case .twilight: "Twilight"
        case .day: "Daylight"
        }
    }
}

/// The state of the sky at one place and moment, and the brightness of photo
/// that suits it.
nonisolated struct Sunlight: Hashable, Sendable {
    /// The sun's altitude above the horizon, in degrees. Negative after dark.
    let elevation: Double

    /// Runs 0 (pick the darkest photo on offer) to 1 (pick the brightest).
    ///
    /// Tied to the sun's altitude rather than to clock time, because that is
    /// what actually differs between a June evening in Oslo and a December one.
    /// The ends are −6° — where civil twilight gives out and the sky is dark —
    /// and +10°, by which point the sun is properly up; in between it slides,
    /// so the desktop shifts through dawn instead of flipping at a threshold.
    var targetBrightness: Double {
        min(1, max(0, (elevation + 6) / 16))
    }

    var phase: SolarPhase {
        switch elevation {
        case ..<(-6): .night
        case ..<6: .twilight
        default: .day
        }
    }
}

/// Sunrise, sunset and the sun's current altitude, worked out on this Mac.
///
/// The NOAA solar position equations, which need nothing but a date and a
/// coordinate: no network, no API key, no service that can go away. Accurate to
/// well under a minute for the latitudes people live at, which is far more than
/// picking a photo requires — it is the displayed sunrise time that has to look
/// right.
///
/// Everything here is pure, so it is all covered by the tests. Note that the
/// polar cases are real, not theoretical: above the Arctic circle the sun does
/// not rise in December, and `sunriseAndSunset` says so by returning `nil`
/// rather than inventing a time. `elevation` keeps working there, which is why
/// it — and not sunrise — is what the brightness target is built on.
nonisolated enum SolarPosition {

    /// The sun's altitude above the horizon, in degrees.
    static func elevation(at coordinate: GeoCoordinate, date: Date = Date()) -> Double {
        let century = julianCentury(date)
        let declination = solarDeclination(century)
        let latitude = radians(coordinate.latitude)

        // True solar time: clock time corrected for the equation of time and
        // for how far the user is from the middle of their time zone.
        let minutesUTC = minutesIntoUTCDay(date)
        var trueSolar = minutesUTC + equationOfTime(century) + 4 * coordinate.longitude
        trueSolar = trueSolar.truncatingRemainder(dividingBy: 1440)
        if trueSolar < 0 { trueSolar += 1440 }

        let hourAngle = radians(trueSolar / 4 - 180)
        let cosZenith = sin(latitude) * sin(declination)
            + cos(latitude) * cos(declination) * cos(hourAngle)

        return 90 - degrees(acos(min(1, max(-1, cosZenith))))
    }

    static func sunlight(at coordinate: GeoCoordinate, date: Date = Date()) -> Sunlight {
        Sunlight(elevation: elevation(at: coordinate, date: date))
    }

    /// Sunrise and sunset for the day `date` falls in, in that place's own
    /// local day.
    ///
    /// `nil` when the sun stays up or stays down for the whole day — which is
    /// not an error and not rare: it is half the year inside either polar
    /// circle.
    static func sunriseAndSunset(
        at coordinate: GeoCoordinate,
        on date: Date = Date(),
        calendar: Calendar = .current
    ) -> (sunrise: Date, sunset: Date)? {
        let startOfDay = calendar.startOfDay(for: date)
        // Noon, not midnight: the declination is taken once for the day, and
        // taking it in the middle halves the error at the ends.
        let noon = startOfDay.addingTimeInterval(12 * 3600)

        let century = julianCentury(noon)
        let declination = solarDeclination(century)
        let latitude = radians(coordinate.latitude)

        // The hour angle at which the sun's centre sits 0.833° below the
        // horizon — its own radius plus the refraction that lifts it into view.
        let cosHourAngle = cos(radians(90.833)) / (cos(latitude) * cos(declination))
            - tan(latitude) * tan(declination)
        guard cosHourAngle >= -1, cosHourAngle <= 1 else { return nil }

        let hourAngle = degrees(acos(cosHourAngle))
        let solarNoonUTC = 720 - 4 * coordinate.longitude - equationOfTime(century)

        // `solarNoonUTC` counts minutes into the *UTC* day, and the UTC day
        // containing solar noon is not always the one containing local noon —
        // at +13 or −11 it is the day either side. Anchor to whichever UTC
        // midnight puts solar noon nearest the local noon we were asked about,
        // or Auckland gets yesterday's sunrise.
        let dayStartUTC = [-86400.0, 0, 86400.0]
            .map { utcMidnight(before: noon).addingTimeInterval($0) }
            .min {
                abs($0.addingTimeInterval(solarNoonUTC * 60).timeIntervalSince(noon))
                    < abs($1.addingTimeInterval(solarNoonUTC * 60).timeIntervalSince(noon))
            }!

        let sunrise = dayStartUTC.addingTimeInterval((solarNoonUTC - 4 * hourAngle) * 60)
        let sunset = dayStartUTC.addingTimeInterval((solarNoonUTC + 4 * hourAngle) * 60)
        return (sunrise, sunset)
    }

    // MARK: - NOAA equations

    private static func julianCentury(_ date: Date) -> Double {
        // 2440587.5 is the Julian day at the Unix epoch.
        let julianDay = date.timeIntervalSince1970 / 86400 + 2_440_587.5
        return (julianDay - 2_451_545) / 36525
    }

    /// Degrees, positive when the sun is north of the equator.
    private static func solarDeclination(_ t: Double) -> Double {
        let meanLongitude = (280.46646 + t * (36000.76983 + t * 0.0003032))
            .truncatingRemainder(dividingBy: 360)
        let meanAnomaly = radians(357.52911 + t * (35999.05029 - 0.0001537 * t))

        let centre = sin(meanAnomaly) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(2 * meanAnomaly) * (0.019993 - 0.000101 * t)
            + sin(3 * meanAnomaly) * 0.000289

        let trueLongitude = meanLongitude + centre
        let apparentLongitude = trueLongitude - 0.00569
            - 0.00478 * sin(radians(125.04 - 1934.136 * t))

        return asin(sin(obliquity(t)) * sin(radians(apparentLongitude)))
    }

    /// Minutes by which a sundial runs ahead of the clock.
    private static func equationOfTime(_ t: Double) -> Double {
        let meanLongitude = radians(
            (280.46646 + t * (36000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        )
        let meanAnomaly = radians(357.52911 + t * (35999.05029 - 0.0001537 * t))
        let eccentricity = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let y = pow(tan(obliquity(t) / 2), 2)

        let value = y * sin(2 * meanLongitude)
            - 2 * eccentricity * sin(meanAnomaly)
            + 4 * eccentricity * y * sin(meanAnomaly) * cos(2 * meanLongitude)
            - 0.5 * y * y * sin(4 * meanLongitude)
            - 1.25 * eccentricity * eccentricity * sin(2 * meanAnomaly)

        return 4 * degrees(value)
    }

    /// Tilt of the Earth's axis, corrected for nutation. Radians.
    private static func obliquity(_ t: Double) -> Double {
        let mean = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        return radians(mean + 0.00256 * cos(radians(125.04 - 1934.136 * t)))
    }

    // MARK: - Time helpers

    private static func minutesIntoUTCDay(_ date: Date) -> Double {
        let seconds = date.timeIntervalSince1970
        let intoDay = seconds - (seconds / 86400).rounded(.down) * 86400
        return intoDay / 60
    }

    private static func utcMidnight(before date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (seconds / 86400).rounded(.down) * 86400)
    }

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    private static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
}
