#!/bin/bash
# peer-as-colab.sh — run the RustDesk peer as the desktop user (`colab`) instead of root.
#
# Why: on Linux, RustDesk never opens PulseAudio in `--server`; it spawns
# `rustdesk --cm` when a connection starts, and the CM serves the `_pa` IPC
# socket that captures PulseAudio (`DummyOutput.monitor`). When the peer runs
# as ROOT, `start_ipc` calls `run_as_user(["--cm"])`, which queries `loginctl`
# for the active seat0 user. In containers where systemd is not PID 1,
# `loginctl` fails ("System has not been booted with systemd..."), returning
# `bail("No valid uid")` — so `--cm` is never spawned and audio silently dies.
#
# When the peer runs as a non-root user (`colab`), RustDesk skips `run_as_user`
# and calls `run_me(["--cm"])` directly, so `--cm` and `ipc_pa` come up cleanly.
#
# Optional env:
#   RD_PASSWORD      if set, configures/updates the permanent password via `--password`
#   DISPLAY_NUM      default: 20
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DISPLAY_NUM="${DISPLAY_NUM:-20}"
ENVV="DISPLAY=:${DISPLAY_NUM} XAUTHORITY=/home/colab/.Xauthority XDG_RUNTIME_DIR=/tmp/runtime-colab XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_TYPE=x11"

echo "== audio daemon"
if ! pactl info >/dev/null 2>&1; then
  AUDIO_SH="/home/colab/audio-setup.sh"
  [ -f "$AUDIO_SH" ] || AUDIO_SH="$SCRIPT_DIR/audio-setup.sh"
  bash "$AUDIO_SH" >/tmp/audio-setup.log 2>&1 && echo "pulseaudio started"
fi
echo "sink: $(pactl get-default-sink 2>/dev/null) source: $(pactl get-default-source 2>/dev/null)"

echo "== stop every rustdesk instance"
pkill -x rustdesk 2>/dev/null
pkill -f 'rustdesk --help' 2>/dev/null
sleep 2

echo "== prepare colab RustDesk config (never clobber without backup)"
DEST=/home/colab/.config/rustdesk
TS=$(date +%Y%m%d-%H%M%S)
mkdir -p "$DEST" /tmp/runtime-colab
chown colab:colab /tmp/runtime-colab && chmod 700 /tmp/runtime-colab

for f in RustDesk.toml RustDesk2.toml; do
  SRC="/root/.config/rustdesk/$f"
  [ -f "$SRC" ] || continue
  if [ -f "$DEST/$f" ] && ! cmp -s "$SRC" "$DEST/$f"; then
    cp -a "$DEST/$f" "$DEST/$f.bak-$TS"
    echo "backed up existing $f -> $f.bak-$TS"
  fi
  if [ ! -f "$DEST/$f" ] || ! cmp -s "$SRC" "$DEST/$f"; then
    cp -a "$SRC" "$DEST/$f"
    echo "installed root's $f"
  else
    echo "$f already identical"
  fi
done
chown -R colab:colab "$DEST"
chmod 600 "$DEST"/RustDesk*.toml 2>/dev/null || true

echo "== uinput access for input injection"
[ -e /dev/uinput ] || mknod /dev/uinput c 10 223 2>/dev/null || true
[ -e /dev/uinput ] && { chmod 666 /dev/uinput; echo "uinput: $(ls -l /dev/uinput | cut -d' ' -f1)"; }

echo "== start peer as colab (--server first so main IPC socket exists, then GUI)"
su colab -c "$ENVV setsid nohup /usr/bin/rustdesk --server </dev/null >>/tmp/rd-server.log 2>&1 &"
sleep 7
su colab -c "$ENVV setsid nohup /usr/bin/rustdesk </dev/null >>/tmp/rd-gui.log 2>&1 &"
sleep 10

# Ensure audio permission + permanent password option are enabled in RustDesk2.toml
if [ -f "$DEST/RustDesk2.toml" ]; then
  python3 - "$DEST/RustDesk2.toml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
changed = False
for k, v in [("enable-audio", "Y"), ("verification-method", "use-both-passwords")]:
    line = f"{k} = '{v}'"
    if f"{k} =" not in s:
        if "[options]" in s:
            s = s.replace("[options]\n", f"[options]\n{line}\n", 1)
        else:
            s += f"\n[options]\n{line}\n"
        changed = True
if changed:
    open(p, "w").write(s)
    print("updated options in RustDesk2.toml")
PY
  chown colab:colab "$DEST/RustDesk2.toml"
fi

if [ -n "${RD_PASSWORD:-}" ]; then
  su colab -c "$ENVV rustdesk --password '$RD_PASSWORD'" 2>&1 | tail -1
fi

COLAB_UID=$(id -u colab)
echo "== verify"
echo "procs: $(pgrep -c -x rustdesk)"
echo "id: $(su colab -c "$ENVV rustdesk --get-id" 2>&1 | tail -1)"
grep -hE '^(enable-audio|verification-method)' "$DEST"/RustDesk*.toml 2>/dev/null || true
echo "password configured: $(grep -c "^password = '." "$DEST/RustDesk.toml" 2>/dev/null || echo 0)"
echo "ipc (/tmp/RustDesk-${COLAB_UID}): $(ls "/tmp/RustDesk-${COLAB_UID}/" 2>/dev/null | tr '\n' ' ')"
