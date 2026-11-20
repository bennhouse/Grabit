<img src="Resources/icon-preview.png" width="96" alt="Grabit icon">

# Grabit

Grabit downloads videos and audio from YouTube and the other sites yt-dlp supports. It is a single window: pick a site and search in the top bar, or paste a link.

## How it works

1. **Top bar** (left): back, the site menu with each service's own logo, in one colour like the system symbols (YouTube at every launch), and the search field for a title or a link. A link works whatever site is selected; the menu follows it.
   - Search: YouTube, YouTube Music, SoundCloud.
   - Links only: Vimeo, TikTok, Instagram, X, Facebook, Twitch, Reddit, Dailymotion, Bilibili and any other site yt-dlp knows (about 1,800). Some need a signed-in account and fail without one.
   - You can also drop a link on the window. A playlist or channel link opens as a list.
2. **Results.** Click a video to open it.
3. **Video screen.**
   - Left: the preview, vertical or horizontal like the video, with a timeline. Drag on it to scrub (you hear the sound while dragging). Mark a segment like in an editor:

     | Key | Action |
     | --- | --- |
     | Space | play / pause (also K and L) |
     | ← → | one frame back / forward |
     | ⇧← ⇧→ | one second back / forward |
     | I / O | mark In / Out (Out alone means from the start, In alone to the end) |
     | ↑ ↓ | go to In / Out |
     | ⌥X | clear In and Out |

     With a segment, only that part is saved: the streams are downloaded at full speed, then cut to the exact frame on the Mac with the hardware encoder. (yt-dlp's own section download goes through ffmpeg, which YouTube slows down: 15 s of video took 76 s; this way it takes about 19 s.)
   - Right: the title with two icon buttons, **Download Now** (↩) and **Add to Queue**, then the options: Video / Audio Only, resolution (only what the video really has, up to its maximum), audio quality (AAC streams), format, destination.
   - Video format *MP4 · plays everywhere* (default) is H.264 + AAC; above 1080p YouTube has only AV1/VP9, so Grabit converts to HEVC with the hardware encoder. *MP4 / MKV · original codecs* keeps what the site streams.
   - Audio: *AAC (.m4a)*, saved as streamed when the source is AAC, or *MP3*.
4. **Download queue** (right sidebar, ⌥⌘J or the button at the top right): what is downloading, what waits in the queue, what is finished. Each row has small buttons: pause / resume and cancel while running, remove while queued, show in Finder when done, retry after a failure. The queue downloads one item at a time and can be paused; Download Now starts at once, alongside it.

Files go to Downloads (changeable on the video screen). An existing file is never overwritten: the new one gets " 2", " 3"…

## Tools inside the app

`Contents/Resources/bin` holds, unchanged:

| Tool | Source | Use | License |
| --- | --- | --- | --- |
| yt-dlp 2026.10.26 (macOS onedir build) | github.com/yt-dlp/yt-dlp | reading sites, downloading | Unlicense |
| ffmpeg 9.0.2 (static, arm64) | ffmpeg.martin-riedl.de | merging, audio and HEVC conversion | GPL |
| deno 2.9.8 | github.com/denoland/deno | JavaScript runtime yt-dlp needs for YouTube | MIT |
| service logos (Resources/icons) | simple-icons.org 16.38.0 | site menu, drawn in one colour | CC0 (the logos are their owners' trademarks) |

The ffmpeg binary is distributed unchanged under the GPL; its source is at https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz and the build scripts at https://git.martin-riedl.de/ffmpeg/build-script.

The onedir build of yt-dlp starts in about 0.3 s; the single-file build unpacks itself on every call and takes about 8 s.

Sites change often. **Grabit → Check for yt-dlp Update…** installs the newest yt-dlp release (checked against its SHA-256) in `~/Library/Application Support/Grabit`; it is used instead of the bundled one. **Use the yt-dlp Inside the App** goes back.

Download only what you have the right to download, and respect each site's terms.

## Permissions

On the first launch Grabit asks, in one window, for:

- **Downloads folder** (required): macOS protects Downloads, Desktop and Documents; Grabit and the tools it runs need to write there.
- **Notifications** (optional): a banner when a download finishes or fails while you're in another app.

Network access needs no permission. The window opens again from **Grabit › Permissions…**.

## Building

```
scripts/setup-signing.sh   # once: local signing identity in signing/
scripts/build-app.sh       # downloads the tools if needed, builds, signs, installs in /Applications
scripts/make-dmg.sh        # installer: build/Grabit-<version>.dmg
```

`scripts/fetch-tools.sh` downloads the tools into `vendor/bin` and checks their published checksums. The app is about 270 MB, almost all of it the tools. Apple Silicon only (the bundled ffmpeg and deno are arm64).

Command-line test modes, without the window:

```
GRABIT_TOOLS=vendor/bin .build/debug/Grabit --search youtube "big buck bunny"
GRABIT_TOOLS=vendor/bin .build/debug/Grabit --info URL
GRABIT_TOOLS=vendor/bin .build/debug/Grabit --download URL [--res 2160] [--audio-only] [--audio-format aac|mp3] [--container mp4Compatible|mp4|mkv] [--section 65.5-80.25] [--out DIR]
GRABIT_TOOLS=vendor/bin .build/debug/Grabit --queue-test URL URL [--out DIR]   # queue order and pause/resume
```
