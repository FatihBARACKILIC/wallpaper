# Wallpaper

Your desktop, with a new photo on it whenever you like.

Wallpaper is a small macOS menu bar app that changes your wallpaper on a schedule you set, using photos from wherever you want them: [Unsplash](https://unsplash.com), [Wallhaven](https://wallhaven.cc), NASA's [picture of the day](https://apod.nasa.gov/apod/astropix.html), or your own folders.

It has no Dock icon and no windows unless you open one. While it waits for the next change it costs 0.004% of a CPU core and a couple of dozen megabytes — which is another way of saying you will forget it is running.

## Install

1. Download `Wallpaper.dmg` from the [latest release](https://github.com/FatihBARACKILIC/wallpaper/releases/latest)
2. Drag **Wallpaper** into **Applications**
3. Right-click it and choose **Open**, then confirm

You need macOS 26 or later. The app runs natively on both Apple Silicon and Intel.

That third step is only needed the first time. This build is signed ad-hoc rather than with a paid Developer ID, so it has not been through Apple's notary service, and macOS greets anything unnotarized with "Apple cannot check it for malicious software." Opening it from the right-click menu tells macOS you meant it. Nothing is wrong with the download.

If you would rather not run unnotarized software — a fair position — [build it yourself](#building-it-yourself) instead. It takes one command.

## Where the photos come from

Add as many sources as you like. Each change picks one of them at random.

| Source | What it gives you | Needs a key? |
| --- | --- | --- |
| **Wallhaven** | The whole site, a search, or a tag | No |
| **Your folders** | Any folders of your own photos, subfolders included | No |
| **Unsplash** | Topics, collections, or a search | A free one |
| **NASA** | The Astronomy Picture of the Day | A free one |

Wallhaven and your own folders work straight out of the box — no account, and folders need no connection at all. The app walks you through getting the other two keys, and keeps them in the macOS Keychain.

To add one, type what you want: `wallhaven` on its own for the whole site, `wallhaven mountains at dusk` for a search, `nasa` for the picture of the day, a paste of a Wallhaven or Unsplash link, or just some words for an Unsplash search.

## What it does while you are not looking

**Changes on your schedule.** Anything from every five minutes to once a week, or only when you ask. A change missed while the Mac was asleep, offline or shut down happens as soon as it can.

**Matches the sky, if you want.** Bright photos while the sun is up, darker ones after it sets, easing through the middle at dawn and dusk. It works out sunrise and sunset from your coordinates on this Mac — no service is called, and the coordinate never leaves the machine. You can type one in by hand instead of granting location access, and if macOS never gets round to showing the permission prompt, typing one works just as well.

**Fits your screen.** Photos shaped like your display are picked first, so a folder full of phone photos doesn't leave you with a heavily cropped portrait across a widescreen monitor. Downloads are sized to your display rather than fetched at full resolution.

**Handles more than one display.** The same photo everywhere, or a different one on each. Spaces you aren't looking at get dressed the moment you switch to them.

**Watches your data.** On a hotspot or cellular connection it stops downloading, keeps rotating your own folders and the photos it already has, and waits for Wi-Fi.

**Keeps going when something breaks.** A source that is out of quota, offline, or on a drive you unplugged is skipped in favour of one that works. If none of them work, it rotates through photos you already have rather than freezing your desktop.

**Fades.** Wallpapers dissolve into each other instead of snapping. You can turn that off.

**Starts with your Mac**, if you switch that on. It is off by default.

## Photos you like, and photos you don't

The menu bar shows who took the photo currently on your desktop, and offers two opinions about it.

**Pin this** keeps it. Pinned photos are never deleted to make room, and you can put one back on the desktop whenever you want.

**Never show again** is final. That photo is never picked again from any source, its downloaded copy is deleted, and if it happened to be on screen the wallpaper changes immediately.

**Previous wallpaper** (⌘[) walks back through the last fifty, one press at a time. Settings › History has all three lists in full, and every row links to where its photo came from — its page on Unsplash or Wallhaven, its day in the NASA archive, or the file itself in Finder.

A wallpaper you choose by hand stays for a full interval. Rotation won't wipe your choice off the screen a minute later.

## Your own photos

**Settings › Sources › Add folders…** takes any number of folders at once. Subfolders count; hidden files and package contents like a Photos library don't.

Your files are read and nothing else. They are never copied into the app's cache, never renamed, never moved, never deleted — the wallpaper is set straight from where the file already sits. That is also why a folder on an external drive is simply skipped while the drive is unplugged, and why blocking one of your own photos only stops the app picking it.

The first time you choose a folder inside Desktop, Documents or Downloads, macOS will ask you to allow it. That is the system's own prompt.

## Getting the two API keys

Both are free and take a couple of minutes. The same instructions are inside the app, during setup and in Settings.

**Unsplash.** Sign in at [unsplash.com](https://unsplash.com), open [your applications](https://unsplash.com/oauth/applications), click **New Application**, accept the terms and name it. Copy the **Access Key** — the Secret Key isn't needed. Enter the name you gave the application too: Unsplash expects attribution links to say which application sent the visitor.

A new application gets 50 requests an hour, which is plenty. One change costs two requests: one to pick the photo, one to report that you used it, as the guidelines require. The image itself costs nothing.

**NASA.** Fill in the short form at [api.nasa.gov](https://api.nasa.gov) and the key arrives by email. There is no account to create. A personal key allows 1000 requests an hour; one change costs one.

Wallhaven needs neither a key nor an account, and its limit — 45 requests a minute — is not something one change at a time can reach.

## Where things are kept

Downloaded photos live in `~/Library/Application Support/Wallpaper/Photos`, named so you can tell what they are:

```
2026-09-10 — Ales Krivec — misty-mountain-lake — Ry9WBo3qmoc.jpg
```

That trailing ID takes you back to the original: `unsplash.com/photos/<id>`, or `wallhaven.cc/w/<id>`. The source link is also written into the file's "Where from" metadata, which Finder shows in Get Info.

By default the folder is capped at 100 photos or 1 GB, whichever fills first, and the oldest go first. You can change or remove the cap, and empty the folder, in Settings. What is on screen and what you pinned is never deleted — so a long list of pins can hold the folder above the cap, which is rather the point of pinning.

## Uninstalling

**Settings › General › Uninstall Wallpaper…** removes the lot: the cached photos and your history, the settings and schedule, the network caches, your two keys in the login keychain, and the open-at-login registration. It puts your desktop back to the macOS default first, and offers to move the app to the Trash. Anything it cannot remove is listed with its path.

Two things it leaves alone on purpose. macOS keeps a metadata stub at `~/Library/Containers/com.barackilic.Wallpaper`; removing it would need Full Disk Access, which this app has no business asking for — drag it to the Trash yourself if it bothers you. And your Unsplash application belongs to you, so delete it on unsplash.com if you want it gone.

Your own photo folders are never touched. The app only ever read them.

## Credit where it is due

Unsplash photos credit the photographer in the menu bar and link to both their profile and Unsplash, with the parameters the [API guidelines](https://help.unsplash.com/en/articles/2511245-unsplash-api-guidelines) ask for, and every photo used is reported to Unsplash's download endpoint.

Most NASA pictures are public domain, but some belong to the astrophotographer who made them. Where the API names a copyright holder, the app shows it.

Wallhaven wallpapers are uploaded by its users and the API names no author, so the menu links to the wallpaper's page and, where the uploader credited one, to the original. Neither is a licence — check the page before you reuse an image somewhere else.

## Building it yourself

```
xcodebuild -project Wallpaper.xcodeproj -scheme Wallpaper -configuration Release build
xcodebuild test -project Wallpaper.xcodeproj -scheme Wallpaper -destination 'platform=macOS'
```

## License

MIT — see [LICENSE](LICENSE).
