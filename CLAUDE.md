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
- **Transitions are faked.** `setDesktopImageURL` has no animation, so `WallpaperFade` covers each screen with a borderless window between the wallpaper and the desktop icons, fades the incoming photo in, swaps the real wallpaper while covered, then holds the cover for 0.5 s because the wallpaper agent applies asynchronously. It is the one place decoded images are held in memory, and only for about a second. The Space re-apply never fades — it runs on every Space switch.
- **The next photo is always prefetched.** A wallpaper change should hit the disk, not the network.
- **A failed change retries on its own.** `WallpaperManager.recovery(for:)` sorts failures into "wait for the network", "retry with backoff" and "the user has to fix it" — waiting a whole interval is wrong when the interval is a week. `NWPathMonitor` runs *only* while offline; an idle app has no monitor.
- **Displays are watched.** `didChangeScreenParametersNotification` (debounced) re-dresses screens from files already on disk; only a newly attached display in per-screen mode costs a request.
- **The wallpaper is stored per display *and Space*.** macOS keeps three scopes in `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`: `AllSpacesAndDisplays`, `Displays/<uuid>` and `Spaces/<uuid>`. System Settings writes `AllSpacesAndDisplays`, which is why picking a wallpaper there covers everything at once. **No public API reaches that scope.** `setDesktopImageURL` writes only the currently visible Space and display, flipping their entry from `linked` to `individual` — so a Space that was never visible while the app ran keeps whatever it had. `activeSpaceDidChangeNotification` therefore re-applies the current photos, immediately and again after 400 ms, because a write during the switch animation can be dropped. Writing the store directly was considered and rejected: the format is undocumented, the image path is a nested binary plist inside an opaque `Configuration` blob, and the wallpaper agent would have to be forced to reload.
- **`nextChangeDate` is persisted.** On launch or wake, a missed change fires immediately — long intervals (1 day, 1 week) span reboots.
- **`NSWorkspace.desktopImageURL(for:)` lags behind writes.** macOS applies the wallpaper via a separate agent, so reading straight after setting returns the *previous* URL. Treat `setDesktopImageURL` not throwing as success; never verify with the getter.

## Unsplash API rules (not optional)

- Hitting `photo.links.download_location` after using a photo is required by the API guidelines. It counts against the rate limit; the image bytes from the CDN do not.
- Attribution is "Photo by <name> on Unsplash", where both the photographer and Unsplash are links. Every outbound Unsplash URL must carry `utm_source` (the user's registered application name) and `utm_medium=referral` — build them with `UnsplashAttribution.link`, never by hand.
- Read `X-Ratelimit-Limit` / `X-Ratelimit-Remaining` from every response and persist them with a timestamp — the gauge must never cost a request to refresh.
- `/photos/random` filters topics by ID, not slug. `UnsplashClient` resolves a slug once via `/topics/<slug>` and caches the ID in UserDefaults.
- A collection is identified by a numeric ID, which means nothing to the user. `SourceEditor` resolves the title via `/collections/<id>` when the source is added and stores it on the `Source`, so the lookup happens once.

## Secrets

The user's Access Key lives in the **login keychain**. Do not switch to the data-protection keychain (`kSecUseDataProtectionKeychain`): it returns `errSecMissingEntitlement` without `keychain-access-groups`, and adding that entitlement forces a provisioning profile onto every build and onto the notarized DMG. The login keychain is encrypted at rest and binds the item to the app's code signature, which is the protection this app needs.

Never log the key, never write it to UserDefaults, always mask it in the UI.

## Layout

```
Wallpaper/
├─ WallpaperApp.swift     scenes + AppDelegate (launch and wake hooks)
├─ Menu/                  menu bar panel
├─ Onboarding/            first-run setup, plus the interval/monitor pickers
├─ Settings/              tabbed settings window
├─ Shared/                views used by both setup and settings
└─ Core/                  Keychain, Settings, Source, UnsplashClient, ImageCache,
                          WallpaperSetter, Scheduler, WallpaperManager, LoginItem
```

- **Rotation is started in exactly two places:** `AppDelegate.applicationDidFinishLaunching` for a configured user, and the last step of onboarding. `WallpaperManager.shared` is the single instance both reach.

## Conventions

- Keep README.md and this file current when behaviour, settings or architecture change.
- Commit messages describe the change only — no AI attribution or co-author trailers.
