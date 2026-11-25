# Changelog

## Unreleased

- No scroll bars in lists (the quality list kept changing width).
- Download queue sidebar rebuilt: it opens and closes in one smooth movement together with the page (the system inspector slid over the page first and moved the page afterwards, with a hitch at the start). It can still be made wider by dragging its edge (250–380 pt).
- The queue is translucent from top to bottom: its top bar and its bottom bar have the same material as the list. The rest of the window is unchanged.
- The line under the top bar is the same over the page and over the queue (colour and thickness of the system's own line).
- **Clear** sits as far from the right edge as **Finished** from the left; the queue's sections can no longer be collapsed.
- Adding to the queue only adds: the queue starts with **Play**. **Stop**, **Pause** and **Play** sit at the right of the queue's top bar. Pause freezes the current download; Stop puts it back at the top of the queue, to start again with Play. The queue goes back to stopped when it has nothing left.
- Player: frame back, play and frame forward on the left; **I** and **O** stacked on the right, each with its time; the clear button after them. In a narrow window the times get shorter (whole seconds) instead of wrapping. Esc clears In and Out. The go-to-In/Out buttons are gone (↑ and ↓ still work).
- Timeline: In and Out are plain dots; a click on a dot puts the playhead exactly on it (dragging doesn't stick to them).
- Format menu: **MP4 · H.264** (or **HEVC (converted)** where the site has no H.264 at that size) and **MP4/MKV · VP9 (original)** (the real codec of the chosen size: VP9, AV1…).
- The preview plays videos that have no combined stream (many 4K and HDR videos): Grabit uses a copy of the site's HLS playlist with only the sharpest H.264 size up to 720p (the VP9/AV1 sizes AVPlayer picked couldn't be decoded, and the preview stayed on the cover). The download quality doesn't change.
- Original soundtrack only: the automatic dubs YouTube adds in other languages are left out, both in the preview (which played the dub in the Mac's language) and in the audio options of the download. No subtitles over the preview.
- Preview much lighter: a light copy (H.264 up to 720p, original audio) is downloaded in a temporary folder while the preview streams, and the player switches to it at the same point; play/pause, seeks and scrubbing no longer wait for the network. The copy is deleted when the video screen closes and at quit.
- The page no longer redraws as a whole at every change: marking or clearing In/Out, play/pause and the running time only redraw what changes (a mark change went from ~65 ms to ~15 ms of work).
- Timeline: the selected part is a rounded bar that reaches the start or the end when only one mark is set; no line following the mouse.
- Volume control next to the time, 50% the first time (then as you leave it).
- Fixed: the site menu didn't open while the queue was open (it was drawn over the page but clicked where it used to be).
- Fixed: a 2160p download stayed at 0%. Some of YouTube's servers didn't answer over IPv6 on this network: downloads now go over IPv4 (and fall back if there is none). yt-dlp updated to 2026.11.23 (the previous one could no longer solve YouTube's "n" challenge).
- Fixed: a crash when stopping a download (a tooltip of a button that disappeared under the mouse).
- In and Out mark at once the position you see: right after a seek (scrubbing, frame steps) the player still reported the old position while the stream loaded, so I or O marked the wrong point and the playhead jumped back. While playing they use the player's own clock.
- Scrubbing follows the mouse: one seek at a time, always to the latest position, instead of a pile of seeks that lagged behind.
- A download refused with "HTTP Error 403: Forbidden" is tried again (up to three times, resuming what was already downloaded).
- Stop, Pause and Play are spaced like separate toolbar buttons. In a narrow window the search field gets narrower so the queue button stays in the bar, and opening the queue widens the window in the same movement.
- Video screen: a status bar at the bottom, as in the other apps (a line on top, the same height as the bar under the queue), with what will be saved: the whole video or the segment.
- Fixed: a video whose thumbnail has another shape than the video (a 4:3 video, a 4:3 thumbnail) pushed the video screen out of the window on both sides.
- The queue opens when something is added to it, and is closed at launch. **Download Now** doesn't open it: the button turns into an App Store style progress ring (click it to stop the download), with a tick at the end.

## 1.3

- The services' logos in one colour, like the system symbols: the text colour in the site menu (white on the highlighted item), grey on the start screen. They follow Light and Dark Mode.

## 1.2

- Icon in the suite's colours: coral, with a light play button and arrow.
- Renamed **Grabit**.
- First launch asks for the permissions in one window (Downloads folder, required; notifications, optional); it opens again from Grabit › Permissions….
- Notifications when a download finishes or fails while Grabit is in the background.
- Installer (scripts/make-dmg.sh): a window with Grabit, an arrow and Applications, like the other apps.
- Start screen centred; a single button to reopen the download queue.
- Site menu and search field centred over the page; they glide to the centre of the window when the queue closes. The start screen fades when the site changes.

## 1.1

- Download queue in a right sidebar: running downloads with progress, queue, finished items; small pause/resume, cancel, retry and show-in-Finder buttons. The queue runs one item at a time and can be paused.
- Video screen: icon-only **Download Now** and **Add to Queue** buttons next to the title, with tooltips.
- Segments: timeline with scrubbing (with sound), frame steps with ← →, In and Out with I and O, ↑ ↓ to jump to them, ⌥X to clear. Only the segment is saved, cut to the exact frame.
- The services' own logos in the site menu.
- Top bar on the left, like a library app rather than a browser; smaller window at first launch (980×600).
- The bundled ffmpeg now finds the system root certificates.

## 1.0

- One window with a top bar: site menu (YouTube by default), search by title or link, downloads button.
- Search on YouTube, YouTube Music and SoundCloud; links from any site yt-dlp supports; playlists open as lists.
- Video screen: vertical or horizontal preview, resolutions up to the video's maximum (4K and the sizes in between), audio quality, Download button next to the title.
- Audio only, as AAC or MP3, with the same choice of quality.
- MP4 that plays everywhere: above 1080p the video is converted to HEVC with the hardware encoder.
- yt-dlp, ffmpeg and deno inside the app; yt-dlp can be updated from the app menu.
