import SwiftUI

/// "Match photos to the sky", plus the location the sun is worked out from.
///
/// The location row does more than collect two numbers: it shows today's
/// sunrise and sunset back, which is the only way a user can tell at a glance
/// that the coordinate is the right one. A wrong location is otherwise
/// invisible until the desktop goes dark at the wrong time of day.
struct SunlightSection: View {
    @Bindable var manager: WallpaperManager

    @State private var isLocating = false
    /// Captured when the lookup starts, not read in the body: asking macOS for
    /// the authorization status means building a `CLLocationManager`, and a
    /// view body runs far too often for that.
    @State private var isAwaitingPermission = false
    @State private var locationError: String?
    @State private var isEditingByHand = false
    @State private var typedLatitude = ""
    @State private var typedLongitude = ""

    private var sunlight: SunlightMatching { manager.settings.settings.sunlight }

    var body: some View {
        Section {
            Toggle("Match photos to the sky", isOn: Binding(
                get: { sunlight.isEnabled },
                set: { new in
                    manager.settings.update { $0.sunlight.isEnabled = new }
                    if new, sunlight.coordinate == nil { locate() }
                }
            ))

            if sunlight.isEnabled {
                locationRow
                locationButtons

                if isEditingByHand {
                    manualEntry
                }

                if let locationError {
                    Text(locationError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Sunlight")
        } footer: {
            Text("Light photos while the sun is up, dark ones after it sets, sliding through dawn and dusk rather than flipping. It is a preference, not a filter — if nothing in a batch suits the hour, the wallpaper still changes. Sunrise and sunset are worked out on this Mac; your location is never sent anywhere.")
        }
    }

    // MARK: - Location

    @ViewBuilder
    private var locationRow: some View {
        LabeledContent("Location") {
            if isLocating {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(isAwaitingPermission ? "Waiting for permission…" : "Locating…")
                        .foregroundStyle(.secondary)
                }
            } else if let coordinate = sunlight.coordinate, coordinate.isValid {
                Text(coordinate.displayName)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text("Not set").foregroundStyle(.secondary)
            }
        }

        // The first lookup includes however long the user takes to answer the
        // system prompt. Saying so is the difference between a wait and a
        // spinner that looks broken.
        if isLocating, isAwaitingPermission {
            Text("macOS is asking whether Wallpaper may use your location.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let times = manager.todaysSunriseAndSunset {
            Text("Today: sunrise \(times.sunrise.formatted(date: .omitted, time: .shortened)), sunset \(times.sunset.formatted(date: .omitted, time: .shortened)). \(skyNow)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if sunlight.coordinate?.isValid == true {
            // Real, and not rare: half the year inside either polar circle.
            Text("The sun neither rises nor sets here today. \(skyNow)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Proof the setting is doing something, in one phrase.
    private var skyNow: String {
        guard let sky = manager.currentSunlight else { return "" }
        let percent = Int((sky.targetBrightness * 100).rounded())
        return "\(sky.phase.displayName) now — looking for photos around \(percent)% brightness."
    }

    private var locationButtons: some View {
        HStack {
            Button(sunlight.coordinate == nil ? "Locate" : "Update location") { locate() }
                .disabled(isLocating)
            Button(isEditingByHand ? "Cancel" : "Enter by hand…") { toggleManualEntry() }
            Spacer()
        }
    }

    /// Two ordinary Form rows rather than a row of squeezed fields. A
    /// `TextField`'s title is the row's *label* here, not its placeholder, so
    /// constraining the field's width narrows the label with it — which is how
    /// "Latitude" ends up hyphenated down the side of a box too small to type
    /// a number in. The example coordinate goes in `prompt`, where a
    /// placeholder belongs.
    @ViewBuilder
    private var manualEntry: some View {
        TextField("Latitude", text: $typedLatitude, prompt: Text("41.0082"))
        TextField("Longitude", text: $typedLongitude, prompt: Text("28.9784"))

        HStack {
            if typedCoordinate == nil, !typedLatitude.isEmpty || !typedLongitude.isEmpty {
                Text("Latitude −90 to 90, longitude −180 to 180, in decimal degrees.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Save") { saveTyped() }
                .disabled(typedCoordinate == nil)
        }
    }


    private var typedCoordinate: GeoCoordinate? {
        guard let latitude = Double(typedLatitude.trimmingCharacters(in: .whitespaces)),
              let longitude = Double(typedLongitude.trimmingCharacters(in: .whitespaces))
        else { return nil }
        let coordinate = GeoCoordinate(latitude: latitude, longitude: longitude)
        return coordinate.isValid ? coordinate : nil
    }

    private func toggleManualEntry() {
        isEditingByHand.toggle()
        guard isEditingByHand else { return }
        typedLatitude = sunlight.coordinate.map { String(format: "%.4f", $0.latitude) } ?? ""
        typedLongitude = sunlight.coordinate.map { String(format: "%.4f", $0.longitude) } ?? ""
        locationError = nil
    }

    private func saveTyped() {
        guard let coordinate = typedCoordinate else { return }
        manager.settings.update {
            $0.sunlight.coordinate = coordinate
            $0.sunlight.updatedAt = Date()
            // Typed by hand, so nothing later re-resolves over the top of it.
            $0.sunlight.isAutomatic = false
        }
        isEditingByHand = false
        locationError = nil
    }

    private func locate() {
        isLocating = true
        isAwaitingPermission = CurrentLocation.isUnasked
        locationError = nil
        Task {
            defer { isLocating = false }
            do {
                let coordinate = try await CurrentLocation.request()
                manager.settings.update {
                    $0.sunlight.coordinate = coordinate
                    $0.sunlight.updatedAt = Date()
                    $0.sunlight.isAutomatic = true
                }
            } catch {
                locationError = error.localizedDescription
                // Every failure here has the same answer, so put it in reach
                // rather than making the user find the button.
                isEditingByHand = true
            }
        }
    }
}
