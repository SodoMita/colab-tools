#!/bin/bash
# 30-xapp.sh - run a single X11 app at full GPU speed inside your Wayland session.
#
#   scripts/30-xapp.sh blender -b ~/scene.blend        # or any X11 program
#   FULLSCREEN=1 scripts/30-xapp.sh xterm -fa Monospace
#   SAFE=1 scripts/30-xapp.sh glxgears                 # Xvfb: cannot hijack anything
#
# SAFE=1 is the recommended mode on a machine whose NVIDIA card drives your
# monitor: it uses Xvfb (no DRM, no VT, no root). Programs are started through
# vglrun when VirtualGL is installed, so OpenGL still runs on the GPU.
#
# It takes care of: starting the headless Xorg if needed, starting xfbridge so
# the X screen appears as a native Wayland window, injecting input, and stopping
# the bridge when the app exits.
#
# Environment:
#   XFDISPLAY=:1        X display to create/use        (default :1)
#   BRIDGE_FPS=60       bridge frame timer
#   FULLSCREEN=1        open the mirror fullscreen
#   KEEP_BRIDGE=1       leave the bridge running after the app exits
#   NO_INPUT=1          do not forward keyboard/pointer
#   BRIDGE_TITLE=...    window title
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE="$here/xfbridge"
[ -x "$BRIDGE" ] || { echo "xfbridge not built: run scripts/00-build.sh" >&2; exit 1; }
[ $# -ge 1 ] || { echo "usage: $0 <X11 command> [args...]" >&2; exit 1; }

XDISPLAY="${XFDISPLAY:-:1}"
RUNDIR="${XFDIR:-/tmp/xfd-$XDISPLAY}"
XAUTH="$RUNDIR/Xauthority"

if [ -z "${WAYLAND_DISPLAY:-}" ]; then
	echo "!! WAYLAND_DISPLAY is not set - start this from a terminal inside your" >&2
	echo "   Wayland session (or export WAYLAND_DISPLAY=wayland-0)." >&2
	exit 1
fi

# ---- X server ----
export XFDISPLAY="$XDISPLAY"
if [ "${SAFE:-0}" = "1" ]; then
	XDISPLAY="${XFDISPLAY_SAFE:-:2}"
	export XFDISPLAY="$XDISPLAY"
	XAUTH="${XFDIR:-/tmp/xvfb-$XDISPLAY}/Xauthority"
	if ! XAUTHORITY="$XAUTH" xdpyinfo -display "$XDISPLAY" >/dev/null 2>&1; then
		echo "== starting Xvfb on $XDISPLAY (safe mode)"
		bash "$here/scripts/15-xvfb-soft.sh" start || exit 1
	fi
else
	if ! XAUTHORITY="$XAUTH" xdpyinfo -display "$XDISPLAY" >/dev/null 2>&1; then
		echo "== starting headless Xorg on $XDISPLAY"
		bash "$here/scripts/20-xorg-headless.sh" start || exit 1
	fi
fi
export DISPLAY="$XDISPLAY" XAUTHORITY="$XAUTH"

# ---- bridge ----
title="${BRIDGE_TITLE:-$(basename "$1") (X $XDISPLAY)}"
args=(--x-display "$XDISPLAY" --title "$title" --fps "${BRIDGE_FPS:-60}")
[ "${FULLSCREEN:-0}" = "1" ] && args+=(--fullscreen)
[ "${NO_INPUT:-0}" = "1" ] && args+=(--no-input)

nohup "$BRIDGE" "${args[@]}" >/tmp/xfbridge-$$.log 2>&1 &
BRIDGE_PID=$!
sleep 0.4
if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
	echo "!! bridge failed to start:" >&2
	sed 's/^/   /' /tmp/xfbridge-$$.log >&2
	exit 1
fi
echo "== bridge pid $BRIDGE_PID  (log /tmp/xfbridge-$$.log)"

cleanup() {
	if [ "${KEEP_BRIDGE:-0}" = "1" ]; then
		echo "== app exited; bridge left running (kill $BRIDGE_PID to stop)"
	else
		kill "$BRIDGE_PID" 2>/dev/null
	fi
}
trap cleanup EXIT INT TERM

# In SAFE mode route OpenGL through VirtualGL's EGL device backend: the GPU
# renders, Xvfb only receives finished pixels. No X server touches the GPU.
VG=""
if [ "${SAFE:-0}" = "1" ] && [ "${NO_VGL:-0}" != "1" ]; then
	VG=$(command -v vglrun || { [ -x /opt/VirtualGL/bin/vglrun ] && echo /opt/VirtualGL/bin/vglrun; } || true)
fi
if [ -n "$VG" ]; then
	echo "== running via vglrun (VGL_DISPLAY=${VGL_DISPLAY:-egl0}): $*"
	VGL_DISPLAY="${VGL_DISPLAY:-egl0}" "$VG" "$@"
else
	echo "== running: $*  (X $XDISPLAY)"
	"$@"
fi
rc=$?
echo "== app exited with $rc"
exit $rc
