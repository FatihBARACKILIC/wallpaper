# Wallpaper

A new photo on your desktop, as often as you like.

Wallpaper sits in your menu bar and changes your desktop picture on whatever schedule suits you — every few minutes, once a day, once a week, or only when you press the button. The photos come from wherever you want them: [Unsplash](https://unsplash.com), [Wallhaven](https://wallhaven.cc), NASA's [picture of the day](https://apod.nasa.gov/apod/astropix.html), or your own folders.

There is no Dock icon and no window to leave open. It sits quietly until it is time for the next photo, and it is light enough that you will forget it is there.

## Install

1. Download `Wallpaper.dmg` from the [latest release](https://github.com/FatihBARACKILIC/wallpaper/releases/latest)
2. Open it and drag **Wallpaper** into your **Applications** folder
3. Double-click it. macOS will say it cannot verify the app — click **Done**
4. Open **System Settings → Privacy & Security**, scroll to the bottom, and click **Open Anyway**

You need macOS 15 Sequoia or later.

**Why the extra step?** Apple charges developers a yearly fee to have their apps checked and approved. This one has not been through that process, so macOS stops it the first time and asks you to say, once, that you meant it. You will not be asked again. Nothing is wrong with the download.

## Choosing where your photos come from

Add as many sources as you like. Each time the wallpaper changes, one of them is picked at random.

| | What you get | Sign-up needed? |
| --- | --- | --- |
| **Wallhaven** | Wallpapers from the whole site, a search, or a tag | None |
| **Your own folders** | Any folders of photos on your Mac, subfolders included | None |
| **Unsplash** | Photography by topic, collection, or search | A free key |
| **NASA** | The Astronomy Picture of the Day | A free key |

To add one, just type what you want: `wallhaven` for the whole site, `wallhaven mountains at dusk` for a search, `nasa` for the picture of the day, or a few words for an Unsplash search. Pasting a link from Unsplash or Wallhaven works too.

Wallhaven and your own folders need no account, no key and no sign-up. If you never want to create an account anywhere, you can use the app happily with just those two.

## What it does

**Changes on your schedule.** Anything from every five minutes to once a week, or never unless you ask. If your Mac was asleep or switched off when a change was due, it happens as soon as you are back.

**Follows the sun, if you want it to.** Bright photos during the day, darker ones at night, easing between the two at dawn and dusk. Your Mac works this out from your location by itself — nothing is sent anywhere, and you can simply type in a latitude and longitude if you would rather not share your location at all.

**Picks photos that suit your screen.** Ones shaped like your display come first, so a folder of phone photos doesn't leave you with a badly cropped portrait stretched across a wide monitor.

**Handles several displays.** The same photo on each, or a different one everywhere. Desktops you aren't looking at are updated the moment you switch to them.

**Watches your data.** On a phone hotspot it stops downloading, carries on with your own photos and the ones it already has, and waits for Wi-Fi.

**Doesn't give up.** If one source is down, out of quota, or on a drive you unplugged, it quietly uses another. If none of them work, it reuses photos you already have rather than leaving your desktop stuck.

**Fades between photos** instead of snapping, which you can turn off.

**Can start when your Mac does.** Off unless you switch it on.

## Photos you love, and photos you don't

The menu bar shows who took the photo you are looking at, and lets you say what you think of it.

**Pin this** keeps it. Pinned photos are never deleted to make space, and you can put one back on your desktop whenever you want.

**Never show again** gets rid of it for good. It won't be picked again from any source, its copy is deleted, and if it was on your desktop at the time, it changes straight away.

**Previous wallpaper** (⌘[) steps back through the last fifty photos, one press at a time. Settings › History has the full lists, and every row takes you to where the photo came from.

Pick a photo yourself and it stays for a full turn — the schedule won't wipe your choice away a minute later.

## Using your own photos

**Settings › Sources › Add folders…** takes as many folders as you like, all at once. Subfolders are included. Hidden files and things like your Photos library are left out.

Your photos are only ever read. They are never copied, renamed, moved or deleted — the app sets your wallpaper straight from where the file already sits. A folder on an external drive is simply skipped while the drive is unplugged.

The first time you pick a folder inside Desktop, Documents or Downloads, macOS will ask if you want to allow it. That prompt is from macOS, not from this app.

## The two free keys

Unsplash and NASA ask you to register before their photos can be used. Both are free, take about two minutes, and the app shows you these same steps while you set it up.

**For Unsplash:** sign in at [unsplash.com](https://unsplash.com), go to [your applications](https://unsplash.com/oauth/applications), click **New Application**, accept the terms and give it a name. Copy the **Access Key** and paste it into the app, along with the name you chose. The free allowance is far more than changing your wallpaper will ever use.

**For NASA:** fill in the short form at [api.nasa.gov](https://api.nasa.gov) and the key arrives by email within seconds. There is no account to create.

Your keys are kept in your Mac's Keychain, the same place Safari keeps your passwords.

## Where your photos are kept

Downloaded photos are saved in your Library folder, with names that tell you what they are:

```
2026-09-10 — Ales Krivec — misty-mountain-lake — Ry9WBo3qmoc.jpg
```

You can open the folder any time from **Settings › Storage › Show in Finder**, and every photo remembers where it came from — Finder's Get Info will show you the page it was downloaded from.

The app keeps up to 100 photos or 1 GB, whichever comes first, and deletes the oldest to make room. You can change that, or empty the folder entirely, in Settings. Anything you pinned, and whatever is currently on your desktop, is never deleted.

## Removing it

**Settings › General › Uninstall Wallpaper…** takes everything back out: the saved photos, your settings and history, your keys, and the start-up entry. Your desktop is set back to the macOS default, and you are offered the chance to move the app itself to the Trash.

Your own photo folders are untouched. The app only ever read them.

## About the photographs

The photos belong to the people who took them, not to this app. Unsplash photography credits the photographer in the menu bar and links to their profile. NASA pictures name their copyright holder when there is one, though most are public domain. Wallhaven wallpapers are uploaded by its users, so the menu links to the wallpaper's page and, where the uploader gave one, to the original.

If you want to use one of these photos for something else — a blog post, a print, anything beyond your own desktop — follow the link and check what its licence actually allows first.

## For developers

The app is written in Swift and SwiftUI, and builds with no dependencies:

```
xcodebuild -project Wallpaper.xcodeproj -scheme Wallpaper -configuration Release build
xcodebuild test -project Wallpaper.xcodeproj -scheme Wallpaper -destination 'platform=macOS'
```

Building it yourself also sidesteps the right-click step in the install instructions. `CLAUDE.md` documents the decisions behind the design.

Released under the MIT licence — see [LICENSE](LICENSE).
