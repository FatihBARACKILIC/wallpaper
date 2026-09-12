# Wallpaper

A lightweight macOS menu bar app that rotates your desktop wallpaper on your own schedule, from sources you choose: [Unsplash](https://unsplash.com), NASA's [Astronomy Picture of the Day](https://apod.nasa.gov/apod/astropix.html), and folders of your own photos.

Built to stay out of the way: no Dock icon, no windows unless you open them, and near-zero idle resource usage.

## Features

- **Menu bar only** — runs in the background, no Dock icon
- **Three kinds of source** — Unsplash, NASA's Astronomy Picture of the Day, and folders of your own photos
- **Multiple sources** — mix as many as you like; each change picks one at random, listed as `t/` topic, `c/` collection, `s/` search, `n/` NASA and `f/` folder
- **Your own photos** — add as many folders as you want, subfolders included. Nothing is uploaded, and your files are never moved, renamed or deleted
- **Works with no key at all** — a setup made only of folders needs no account and no connection
- **Your own API keys** — stored encrypted in the macOS Keychain, one per service
- **Flexible schedule** — nine intervals from 5 minutes to 1 week, or manual only
- **Kind to your data plan** — on cellular or a hotspot it stops downloading, keeps rotating your own folders and photos already saved, and waits for Wi-Fi (macOS spots an iPhone hotspot by itself; for an Android one, switch on Low Data Mode for that network)
- **Multi-monitor** — same photo on every screen, or a different photo per screen
- **Every desktop** — Spaces you aren't looking at are updated as soon as you switch to them
- **Skip button** — don't like the current photo? Change it instantly
- **History** — the last 50 wallpapers, with one click to step back to the one before
- **Pin the ones you like** — a pinned photo is never deleted to make room, and goes back on the desktop whenever you want
- **Never show again** — a photo you reject is never picked again, from any source, and its download is deleted
- **Cross-fade** — wallpapers fade into each other instead of snapping; switchable off
- **Survives interruptions** — a change missed while asleep, offline or shut down happens as soon as it can
- **Keeps going when a source doesn't** — a source that is out of quota, offline or on an unplugged drive is skipped for one that works; if none work, it rotates through photos you already have
- **Rate limit gauges** — see how much of your hourly Unsplash and NASA quota is left
- **Download size** — match the largest display, fit every display, or keep the full resolution
- **Storage limits** — cap the photo cache by count and size, or turn the cap off entirely
- **Findable filenames** — every downloaded photo is saved with its author, a description and its ID
- **Proper attribution** — the photographer is credited and linked in the menu bar, as Unsplash requires; NASA pictures name their copyright holder when they have one
- **Opens at login** — optional, off by default
- **Clean uninstall** — one button removes the photos, settings and your key, and leaves nothing behind

## Requirements

- macOS 26.0 or later
- A free Unsplash API key, if you want Unsplash sources (the app walks you through getting one)
- A free NASA API key, if you want the Astronomy Picture of the Day source

Neither is needed to use folders of your own photos.

## Getting an Unsplash API key

1. Sign in at [unsplash.com](https://unsplash.com)
2. Go to [unsplash.com/oauth/applications](https://unsplash.com/oauth/applications) and click **New Application**
3. Accept the API terms and give your application a name
4. Copy the **Access Key** (the Secret Key is not needed)

Enter the name you gave the application during setup as well — Unsplash expects attribution links to identify the application that referred the visit.

New applications start in Demo mode with 50 requests per hour, which is plenty. A wallpaper change costs one request to pick the photos plus one per photo to report the download, as the API guidelines require — so two requests for a single photo. Downloading the image itself costs nothing.

The same instructions are available inside the app, during setup and in Settings.

## Getting a NASA API key

1. Open [api.nasa.gov](https://api.nasa.gov) and fill in the short signup form
2. The key arrives by email straight away — there is no account to create
3. Paste it into **Settings › Account › NASA**

A personal key allows 1000 requests per hour. A wallpaper change costs one, because APOD returns every photo in a single request and has no download to report.

## Using your own photos

**Settings › Sources › Add folders…** takes any number of folders, and you can pick several at once. Subfolders are included; hidden files and package contents such as a Photos library are not.

Folder photos cost no requests and need no connection, and they are used exactly where they lie — the app never copies them into its cache, so the storage limit and its eviction can never touch your originals. A folder on an external drive is simply skipped while the drive is unplugged.

The first time you pick a folder inside Desktop, Documents or Downloads, macOS asks you to grant access. That is the system's own permission prompt, and the app reads nothing else.

## History, pinning and blocking

The menu bar credits the photo on screen and offers two verdicts on it. **Pin this** keeps it: a pinned photo is never deleted to make room for new ones, and can be put back on the desktop at any time. **Never show again** drops it for good — it is never picked again from any source, not even from the photos already downloaded, and its downloaded copy is deleted. If it was the wallpaper at the time, the wallpaper changes there and then.

**Previous wallpaper** (⌘[) steps back through the last 50 wallpapers, and pressing it again keeps walking back rather than bouncing between two photos. **Recent wallpapers** in the menu lists the ones just behind you; **Settings › History** has all three lists in full, with the last 50, the pinned and the blocked on their own shelves.

Every row links to where its photo came from: its page on Unsplash, its day in the NASA APOD archive, or the file itself in Finder.

A wallpaper you pick by hand stays for a full interval, so rotation doesn't wipe your choice off the screen moments later. A downloaded photo whose file has since been evicted is fetched again when you put it back up. Photos from your own folders are used where they lie, so one you have deleted yourself is simply marked as no longer on this Mac — and blocking one only stops the app picking it. Your file is left exactly where it is.

## Storage

Photos are cached in `~/Library/Application Support/Wallpaper/Photos`, named like:

```
2026-09-10 — Ales Krivec — misty-mountain-lake — Ry9WBo3qmoc.jpg
```

The trailing ID is the Unsplash photo ID, so `unsplash.com/photos/<id>` takes you straight to the original. The source URL is also written to the file's "Where from" metadata, visible in Finder's Get Info.

Only downloaded photos are cached. Photos from your own folders are never copied here, so they are never counted towards the limit and never evicted.

By default the cache is capped at 100 photos or 1 GB, whichever comes first, evicting oldest first. You can raise, lower or disable the cap in Settings, and clear the cache at any time. The wallpapers currently on screen and the photos you pinned are never evicted and never cleared — so a long list of pins can keep the folder above the limit, which is the point of pinning.

## Uninstalling

**Settings › General › Uninstall Wallpaper…** removes everything the app has put on this Mac:

- the cached photos, their index and your history, pins and blocks in `~/Library/Application Support/Wallpaper`
- settings, sources and the rotation schedule in `~/Library/Preferences`
- the network caches in `~/Library/Caches` and `~/Library/HTTPStorages`
- your Unsplash Access Key and NASA API key in the login keychain
- the "open at login" registration

It optionally moves the app itself to the Trash, and puts your desktop back to the macOS default wallpaper first — Spaces you aren't looking at keep the old photo until you pick one yourself in System Settings. Anything it fails to remove is listed with its path so you can finish by hand.

Two things it deliberately leaves alone. macOS keeps a metadata-only stub at `~/Library/Containers/com.barackilic.Wallpaper`; removing it would need Full Disk Access, which this app should never ask for — drag it to the Trash in Finder if you want it gone. And your Unsplash application on unsplash.com is yours: delete it there. Your own photo folders are never touched — the app only ever reads them.

## Attribution

Photos from Unsplash are provided by Unsplash. As the [API guidelines](https://help.unsplash.com/en/articles/2511245-unsplash-api-guidelines) require, the app credits the photographer and links to both their profile and Unsplash with the expected `utm_source` and `utm_medium` parameters, and reports each photo it uses to the download endpoint.

NASA's Astronomy Picture of the Day is served by [api.nasa.gov](https://api.nasa.gov). Most APOD images are public domain, but some are copyrighted by the astrophotographer who made them; where the API names a copyright holder, the app shows it in the menu bar. Check the picture's own page before reusing it anywhere else.

## Building from source

```
xcodebuild -project Wallpaper.xcodeproj -scheme Wallpaper -configuration Release build
xcodebuild test -project Wallpaper.xcodeproj -scheme Wallpaper -destination 'platform=macOS'
```

## License

MIT — see [LICENSE](LICENSE).
