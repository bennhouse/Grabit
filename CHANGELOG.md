# Changelog

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
