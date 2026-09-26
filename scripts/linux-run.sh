#!/usr/bin/env bash
# Run the built app on a virtual screen with a throwaway home and settings, then clean up
# everything it started. Linux only.
#
#   scripts/linux-run.sh selftest                 the in-app self-test; exits with its verdict
#   scripts/linux-run.sh shot OUT.png [SETUP]     a picture of the window; SETUP is a script
#                                                 run first with $HOME set, to lay out sessions
#   scripts/linux-run.sh capture                  the global screenshot key and a real mouse
#                                                 drag, then an arrow and a circle drawn in the
#                                                 mark-up window and Enter (MARK_SHOT=file.png
#                                                 photographs it); checks the files
#   scripts/linux-run.sh pictures DIR             README pictures: notebook, mark-up, recording
#   scripts/linux-run.sh record                   the same for a recording; REC_SHOT=file.png
#                                                 also photographs the screen while it runs
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="${SNAGBOOK_BIN:-target/release/snagbook}"
mode="${1:?selftest or shot}"
SHOT_SIZE="${SHOT_SIZE:-1180x760}"
T="$(mktemp -d)"
H="$T/home"
mkdir -p "$H"
cleanup() {
  # Helpers started for the throwaway home (file portal, gvfs) outlive the app.
  for p in $(pgrep -u "$(id -u)" 2>/dev/null || true); do
    if { tr '\0' '\n' < "/proc/$p/environ"; } 2>/dev/null | grep -qx "HOME=$H"; then kill "$p" 2>/dev/null || true; fi
  done
  sleep 0.5
  for m in "$H/.gvfs" "$H/.cache/doc"; do fusermount -u "$m" 2>/dev/null || true; done
  rm -rf "$T"
}
trap cleanup EXIT
run_env=(env -i PATH=/usr/bin:/bin HOME="$H" LANG=C.UTF-8 XDG_RUNTIME_DIR="$T" GVFS_DISABLE_FUSE=1 GIO_USE_VFS=local NO_AT_BRIDGE=1
  WEBKIT_DISABLE_DMABUF_RENDERER=1 SNAGBOOK_CONFIG="$T/config.json")
case "$mode" in
  selftest)
    echo "{\"sessionsFolder\":\"~/Snagbook\"}" > "$T/config.json"
    timeout 180 "${run_env[@]}" SNAGBOOK_SELFTEST="${SELFTEST_MODE:-1}" xvfb-run -a -s "-screen 0 1280x800x24" dbus-run-session -- "$BIN" 2>"$T/err.log" | grep -E '^(ok|FAIL|note|SELFTEST)'
    exit "${PIPESTATUS[0]}"
    ;;
  shot)
    out="$(realpath -m "${2:?output png}")"
    echo "{\"sessionsFolder\":\"~/Snagbook\"}" > "$T/config.json"
    if [ -n "${3:-}" ]; then HOME="$H" CONFIG="$T/config.json" bash "$3"; fi
    n=$((90 + RANDOM % 100))
    "${run_env[@]}" xvfb-run -n "$n" -s "-screen 0 ${SHOT_SIZE}x24" sh -c "
      dbus-run-session -- '$BIN' & app=\$!
      sleep ${SHOT_WAIT:-5}
      DISPLAY=:$n xdotool search --sync --name '^Snagbook' windowmove 0 0 windowsize ${SHOT_SIZE%x*} ${SHOT_SIZE#*x} 2>/dev/null || true
      sleep 1
      ${SHOT_KEYS:+DISPLAY=:$n xdotool $SHOT_KEYS; sleep 1;}
      DISPLAY=:$n import -window root '$out'
      kill \$app" >/dev/null 2>&1 || true
    [ -s "$out" ] && echo "$out"
    ;;
  capture)
    CONFIG="$T/config.json" HOME="$H" bash scripts/demo-session.sh
    n=$((90 + RANDOM % 100))
    "${run_env[@]}" xvfb-run -n "$n" -s "-screen 0 1280x800x24" sh -c "
      dbus-run-session -- '$BIN' & app=\$!
      sleep 5
      DISPLAY=:$n xdotool mousemove 640 400 key --clearmodifiers ctrl+alt+s
      sleep 2
      DISPLAY=:$n xdotool mousemove 200 150 mousedown 1 mousemove 360 250 mousemove 520 390 mouseup 1
      sleep 3
      DISPLAY=:$n xdotool key a mousemove 420 320 mousedown 1 mousemove 560 400 mousemove 700 500 mouseup 1
      DISPLAY=:$n xdotool key o mousemove 560 340 mousedown 1 mousemove 650 420 mousemove 760 520 mouseup 1
      sleep 1
      ${MARK_SHOT:+DISPLAY=:$n import -window root '$MARK_SHOT';}
      DISPLAY=:$n xdotool key Return
      sleep 2
      kill \$app" >/dev/null 2>&1 || true
    shot="$H/Snagbook/1a2b3c4d_25-09-2026/03-save-slot-names/media/shot-001.png"
    [ -f "$shot" ] || { echo "FAIL no screenshot was saved"; exit 1; }
    marks="${shot%.png}.marks.json"
    tools=$(python3 -c "import json,sys; print(','.join(m['tool'] for m in json.load(open(sys.argv[1]))['marks']))" "$marks" 2>/dev/null || true)
    [ "$tools" = "arrow,ellipse" ] || { echo "FAIL the marks are '$tools', not arrow,ellipse"; exit 1; }
    [ -f "${shot%.png}.orig.png" ] || { echo "FAIL the original was not kept"; exit 1; }
    size=$(python3 -c "import struct,sys; d=open(sys.argv[1],'rb').read(24); print(*struct.unpack('>II', d[16:24]))" "$shot")
    grep -q 'shot-001.png' "$H/Snagbook/1a2b3c4d_25-09-2026/03-save-slot-names/notes.md" || { echo "FAIL the note does not show it"; exit 1; }
    [ "$size" = "320 240" ] || { echo "FAIL the picture is $size, not 320 240"; exit 1; }
    echo "ok   Ctrl+Alt+S, a drag, an arrow and a circle drawn by mouse, Enter: a 320×240 marked-up screenshot, its original and its marks"
    ;;
  record)
    CONFIG="$T/config.json" HOME="$H" bash scripts/demo-session.sh
    n=$((90 + RANDOM % 100))
    "${run_env[@]}" xvfb-run -n "$n" -s "-screen 0 1280x800x24" sh -c "
      dbus-run-session -- '$BIN' & app=\$!
      sleep 5
      DISPLAY=:$n xdotool mousemove 640 400 key --clearmodifiers ctrl+alt+r
      sleep 2
      DISPLAY=:$n xdotool mousemove 100 100 mousedown 1 mousemove 400 300 mousemove 740 580 mouseup 1
      sleep 1.5
      ${REC_SHOT:+DISPLAY=:$n import -window root '$REC_SHOT';}
      sleep 2
      DISPLAY=:$n xdotool key --clearmodifiers ctrl+alt+r
      sleep 4
      ${REC_AFTER:+DISPLAY=:$n import -window root '$REC_AFTER';}
      kill \$app" >/dev/null 2>&1 || true
    m="$H/Snagbook/1a2b3c4d_25-09-2026/03-save-slot-names/media"
    [ -f "$m/clip-001.mp4" ] || { echo "FAIL no recording was saved"; ls -la "$m" 2>&1; exit 1; }
    dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$m/clip-001.mp4")
    size=$(ffprobe -v error -select_streams v -show_entries stream=width,height -of csv=p=0 "$m/clip-001.mp4")
    stills=$(ls "$m/clip-001-frames" | wc -l)
    grep -q 'clip-001.mp4' "$H/Snagbook/1a2b3c4d_25-09-2026/03-save-slot-names/notes.md" || { echo "FAIL the note does not show it"; exit 1; }
    [ "$size" = "640,480" ] || { echo "FAIL the video is $size, not 640,480"; exit 1; }
    python3 -c "import sys; d=float(sys.argv[1]); sys.exit(0 if 2.5 <= d <= 6 else 1)" "$dur" || { echo "FAIL the video is ${dur}s long"; exit 1; }
    [ -f "$m/clip-001-contact.jpg" ] && [ -f "$m/clip-001.json" ] && [ "$stills" -ge 3 ] || { echo "FAIL companions missing ($stills stills)"; exit 1; }
    echo "ok   Ctrl+Alt+R, a drag, Ctrl+Alt+R: a ${dur}s 640×480 video, $stills stills, a contact sheet and clip-001.json"
    ;;
  pictures)
    # README pictures from the invented session: the notebook, a picture marked up by mouse
    # and keyboard, and a note with a recording. OUT is a directory.
    out="$(realpath -m "${2:?output directory}")"; mkdir -p "$out"
    CONFIG="$T/config.json" HOME="$H" bash scripts/demo-session.sh
    n=$((90 + RANDOM % 100))
    "${run_env[@]}" xvfb-run -n "$n" -s "-screen 0 1280x800x24" sh -c "
      dbus-run-session -- '$BIN' & app=\$!
      sleep 5
      X() { DISPLAY=:$n xdotool \"\$@\"; }
      X mousemove 100 80 click 1; sleep 1.5
      DISPLAY=:$n import -window root -crop 980x720+0+0 +repage '$out/notebook.png'
      X mousemove 510 300 click --repeat 2 --delay 80 1; sleep 3
      X mousemove 575 453 mousedown 1 mousemove 640 453 mousemove 706 453 mouseup 1; sleep 0.5
      X key o; sleep 0.3; X mousemove 552 423 mousedown 1 mousemove 640 460 mousemove 729 489 mouseup 1; sleep 0.5
      X key a; sleep 0.3; X mousemove 855 540 mousedown 1 mousemove 800 515 mousemove 738 487 mouseup 1; sleep 0.5
      X key n; sleep 0.3; X mousemove 540 345 click 1; sleep 0.5
      X key t; sleep 0.3; X mousemove 414 500 click 1; sleep 1.2; X type --delay 40 'logo covers Start'; sleep 0.5; X key Return; sleep 1
      DISPLAY=:$n import -window root -crop 1040x720+120+40 +repage '$out/markup.png'
      X key Escape; sleep 2
      X mousemove 100 109 click 1; sleep 1; X mousemove 100 80 click 1; sleep 1
      X mousemove 640 400 key --clearmodifiers ctrl+alt+r; sleep 2
      X mousemove 272 172 mousedown 1 mousemove 500 300 mousemove 748 438 mouseup 1
      sleep 4; X key --clearmodifiers ctrl+alt+r; sleep 5
      DISPLAY=:$n import -window root -crop 980x720+0+0 +repage '$out/recording.png'
      kill \$app" >/dev/null 2>&1 || true
    ls "$out"
    ;;
  *) echo "selftest, shot, capture, record or pictures" >&2; exit 2 ;;
esac
