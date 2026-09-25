#!/usr/bin/env bash
# Run the built app on a virtual screen with a throwaway home and settings, then clean up
# everything it started. Linux only.
#
#   scripts/linux-run.sh selftest                 the in-app self-test; exits with its verdict
#   scripts/linux-run.sh shot OUT.png [SETUP]     a picture of the window; SETUP is a script
#                                                 run first with $HOME set, to lay out sessions
#   scripts/linux-run.sh capture                  the global screenshot key and a real mouse
#                                                 drag; checks the saved picture's size
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
    timeout 120 "${run_env[@]}" SNAGBOOK_SELFTEST=1 xvfb-run -a -s "-screen 0 1280x800x24" dbus-run-session -- "$BIN" 2>"$T/err.log" | grep -E '^(ok|FAIL|note|SELFTEST)'
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
      sleep 2
      kill \$app" >/dev/null 2>&1 || true
    shot="$H/Snagbook/1a2b3c4d_25-09-2026/03-save-slot-names/media/shot-001.png"
    [ -f "$shot" ] || { echo "FAIL no screenshot was saved"; exit 1; }
    size=$(python3 -c "import struct,sys; d=open(sys.argv[1],'rb').read(24); print(*struct.unpack('>II', d[16:24]))" "$shot")
    grep -q 'shot-001.png' "$H/Snagbook/1a2b3c4d_25-09-2026/03-save-slot-names/notes.md" || { echo "FAIL the note does not show it"; exit 1; }
    [ "$size" = "320 240" ] || { echo "FAIL the picture is $size, not 320 240"; exit 1; }
    echo "ok   Ctrl+Alt+S and a mouse drag saved a 320×240 screenshot into the shown item"
    ;;
  *) echo "selftest, shot or capture" >&2; exit 2 ;;
esac
