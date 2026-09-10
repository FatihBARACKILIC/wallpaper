# CLAUDE.md

macOS menu bar app that rotates the desktop wallpaper from Unsplash. See README.md for user-facing behaviour.

## Build

```
xcodebuild -project Wallpaper.xcodeproj -scheme Wallpaper -configuration Debug build
xcodebuild test -project Wallpaper.xcodeproj -scheme Wallpaper -destination 'platform=macOS'
```

## Non-obvious constraints

- **App Sandbox is off** on purpose. Distribution is a notarized DMG, not the App Store. Hardened Runtime stays on. Do not re-enable the sandbox — `setDesktopImageURL` and the cache directory depend on this.
- **`LSUIElement = YES`** — no Dock icon. There is no main window; `MenuBarExtra` is the only always-present scene. Settings and onboarding are opened on demand.
- **Idle cost is the primary constraint.** No polling timers, no views alive while the menu is closed, no decoded images held in memory. Scheduling goes through `NSBackgroundActivityScheduler` so the system can coalesce wakeups.
- **Transitions are faked.** `setDesktopImageURL` has no animation, so `WallpaperFade` covers each screen with a borderless window between the wallpaper and the desktop icons, fades the incoming photo in, swaps the real wallpaper while covered, then holds the cover for 0.5 s because the wallpaper agent applies asynchronously. It is the one place decoded images are held in memory, and only for about a second. The Space re-apply never fades — it runs on every Space switch.
- **Download size is a setting** (`PhotoResolution`), defaulting to the largest screen. `coverAllScreens` takes the largest width *and* the largest height — not the largest screen by area, since an ultra-wide can win on area while being too short for a taller display. `original` drops `w`/`h` but still transcodes to JPEG, because the raw file can be 50 MB. Per-screen mode always sizes to each screen unless the setting is `original`.
- **A change costs 2 API requests, not 2 per photo.** `/photos/random?count=N` fetches every photo in one request; the download report is one per photo. So N photos cost `1 + N`. The image bytes come from the CDN and cost nothing.
- **The next photo is always prefetched.** A wallpaper change should hit the disk, not the network.
- **A rate limit or an outage must not freeze the desktop.** When Unsplash is unreachable, `applyFromCache` rotates through photos already downloaded, avoiding the ones on screen; only when the cache has nothing does the wallpaper stay put. `ImageCache` keeps a `photo-index.json` beside the photo folder recording which `Photo` each file is, so a re-used file can still be credited. It sits outside the folder so it is never counted towards the storage limit or evicted. Files with no index entry — downloaded before the index existed — are evicted before indexed ones regardless of age: they cannot be credited, so they can never be re-used. Re-using a file reports no download: nothing was downloaded, and it was reported the first time.
- **A failed change retries on its own.** `WallpaperManager.recovery(for:)` sorts failures into "wait for the network", "retry with backoff" and "the user has to fix it" — waiting a whole interval is wrong when the interval is a week. `NWPathMonitor` runs *only* while offline; an idle app has no monitor.
- **Displays are watched.** `didChangeScreenParametersNotification` (debounced) re-dresses screens from files already on disk; only a newly attached display in per-screen mode costs a request.
- **The wallpaper is stored per display *and Space*.** macOS keeps three scopes in `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`: `AllSpacesAndDisplays`, `Displays/<uuid>` and `Spaces/<uuid>`. System Settings writes `AllSpacesAndDisplays`, which is why picking a wallpaper there covers everything at once. **No public API reaches that scope.** `setDesktopImageURL` writes only the currently visible Space and display, flipping their entry from `linked` to `individual` — so a Space that was never visible while the app ran keeps whatever it had. `activeSpaceDidChangeNotification` therefore re-applies the current photos, immediately and again after 400 ms, because a write during the switch animation can be dropped. Writing the store directly was considered and rejected: the format is undocumented, the image path is a nested binary plist inside an opaque `Configuration` blob, and the wallpaper agent would have to be forced to reload.
- **`nextChangeDate` is persisted** under its own key, separate from `settings`. On launch or wake, a missed change fires immediately — long intervals (1 day, 1 week) span reboots. Because it outlives a settings reset, finishing setup calls `scheduler.reset()` first: otherwise `start()` finds a date long past, fires a change for it, and the first wallpaper lands twice.
- **Only one change runs at a time.** `WallpaperManager.isChanging` drops overlapping changes — two would race on `current` and stack two fade overlays.
- **Uninstalling has to reach four places, not one.** The app is unsandboxed, so `Uninstaller` removes Application Support, the preferences plist, `Caches` and `HTTPStorages`, the login keychain item and the `SMAppService` registration. Anything new the app writes has to be added there too. The preferences plist is the awkward one: it belongs to cfprefsd, which writes its in-memory copy back out *after* the process exits, so emptying the domain and deleting the file still leaves a 42-byte stub. That delete is handed to a detached `/bin/sh` that waits for the pid to go, waits 3 s more, then removes it — measured; a delete racing the flush loses. `Uninstaller.quit()` is the only exit, because that wait is timed against this process. The desktop is put back to `/System/Library/CoreServices/DefaultDesktop.heic` before the photos go, and `WallpaperManager.stopEverything()` runs first so no Space observer re-applies a file that is about to be deleted.
- **`NSWorkspace.desktopImageURL(for:)` lags behind writes.** macOS applies the wallpaper via a separate agent, so reading straight after setting returns the *previous* URL. Treat `setDesktopImageURL` not throwing as success; never verify with the getter.

## Unsplash API rules (not optional)

- Hitting `photo.links.download_location` after using a photo is required by the API guidelines. It counts against the rate limit; the image bytes from the CDN do not. Verified against the live API: it answers `200` with a `{"url": …}` body and drops `X-Ratelimit-Remaining` by one.
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
├─ WallpaperApp.swift    scenes + AppDelegate (launch and wake hooks)
├─ Menu/                 menu bar panel
├─ Onboarding/           first-run setup, plus the interval/monitor pickers
├─ Settings/             tabbed settings window, plus the uninstall sheet
├─ Shared/               views used by both setup and settings
├─ Assets.xcassets/      AppIcon, generated — see Tools below
└─ Core/                 Keychain, Settings, Source, UnsplashAttribution,
                         UnsplashClient, ImageCache, WallpaperSetter,
                         WallpaperFade, Scheduler, WallpaperManager,
                         LoginItem, Uninstaller, Log
WallpaperTests/         unit tests for the pure logic
Tools/MakeAppIcon.swift draws the app icon:
                        `swift Tools/MakeAppIcon.swift Wallpaper/Assets.xcassets/AppIcon.appiconset`
```

- `Tools/` sits outside `Wallpaper/` on purpose. `Wallpaper/` is a synchronized group, so anything dropped in it is compiled into the app — a build script placed there would break the build.

- **Rotation is started in exactly two places:** `AppDelegate.applicationDidFinishLaunching` for a configured user, and the last step of onboarding. `WallpaperManager.shared` is the single instance both reach.

## Tests

`WallpaperTests` covers what can be checked without macOS in the loop: the
`Source` parser, attribution links, the request estimate, `Photo.downloadURL`
and `ImageCache` naming and eviction. Everything the wallpaper actually touches
— Spaces, displays, the scheduler, the network — is deliberately untested;
mocking it would test the mock, and every real bug there came from macOS
behaving unlike its documentation.

- **The test bundle is hosted in the app, so a test run launches it.** `AppDelegate` checks `XCTestConfigurationFilePath` and skips `start()`, otherwise running the tests would change the developer's own wallpaper.
- `ImageCache` takes `session:` and `directory:`, which is what makes it testable: a `URLProtocol` stub serves the bytes and a temporary folder stands in for Application Support. The stub answers 500 for any URL containing `fail`, so it needs no mutable state and is safe under parallel tests.
- `UnsplashAttribution.applicationName` is global mutable state. Every test that reads or writes it lives in one `.serialized` suite; putting an attribution assertion anywhere else will flake.

## Conventions

- Keep README.md and this file current when behaviour, settings or architecture change.
- Commit messages describe the change only — no AI attribution or co-author trailers.
