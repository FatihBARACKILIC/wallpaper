# CLAUDE.md

macOS menu bar app that rotates the desktop wallpaper from Unsplash, NASA APOD and the user's own folders. See README.md for user-facing behaviour.

## Build

```
xcodebuild -project Wallpaper.xcodeproj -scheme Wallpaper -configuration Debug build
xcodebuild test -project Wallpaper.xcodeproj -scheme Wallpaper -destination 'platform=macOS'
```

## Non-obvious constraints

- **App Sandbox is off** on purpose. Distribution is a notarized DMG, not the App Store. Hardened Runtime stays on. Do not re-enable the sandbox — `setDesktopImageURL` and the cache directory depend on this.
- **`LSUIElement = YES`** — no Dock icon. There is no main window; `MenuBarExtra` is the only always-present scene. Settings and onboarding are opened on demand.
- **Idle cost is the primary constraint.** No polling timers, no views alive while the menu is closed, no decoded images held in memory. Scheduling is one run-loop timer armed for the next due date — a single wakeup per interval, with `tolerance` so the system can coalesce it. The one exception is the menu's countdown, which needs a 1 s tick because "now" is not observable state and `nextChangeDate` only moves once an interval; it is driven by `.task`, so it is cancelled with the view and a closed menu still costs nothing.
- **Transitions are faked.** `setDesktopImageURL` has no animation, so `WallpaperFade` covers each screen with a borderless window between the wallpaper and the desktop icons, fades the incoming photo in, swaps the real wallpaper while covered, then holds the cover for 0.5 s because the wallpaper agent applies asynchronously. It is the one place decoded images are held in memory, and only for about a second. The Space re-apply never fades — it runs on every Space switch.
- **Download size is a setting** (`PhotoResolution`), defaulting to the largest screen. `coverAllScreens` takes the largest width *and* the largest height — not the largest screen by area, since an ultra-wide can win on area while being too short for a taller display. `original` drops `w`/`h` but still transcodes to JPEG, because the raw file can be 50 MB. Per-screen mode always sizes to each screen unless the setting is `original`.
- **Every provider narrows to `Artwork`.** Unsplash's `Photo`, NASA's `Entry` and a file on disk all map into it at the edge of their client; nothing downstream knows which one it came from. Everything persisted — `photo-index.json`, `currentWallpapers` — is in `Artwork` terms, so its `init(from:)` carries a migration from the Unsplash-only shape the app used to write. That migration is not cosmetic: an index entry that fails to decode is one that cannot be credited, and `enforce` evicts those *first*, so dropping it would quietly delete every photo an existing user has.
- **`Artwork.Origin` is a safety rule, not a detail.** `.remote` files are downloaded into the cache and may be evicted; `.localFile` ones are the user's, are applied where they lie, and must never be copied, renamed or deleted. `ImageCache.download` throws `CacheError.notDownloadable` rather than accept one — copying a user's file into the cache would put it under the storage limit, where eviction could delete an original.
- **A change costs 2 API requests, not 2 per photo — and only for Unsplash.** `/photos/random?count=N` fetches every photo in one request; the download report is one per photo. So N photos cost `1 + N`. APOD's `count=N` is also a single request and has nothing to report, so it is flat 1. A folder costs nothing. That is `Artwork.Provider.requestCost`, and the interval picker shows the worst case across the sources actually added. The image bytes come from the CDN and cost nothing for any of them.
- **No key is required to run.** `isReady` is "at least one *usable* source", not "has an Unsplash key": a folder-only setup needs no account and no network. `SettingsStore.canUse` decides per source — Unsplash kinds need the Access Key, `apod` needs the NASA key, `folder` always works. The onboarding key step is skippable for the same reason.
- **A failing source is skipped, not fatal.** `fetchAndDownload` shuffles the usable sources and tries each; `isSourceSpecific` decides what moves on to the next (an unplugged folder, a search that matched nothing) and what stops everything (a bad key, an exhausted quota). Without this, one unplugged external drive would freeze the desktop of a user who also has three sources that work.
- **APOD does two things Unsplash never does.** Some days are videos — `Entry.artwork` returns `nil` for anything whose `media_type` is not `image`, which is why the client over-asks by five — and `hdurl` is not always present, so it falls back to `url`. There is no resizing: APOD serves fixed files, so `PhotoResolution` has nothing to act on and `Artwork.downloadURL` only rewrites Unsplash URLs. The file keeps the extension it was served with, because a PNG saved as `.jpg` misinforms every other app that reads the folder.
- **The next photo is always prefetched, and the queue survives a quit.** A wallpaper change should hit the disk, not the network. The queue is persisted under `prefetchedWallpapers` because it used to be in-memory only: `start()` runs `fireIfOverdue()` *before* `prefetchNext()`, so the first change after every launch went to the network — and on a daily or weekly interval that is the only change the user ever sees. `restorePrefetched()` checks every file on disk rather than trusting `Applied.stillExists`, which only looks at user-folder files: a queued cache file is pinned against eviction while the app runs, but nothing pins it across a quit.
- **A rate limit or an outage must not freeze the desktop.** When Unsplash is unreachable, `applyFromCache` rotates through photos already downloaded, avoiding the ones on screen; only when the cache has nothing does the wallpaper stay put. `ImageCache` keeps a `photo-index.json` beside the photo folder recording which `Artwork` each file is, so a re-used file can still be credited. It sits outside the folder so it is never counted towards the storage limit or evicted. Files with no index entry — downloaded before the index existed — are evicted before indexed ones regardless of age: they cannot be credited, so they can never be re-used. Re-using a file reports no download: nothing was downloaded, and it was reported the first time.
- **A failed change retries on its own.** `WallpaperManager.recovery(for:)` sorts failures into "wait for the network", "retry with backoff" and "the user has to fix it" — waiting a whole interval is wrong when the interval is a week. `NWPathMonitor` runs *only* while offline; an idle app has no monitor.
- **A hotspot is the user's own data allowance.** `pauseOnExpensiveNetwork` (on by default) checks `NWPath.isExpensive` / `isConstrained` at the moment a change runs and keeps only the sources that download nothing — a folder still rotates normally. With no folder, `MeteredNetworkError` goes through `handleFailure`, which reaches for the cache first: a hotspot must not freeze the desktop any more than an outage does. The check is `NetworkPath.current()`, a one-shot read, *not* a live monitor — rotation is event-driven, so the path only matters at fire time. The offline monitor also refuses to resume onto a metered path: reconnecting to the same hotspot is not coming back.
- **`AppSettings` decodes field by field, and every new field must too.** The synthesized decoder throws `keyNotFound` for a key an older build never wrote — it does *not* fall back to the property's default — and `SettingsStore` answers a decode failure with `AppSettings()`. A field added without `decodeIfPresent` therefore wipes every source, the interval and the onboarding flag on upgrade, silently. `MeteredNetworkTests` pins this with a stored blob from before the toggle existed.
- **Displays are watched.** `didChangeScreenParametersNotification` (debounced) re-dresses screens from files already on disk; only a newly attached display in per-screen mode costs a request.
- **The wallpaper is stored per display *and Space*.** macOS keeps three scopes in `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`: `AllSpacesAndDisplays`, `Displays/<uuid>` and `Spaces/<uuid>`. System Settings writes `AllSpacesAndDisplays`, which is why picking a wallpaper there covers everything at once. **No public API reaches that scope.** `setDesktopImageURL` writes only the currently visible Space and display, flipping their entry from `linked` to `individual` — so a Space that was never visible while the app ran keeps whatever it had. `activeSpaceDidChangeNotification` therefore re-applies the current photos, immediately and again after 400 ms, because a write during the switch animation can be dropped. Writing the store directly was considered and rejected: the format is undocumented, the image path is a nested binary plist inside an opaque `Configuration` blob, and the wallpaper agent would have to be forced to reload.
- **Rotation must not be discretionary work.** `Scheduler` used `NSBackgroundActivityScheduler`, which is the wrong tool and was replaced. That API submits the activity to `dasd`, which scores every run against system policy; on battery the Charger Plugged In Policy (weight 20) answers `Decision: MNP` — may not proceed. Measured on a discharging Mac, a 5 minute interval was stretched to 23–28 minutes and often skipped entirely. The user set a clock, not a chore the system may defer, so the scheduler owns a `Timer` armed for `nextChangeDate`. Do not go back to a background activity for this.
- **Shortening the interval re-anchors the due date.** `start()` keeps a persisted `nextChangeDate` only when it is within the new interval; otherwise it schedules fresh. Without this, switching from weekly to 5 minutes would change nothing for a week.
- **`nextChangeDate` is persisted** under its own key, separate from `settings`. On launch or wake, a missed change fires immediately — long intervals (1 day, 1 week) span reboots. Because it outlives a settings reset, finishing setup calls `scheduler.reset()` first: otherwise `start()` finds a date long past, fires a change for it, and the first wallpaper lands twice.
- **Only one change runs at a time.** `WallpaperManager.isChanging` drops overlapping changes — two would race on `current` and stack two fade overlays.
- **Uninstalling has to reach four places, not one.** The app is unsandboxed, so `Uninstaller` removes Application Support, the preferences plist, `Caches` and `HTTPStorages`, every login keychain item in `Keychain.all` and the `SMAppService` registration. The user's own photo folders are never touched — the app only ever read them. Anything new the app writes has to be added there too. The preferences plist is the awkward one: it belongs to cfprefsd, which writes its in-memory copy back out *after* the process exits, so emptying the domain and deleting the file still leaves a 42-byte stub. That delete is handed to a detached `/bin/sh` that waits for the pid to go, waits 3 s more, then removes it — measured; a delete racing the flush loses. `Uninstaller.quit()` is the only exit, because that wait is timed against this process. The desktop is put back to `/System/Library/CoreServices/DefaultDesktop.heic` before the photos go, and `WallpaperManager.stopEverything()` runs first so no Space observer re-applies a file that is about to be deleted. One thing is deliberately out of reach: macOS creates a `~/Library/Containers/com.barackilic.Wallpaper` stub (metadata only — the app is unsandboxed and stores nothing there), and `~/Library/Containers` is TCC-protected, so deleting it would need Full Disk Access. Asking for that to remove a 32 KB stub is a worse trade than leaving it; the user can drag it to the Trash in Finder.
- **`NSWorkspace.desktopImageURL(for:)` lags behind writes.** macOS applies the wallpaper via a separate agent, so reading straight after setting returns the *previous* URL. Treat `setDesktopImageURL` not throwing as success; never verify with the getter.

## Local folders

- Scanned recursively, skipping hidden files and package descendants — a `.photoslibrary` or an `.app` is full of images nobody means to see on their desktop. `ImageFile.extensions` is the whitelist.
- Re-scanned on every change rather than watched. A folder watcher is a live resource for something that only matters at change time, which the idle budget does not allow.
- Nothing is ever written. The tests assert the folder is byte-identical after a pick, because this is the one place the app touches files it does not own.
- Selection is through `NSOpenPanel` with `allowsMultipleSelection`. The app is unsandboxed so a plain path is enough — no security-scoped bookmark — but TCC still prompts the first time a folder inside Desktop, Documents or Downloads is read.

## Unsplash API rules (not optional)

- Hitting `photo.links.download_location` after using a photo is required by the API guidelines. It counts against the rate limit; the image bytes from the CDN do not. Verified against the live API: it answers `200` with a `{"url": …}` body and drops `X-Ratelimit-Remaining` by one.
- Attribution is "Photo by <name> on Unsplash", where both the photographer and Unsplash are links. Every outbound Unsplash URL must carry `utm_source` (the user's registered application name) and `utm_medium=referral` — build them with `UnsplashAttribution.link`, never by hand.
- Read `X-Ratelimit-Limit` / `X-Ratelimit-Remaining` from every response and persist them with a timestamp — the gauge must never cost a request to refresh.
- `/photos/random` filters topics by ID, not slug. `UnsplashClient` resolves a slug once via `/topics/<slug>` and caches the ID in UserDefaults.
- A collection is identified by a numeric ID, which means nothing to the user. `SourceEditor` resolves the title via `/collections/<id>` when the source is added and stores it on the `Source`, so the lookup happens once.

## NASA APOD rules

- The API key is required — the user brings their own. `DEMO_KEY` was measured at **10** requests/hour from a single IP, which a hourly rotation outruns; a personal key allows 1000.
- `X-Ratelimit-Limit` / `X-Ratelimit-Remaining` come back in the same headers Unsplash uses, which is why `RateLimit.init(_ response:)` is shared between the two clients.
- `403` is a bad key and `429` is an exhausted quota, so unlike Unsplash the two never have to be told apart.
- Most APOD images are public domain; `copyright` appears only when the picture belongs to the astrophotographer who made it, and the live API pads that value with newlines. When it is present it must be shown.
- The archive page is derived from the date: `apod.nasa.gov/apod/ap<YYMMDD>.html`.

## Secrets

Two keys, both in the **login keychain**, addressed through `Keychain.unsplashAccessKey` and `Keychain.nasaAPIKey`. Add a new one to `Keychain.all` and the uninstaller removes it without anyone having to remember.

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
`Source` parser, attribution links, the request estimate, `Artwork.downloadURL`
and its migration, the APOD mapping, `LocalFolder` scanning and `ImageCache`
naming and eviction. Everything the wallpaper actually touches
— Spaces, displays, the scheduler, the network — is deliberately untested;
mocking it would test the mock, and every real bug there came from macOS
behaving unlike its documentation.

- **The test bundle is hosted in the app, so a test run launches it.** `AppDelegate` checks `XCTestConfigurationFilePath` and skips `start()`, otherwise running the tests would change the developer's own wallpaper.
- `ImageCache` takes `session:` and `directory:`, which is what makes it testable: a `URLProtocol` stub serves the bytes and a temporary folder stands in for Application Support. The stub answers 500 for any URL containing `fail`, so it needs no mutable state and is safe under parallel tests.
- `NASAClient.Entry` is internal rather than private so the mapping — which silently drops the days NASA picked a film — can be tested without the network.
- `UnsplashAttribution.applicationName` is global mutable state. Every test that reads or writes it lives in one `.serialized` suite; putting an attribution assertion anywhere else will flake.

## Conventions

- Keep README.md and this file current when behaviour, settings or architecture change.
- Commit messages describe the change only — no AI attribution or co-author trailers.
