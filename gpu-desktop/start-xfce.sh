#!/bin/bash
# start-xfce.sh — start the XFCE session on :20 with a PERSISTENT session dbus
# (no --exit-with-session: survives the SSH/pty that launched it). Run as colab.
export DISPLAY="${DISPLAY:-:20}"
export XAUTHORITY="${XAUTHORITY:-/home/colab/.Xauthority}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-colab}"
export XDG_CURRENT_DESKTOP=XFCE
export XDG_SESSION_TYPE=x11
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"

if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
    eval "$(dbus-launch --sh-syntax)"
    echo "session bus: $DBUS_SESSION_BUS_ADDRESS"
fi
echo "starting startxfce4 at $(date -u)"
exec startxfce4
