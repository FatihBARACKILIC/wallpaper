# Wallpaper

A lightweight macOS menu bar app that rotates your desktop wallpaper using photos from [Unsplash](https://unsplash.com), on your own schedule and from sources you choose.

Built to stay out of the way: no Dock icon, no windows unless you open them, and near-zero idle resource usage.

## Features

- **Menu bar only** — runs in the background, no Dock icon
- **Your own Unsplash API key** — stored encrypted in the macOS Keychain
- **Multiple sources** — mix topics, collections and search queries; each change picks one at random
- **Flexible schedule** — 5 minutes to 1 week, a custom interval, or manual only
- **Multi-monitor** — same photo on every screen, or a different photo per screen
- **Skip button** — don't like the current photo? Change it instantly
- **Rate limit gauge** — see how much of your hourly Unsplash quota is left
- **Storage limits** — cap the photo cache by count and size, or turn the cap off entirely
- **Findable filenames** — every photo is saved with the photographer, a description and its Unsplash ID
- **Proper attribution** — the photographer is credited and linked in the menu bar, as Unsplash requires

## Requirements

- macOS 26.0 or later
- A free Unsplash API key (the app walks you through getting one)

## Getting an Unsplash API key

1. Sign in at [unsplash.com](https://unsplash.com)
2. Go to [unsplash.com/oauth/applications](https://unsplash.com/oauth/applications) and click **New Application**
3. Accept the API terms and give your application a name
4. Copy the **Access Key** (the Secret Key is not needed)

Enter the name you gave the application during setup as well — Unsplash expects attribution links to identify the application that referred the visit.

New applications start in Demo mode with 50 requests per hour, which is plenty — a wallpaper change costs about 2 requests.

The same instructions are available inside the app, during setup and in Settings.

## Storage

Photos are cached in `~/Library/Application Support/Wallpaper/Photos`, named like:

```
2026-09-10 — Ales Krivec — misty-mountain-lake — Ry9WBo3qmoc.jpg
```

The trailing ID is the Unsplash photo ID, so `unsplash.com/photos/<id>` takes you straight to the original. The source URL is also written to the file's "Where from" metadata, visible in Finder's Get Info.

By default the cache is capped at 100 photos or 1 GB, whichever comes first, evicting oldest first. You can raise, lower or disable the cap in Settings, and clear the cache at any time.

## Attribution

Photos are provided by Unsplash. As the [API guidelines](https://help.unsplash.com/en/articles/2511245-unsplash-api-guidelines) require, the app credits the photographer and links to both their profile and Unsplash with the expected `utm_source` and `utm_medium` parameters, and reports each photo it uses to the download endpoint.

## License

MIT — see [LICENSE](LICENSE).
