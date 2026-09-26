#!/usr/bin/env bash
# Pictures for the README, drawn by the app itself from an invented session in a throwaway
# HOME: docs/images/notebook.png, markup.png, recording.png. Needs a built app (make build)
# and ffmpeg (for the demo recording).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$PWD/docs/images"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
H="$T/home"
S="$H/Snagbook/1a2b3c4d_26-09-2026"
mkdir -p "$S/01-main-menu/media" "$S/02-inventory-drag-drop" "$S/03-recording-the-save-screen/media" "$OUT"
python3 - "$S" <<'PY'
import sys, zlib, struct, json
S = sys.argv[1]
def png(w, h, f):
    raw = b"".join(b"\x00" + b"".join(bytes(f(x, y)) for x in range(w)) for y in range(h))
    def ch(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + ch(b"IDAT", zlib.compress(raw)) + ch(b"IEND", b"")
W, H = 960, 540
def menu(x, y):
    if 360 < x < 600 and 300 < y < 360: return (236, 236, 236)            # the Start button
    if 300 < x < 660 and 120 < y < 330 and (x + y) % 18 < 10: return (250, 196, 60)  # the logo over it
    if 60 < x < 420 and 50 < y < 80: return (240, 240, 240)               # a title bar
    return (32 + x // 12, 48 + y // 10, 96 + x // 16)
open(S + "/01-main-menu/media/image-001.png", "wb").write(png(W, H, menu))
open(S + "/01-main-menu/notes.md", "w").write('---\ntitle: "Main menu"\ncreated: "2026-09-26T18:03:59+02:00"\n---\n\n**Bug:** the logo overlaps the Start button at 1280×720.\n\n![](media/image-001.png)\n\n**Expected:** the logo sits above the buttons.\n')
open(S + "/02-inventory-drag-drop/notes.md", "w").write('---\ntitle: "Inventory: drag & drop"\ncreated: "2026-09-26T18:13:05+02:00"\n---\n\nSteps to reproduce:\n\n1. Open the inventory\n2. Drag a potion onto a full slot\n\n**Actual:** the potion disappears.\n')
open(S + "/03-recording-the-save-screen/notes.md", "w").write('---\ntitle: "Recording: the save screen"\ncreated: "2026-09-26T18:20:41+02:00"\n---\n\nThe progress bar jumps back at the end of saving:\n\n[Recording 0:06](media/clip-001.mp4)\n\n**Idea:** show the play time next to each save slot.\n')
items = [("01-main-menu", 1, "Main menu"), ("02-inventory-drag-drop", 2, "Inventory: drag & drop"), ("03-recording-the-save-screen", 3, "Recording: the save screen")]
json.dump({"created": "2026-09-26T16:03:58Z", "format": 1, "id": "1a2b3c4d", "title": "Build 412 play test",
           "items": [{"created": "2026-09-26T16:0%d:00Z" % i, "folder": f, "id": i, "title": t} for f, i, t in items], "nextItem": 4},
          open(S + "/session.json", "w"), indent=2)
PY
# A six-second demo recording: a progress bar that fills, then jumps back.
M="$S/03-recording-the-save-screen/media"
ffmpeg -hide_banner -loglevel error -f lavfi -i "color=c=0x202838:s=960x540:d=6,format=yuv420p" \
  -vf "drawbox=x=180:y=250:w=600:h=40:color=0x3a4660:t=fill,drawbox=x=180:y=250:w='if(lt(t,4.5),t*130,120)':h=40:color=0x5fb0ff:t=fill" \
  -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$M/clip-001.mp4"
mkdir -p "$M/clip-001-frames"
ffmpeg -hide_banner -loglevel error -ss 3 -i "$M/clip-001.mp4" -frames:v 1 -q:v 3 "$M/clip-001-frames/0001.jpg"
echo "{\"sessionsFolder\":\"~/Snagbook\",\"lastSession\":\"~/Snagbook/1a2b3c4d_26-09-2026\"}" > "$T/config.json"
HOME="$H" SNAGBOOK_CONFIG="$T/config.json" SNAGBOOK_SHOTS="$OUT" build/Snagbook.app/Contents/MacOS/Snagbook 2>/dev/null
