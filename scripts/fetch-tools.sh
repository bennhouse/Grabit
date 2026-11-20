#!/bin/zsh
# Downloads the command-line tools Grabit bundles, checks them against the published SHA-256
# checksums and unpacks them in vendor/bin (not in the repository). build-app.sh copies vendor/bin
# into the app, in Contents/Resources/bin.
#   scripts/fetch-tools.sh
#
#   yt-dlp  github.com/yt-dlp/yt-dlp        macOS "onedir" build (starts in ~0.3 s; the one-file
#                                            build unpacks itself on every call and takes ~8 s)
#   ffmpeg  ffmpeg.martin-riedl.de          static arm64 build (merging, audio conversion, HEVC)
#   deno    github.com/denoland/deno        JavaScript runtime yt-dlp needs for YouTube
set -euo pipefail
cd "$(dirname "$0")/.."

YTDLP_VERSION="2026.10.26"
FFMPEG_PATH="macos/arm64/1789931890_9.0.2"
DENO_VERSION="v2.9.8"

mkdir -p vendor
DL="vendor/downloads"; mkdir -p "$DL"

get() {   # url file
    [[ -f "$2" ]] || curl -fsSL -o "$2" "$1"
}
check() { # file expected-sha256
    local got=$(shasum -a 256 "$1" | cut -d' ' -f1)
    if [[ "$got" != "$2" ]]; then echo "error: checksum mismatch for $1" >&2; rm -f "$1"; exit 1; fi
}

get "https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION/yt-dlp_macos.zip" "$DL/yt-dlp_macos.zip"
get "https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION/SHA2-256SUMS" "$DL/yt-dlp-SUMS"
check "$DL/yt-dlp_macos.zip" "$(grep ' yt-dlp_macos.zip$' "$DL/yt-dlp-SUMS" | cut -d' ' -f1)"

get "https://ffmpeg.martin-riedl.de/download/$FFMPEG_PATH/ffmpeg.zip" "$DL/ffmpeg.zip"
get "https://ffmpeg.martin-riedl.de/download/$FFMPEG_PATH/ffmpeg.zip.sha256" "$DL/ffmpeg.zip.sha256"
check "$DL/ffmpeg.zip" "$(cut -d' ' -f1 < "$DL/ffmpeg.zip.sha256")"

get "https://github.com/denoland/deno/releases/download/$DENO_VERSION/deno-aarch64-apple-darwin.zip" "$DL/deno.zip"
get "https://github.com/denoland/deno/releases/download/$DENO_VERSION/deno-aarch64-apple-darwin.zip.sha256sum" "$DL/deno.zip.sha256sum"
check "$DL/deno.zip" "$(cut -d' ' -f1 < "$DL/deno.zip.sha256sum")"

rm -rf vendor/bin; mkdir -p vendor/bin/yt-dlp
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
ditto -x -k "$DL/yt-dlp_macos.zip" "$WORK/yt"
ditto "$WORK/yt" vendor/bin/yt-dlp
ditto -x -k "$DL/ffmpeg.zip" "$WORK/ff"; cp "$WORK/ff/ffmpeg" vendor/bin/ffmpeg
ditto -x -k "$DL/deno.zip" "$WORK/de"; cp "$WORK/de/deno" vendor/bin/deno
chmod +x vendor/bin/yt-dlp/yt-dlp_macos vendor/bin/ffmpeg vendor/bin/deno
xattr -cr vendor/bin
echo "Tools ready in vendor/bin:"
echo "  yt-dlp $(vendor/bin/yt-dlp/yt-dlp_macos --version)"
echo "  $(vendor/bin/ffmpeg -version | head -1 | cut -d' ' -f1-3)"
echo "  $(vendor/bin/deno --version | head -1)"
