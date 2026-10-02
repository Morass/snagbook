#!/usr/bin/env bash
# Lay out an invented session under $HOME/Snagbook and make it the one that opens.
# Used for pictures of the window; every name and note in it is made up.
set -euo pipefail
S="$HOME/Snagbook/1a2b3c4d_25-09-2026"
mkdir -p "$S/01-main-menu/media" "$S/02-inventory-drag-drop" "$S/03-save-slot-names"
python3 - "$S" <<'PY'
import sys, zlib, struct
S = sys.argv[1]
def png(w, h, f):
    raw = b"".join(b"\x00" + b"".join(bytes(f(x, y)) for x in range(w)) for y in range(h))
    def ch(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + ch(b"IDAT", zlib.compress(raw)) + ch(b"IEND", b"")
def menu(x, y):
    if 170 < x < 310 and 150 < y < 186: return (236, 236, 236)          # the Start button
    if 150 < x < 330 and 60 < y < 170 and (x + y) % 9 < 5: return (250, 196, 60)  # the logo over it
    return (32 + x // 6, 48 + y // 5, 96 + x // 8)
open(S + "/01-main-menu/media/image-001.png", "wb").write(png(480, 270, menu))
open(S + "/01-main-menu/notes.md", "w").write('---\ntitle: "Main menu"\ncreated: "2026-09-25T18:03:59+02:00"\n---\n\n**Bug:** the logo overlaps the Start button at 1280x720.\n\n![](media/image-001.png)\n\n**Expected:** the logo sits above the buttons.\n')
open(S + "/02-inventory-drag-drop/notes.md", "w").write('---\ntitle: "Inventory: drag & drop"\ncreated: "2026-09-25T18:13:05+02:00"\n---\n\nSteps to reproduce:\n\n1. Open the inventory\n2. Drag a potion onto a full slot\n\n**Actual:** the potion disappears.\n')
open(S + "/03-save-slot-names/notes.md", "w").write('---\ntitle: "Save slot names"\ncreated: "2026-09-25T18:20:41+02:00"\n---\n\n**Idea:** show the play time next to each save slot.\n')
open(S + "/session.json", "w").write('{"created":"2026-09-25T16:03:58Z","format":1,"id":"1a2b3c4d","title":"Build 412 play test","items":[{"created":"2026-09-25T16:03:59Z","folder":"01-main-menu","id":1,"title":"Main menu"},{"created":"2026-09-25T16:13:05Z","folder":"02-inventory-drag-drop","id":2,"title":"Inventory: drag & drop"},{"created":"2026-09-25T16:20:41Z","folder":"03-save-slot-names","id":3,"title":"Save slot names"}],"nextItem":4}')
PY
echo '{"sessionsFolder":"~/Snagbook","lastSession":"~/Snagbook/1a2b3c4d_25-09-2026"}' > "$CONFIG"
