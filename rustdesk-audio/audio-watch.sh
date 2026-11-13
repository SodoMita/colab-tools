#!/bin/bash
# Samples PulseAudio + RustDesk IPC sockets + peer logs for 6 minutes.
# Read-only; changes nothing.
OUT=/tmp/audio-watch.log
L_COLAB=/home/colab/.local/share/logs/RustDesk/rustdesk_rCURRENT.log
L_ROOT=/root/.local/share/logs/RustDesk/rustdesk_rCURRENT.log
: > "$OUT"
for i in $(seq 1 120); do
  L="$L_COLAB"
  [ -f "$L" ] || L="$L_ROOT"
  {
    echo "--- $(date +%H:%M:%S) ---"
    echo "clients:        $(pactl list short clients 2>/dev/null | awk '{print $3}' | grep -v '^$' | sort -u | tr '\n' ' ')"
    echo "source-outputs: $(pactl list short source-outputs 2>/dev/null | wc -l)"
    echo "rustdesk-recs:  $(pactl list short source-outputs 2>/dev/null | grep -ci rustdesk)"
    echo "peer-procs:     $(pgrep -c -x rustdesk 2>/dev/null)"
    echo "cm-procs:       $(pgrep -c -f 'rustdesk --cm' 2>/dev/null)"
    echo "ipc-sockets:    $(ls /tmp/RustDesk-*/ipc* 2>/dev/null | tr '\n' ' ')"
    echo "log-audio:      $(grep -icE 'audio|pa monitor|pa ipc|simple pulse' "$L" 2>/dev/null)"
    tail -2 "$L" 2>/dev/null | cut -c1-140
  } >> "$OUT"
  sleep 3
done
echo "WATCH_DONE" >> "$OUT"
