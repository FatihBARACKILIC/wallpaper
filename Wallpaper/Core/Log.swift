import OSLog

/// Diagnostics for the things that are hard to observe from the outside:
/// wallpaper writes, Space switches, display changes.
///
/// Read them with:
///   log show --predicate 'subsystem == "com.barackilic.Wallpaper"' --last 10m
///
/// Never log the Access Key, or any URL that might carry it.
enum Log {
    static let wallpaper = Logger(subsystem: "com.barackilic.Wallpaper", category: "wallpaper")
}
