import Foundation

/// Builds the links used for attribution.
///
/// The Unsplash API guidelines require every link back to Unsplash to carry
/// `utm_source` (the application name as registered with Unsplash) and
/// `utm_medium=referral`. Since each user registers their own application, the
/// name is a setting rather than a constant.
enum UnsplashAttribution {
    static let defaultApplicationName = "Wallpaper"

    /// Kept in sync by `SettingsStore` so views can build links without
    /// threading the name through every layer.
    static var applicationName: String = defaultApplicationName

    static var homeURL: URL {
        link("https://unsplash.com/") ?? URL(string: "https://unsplash.com/")!
    }

    /// Appends the required UTM parameters to an Unsplash URL.
    static func link(_ rawURL: String) -> URL? {
        guard var components = URLComponents(string: rawURL) else { return nil }

        var items = components.queryItems ?? []
        items.removeAll { $0.name == "utm_source" || $0.name == "utm_medium" }
        items.append(contentsOf: [
            URLQueryItem(name: "utm_source", value: utmSource),
            URLQueryItem(name: "utm_medium", value: "referral"),
        ])
        components.queryItems = items

        return components.url
    }

    /// `utm_source` has to survive a query string, so the registered name is
    /// slugified: "My Wallpaper App" -> "my_wallpaper_app".
    private static var utmSource: String {
        let slug = applicationName
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")

        return slug.isEmpty ? "wallpaper" : slug
    }
}
