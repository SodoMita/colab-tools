#!/bin/bash
# start-rustdesk-root.sh — RustDesk peer as root on the :20 GPU desktop (unattended).
#
# Two hard-won requirements baked in:
#  1. root needs the :20 MIT-MAGIC-COOKIE, otherwise the peer dies instantly with
#     "Authorization required, but no authorization protocol specified".
#  2. `rustdesk --password` only works while a `rustdesk --server` process owns the
#     IPC socket (/tmp/RustDesk-0/ipc). The GUI alone does NOT serve, and the command
#     fails with "No --server process found for user main IPC". So: server first,
#     then GUI, then --password.
set -u

DISPLAY_NUM="${DISPLAY_NUM:-20}"
PASS="${RD_PASSWORD:?Set RD_PASSWORD in the environment}"
# NOTE: Prefer peer-as-colab.sh! Running the peer as root in a container without
# systemd-logind prevents RustDesk from spawning --cm on connect (audio broken).
LOG=/tmp/gpu-desk

export DISPLAY=":$DISPLAY_NUM"
export XAUTHORITY=/root/.Xauthority
mkdir -p /tmp/runtime-root "$LOG" && chmod 700 /tmp/runtime-root
export XDG_RUNTIME_DIR=/tmp/runtime-root
export XDG_CURRENT_DESKTOP=XFCE
export XDG_SESSION_TYPE=x11

# --- 1. root X authority ---------------------------------------------------
if ! xdpyinfo -display ":$DISPLAY_NUM" header >/dev/null 2>&1 || ! xdpyinfo >/dev/null 2>&1; then
  COOKIE=$(su - colab -c "xauth -f /home/colab/.Xauthority list :$DISPLAY_NUM" 2>/dev/null | awk '{print $3}')
  if [ -n "$COOKIE" ]; then
    xauth -f /root/.Xauthority add ":$DISPLAY_NUM" . "$COOKIE" 2>/dev/null
    echo "cookie installed for :$DISPLAY_NUM"
  else
    echo "WARN: no cookie found for :$DISPLAY_NUM (is Xorg up?)"
  fi
fi
if ! xdpyinfo >/dev/null 2>&1; then
  echo "FATAL: cannot open display :$DISPLAY_NUM as root; not starting peer"
  exit 1
fi


# --- 2.5 audio: system PulseAudio must be up before the peer inits audio ---
if ! pactl info >/dev/null 2>&1; then
  echo "audio: starting pulseaudio"
  bash /home/colab/audio-setup.sh >/tmp/gpu-desk/audio.log 2>&1 || echo "WARN: audio setup failed"
fi
echo "audio sink: $(pactl get-default-sink 2>/dev/null) source: $(pactl get-default-source 2>/dev/null)"

# --- 2. clean slate --------------------------------------------------------
pkill -x rustdesk 2>/dev/null
sleep 2

# --- 3. server (owns IPC) then GUI ----------------------------------------
cd /root || exit 1
setsid nohup /usr/bin/rustdesk --server </dev/null >>"$LOG/rd-server.log" 2>&1 &
sleep 6
setsid nohup /usr/bin/rustdesk </dev/null >>"$LOG/rd-gui.log" 2>&1 &
sleep 8

# --- 3.5 connection manager (CM) ---
# On Linux the CM serves the `_pa` IPC channel used for PulseAudio capture.
# RustDesk normally spawns it via run_as_user(), which needs an "active user"
# from logind -- impossible here (systemd is not PID 1), so audio never starts.
if ! pgrep -f 'rustdesk --cm' >/dev/null; then
  setsid nohup /usr/bin/rustdesk --cm </dev/null >>"$LOG/rd-cm.log" 2>&1 &
  sleep 6
  echo "cm: $(pgrep -f 'rustdesk --cm' | head -1)"
else
  echo "cm: already running"
fi
echo "ipc_pa socket: $([ -S /tmp/RustDesk-0/ipc_pa ] && echo present || echo MISSING)"

# --- 4. permanent password (needs the server above) -----------------------
if pgrep -f 'rustdesk --server' >/dev/null; then
  out=$(rustdesk --password "$PASS" 2>&1 | tail -1)
  echo "password: $out"
else
  echo "WARN: no --server process; password not set"
fi

echo "ID: $(rustdesk --get-id 2>&1 | tail -1)"
echo "toml password set: $(grep -c "^password = '" /root/.config/rustdesk/RustDesk.toml)"
echo "verification: $(grep -E '^verification-method' /root/.config/rustdesk/RustDesk2.toml)"
