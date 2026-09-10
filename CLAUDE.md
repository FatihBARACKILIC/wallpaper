# CLAUDE.md

macOS menu bar app that rotates the desktop wallpaper from Unsplash. See README.md for user-facing behaviour.

## Build

```
xcodebuild -project Wallpaper.xcodeproj -scheme Wallpaper -configuration Debug build
```

## Non-obvious constraints

- **App Sandbox is off** on purpose. Distribution is a notarized DMG, not the App Store. Hardened Runtime stays on. Do not re-enable the sandbox — `setDesktopImageURL` and the cache directory depend on this.
- **`LSUIElement = YES`** — no Dock icon. There is no main window; `MenuBarExtra` is the only always-present scene. Settings and onboarding are opened on demand.
- **Idle cost is the primary constraint.** No polling timers, no views alive while the menu is closed, no decoded images held in memory. Scheduling goes through `NSBackgroundActivityScheduler` so the system can coalesce wakeups.
- **The next photo is always prefetched.** A wallpaper change should hit the disk, not the network.
- **`nextChangeDate` is persisted.** On launch or wake, a missed change fires immediately — long intervals (1 day, 1 week) span reboots.

## Unsplash API rules (not optional)

- Hitting `photo.links.download_location` after using a photo is required by the API guidelines. It counts against the rate limit; the image bytes from the CDN do not.
- Photographer name + link back to the photo must be visible in the UI.
- Read `X-Ratelimit-Limit` / `X-Ratelimit-Remaining` from every response and persist them with a timestamp — the gauge must never cost a request to refresh.

## Secrets

The user's Access Key lives in the Keychain (`kSecUseDataProtectionKeychain`, `kSecAttrAccessibleWhenUnlocked`). Never log it, never write it to UserDefaults, always mask it in the UI.

## Layout

```
Wallpaper/
├─ WallpaperApp.swift     MenuBarExtra + Settings scenes
├─ Menu/                  menu bar content
├─ Onboarding/            first-run setup
├─ Settings/              key, sources, interval, monitor mode, storage
└─ Core/                  Keychain, Settings, Source, UnsplashClient,
                          ImageCache, WallpaperSetter, Scheduler
```

## Conventions

- Keep README.md and this file current when behaviour, settings or architecture change.
- Commit messages describe the change only — no AI attribution or co-author trailers.
