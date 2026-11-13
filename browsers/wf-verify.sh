#!/bin/bash
# wf-verify.sh — prove Waterfox renders a page, on a throwaway Xvfb display (:77).
# Deliberately does NOT touch :20 so the user's live session is never disturbed.
set -u
D=:77
export XDG_RUNTIME_DIR=/tmp/runtime-colab
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"

pkill -f "Xvfb $D" 2>/dev/null
rm -rf /tmp/wf-x; mkdir -p /tmp/wf-x
Xvfb $D -screen 0 1280x800x24 >/tmp/gpu-desk/xvfb77.log 2>&1 &
XPID=$!
sleep 3
DISPLAY=$D xdpyinfo | grep -m1 dimensions || { echo "FAIL: Xvfb not up"; kill $XPID; exit 1; }

DISPLAY=$D waterfox --new-instance -profile /tmp/wf-x -no-remote "https://www.waterfox.com" \
  >/tmp/gpu-desk/wf-x.log 2>&1 &
WPID=$!
for i in $(seq 1 30); do
  sleep 2
  if DISPLAY=$D xdotool search --name "Waterfox" >/dev/null 2>&1; then echo "window up after $((i*2))s"; break; fi
done
sleep 6
DISPLAY=$D import -window root /tmp/gpu-desk/wf_x.png && echo SHOT_OK
echo "waterfox procs: $(pgrep -x waterfox | wc -l)"
tail -5 /tmp/gpu-desk/wf-x.log
pkill -f "profile /tmp/wf-x" 2>/dev/null
sleep 3
kill $XPID 2>/dev/null
echo DONE
