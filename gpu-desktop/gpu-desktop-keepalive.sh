#!/bin/bash
# gpu-desktop-keepalive.sh (v4 — run as root)
#
# Every 30 s supervises:
#   1. Xorg :20 (NVIDIA GPU) + persistent XFCE session (as colab)
#   2. /dev/uinput character device (666 so non-root RustDesk injects input)
#   3. System-wide PulseAudio + DummyOutput null sink (via audio-setup.sh)
#   4. RustDesk peer running as `colab` (via peer-as-colab.sh — non-root so
#      RustDesk spawns `rustdesk --cm` via run_me() without needing systemd-logind,
#      keeping the `_pa` audio capture channel alive)
#
# Log: /tmp/gpu-desk/keepalive.log
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUDIO_SETUP="${AUDIO_SETUP:-/home/colab/audio-setup.sh}"
PEER_START="${PEER_START:-/home/colab/peer-as-colab.sh}"
GPU_DESKTOP="${GPU_DESKTOP:-/home/colab/gpu-desktop.sh}"
[ -f "$AUDIO_SETUP" ] || AUDIO_SETUP="$SCRIPT_DIR/../rustdesk-audio/audio-setup.sh"
[ -f "$PEER_START" ]  || PEER_START="$SCRIPT_DIR/../rustdesk-audio/peer-as-colab.sh"
[ -f "$GPU_DESKTOP" ] || GPU_DESKTOP="$SCRIPT_DIR/gpu-desktop.sh"

LOG=/tmp/gpu-desk/keepalive.log
mkdir -p /tmp/gpu-desk
log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

log "keepalive v4 started (pid $$)"
while true; do
    if ! su - colab -c "bash '$GPU_DESKTOP' start" >/dev/null 2>&1; then
        log "WARN gpu-desktop.sh start returned non-zero"
    fi

    if [ ! -e /dev/uinput ]; then
        mknod /dev/uinput c 10 223 2>/dev/null && log "uinput node recreated"
    fi
    chmod 666 /dev/uinput 2>/dev/null

    if ! pactl info >/dev/null 2>&1; then
        log "pulseaudio down - running audio-setup.sh"
        bash "$AUDIO_SETUP" >>/tmp/gpu-desk/keepalive-audio.log 2>&1
    fi

    if [ -x /usr/bin/rustdesk ] && ! pgrep -u colab -x rustdesk >/dev/null 2>&1; then
        log "rustdesk peer (colab) down - restarting via peer-as-colab.sh"
        bash "$PEER_START" >>/tmp/gpu-desk/keepalive-rd.log 2>&1
    fi

    sleep 30
done
