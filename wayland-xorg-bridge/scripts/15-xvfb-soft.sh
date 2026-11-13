#!/bin/bash
# 15-xvfb-soft.sh - the SAFE headless X server: Xvfb + optional VirtualGL.
#
#   scripts/15-xvfb-soft.sh start|stop|restart|status
#
# Why this exists
# ---------------
# A real Xorg on the NVIDIA card takes DRM master away from whatever owns that
# card (your Wayland compositor) and the session is hijacked: frozen screen, VT
# switching dead, hard reset required. 20-xorg-headless.sh now refuses to do that
# when a monitor is connected to the NVIDIA card - this is the alternative.
#
# Xvfb never touches DRM, never opens a VT, never needs root, and can run
# alongside your compositor forever:
#
#     X app ──► Xvfb (software framebuffer)        zero risk
#                 └─ with vglrun: GL calls go to the GPU through the EGL
#                    device backend (no X server on the GPU involved)
#                        │
#                        └──► xfbridge ──► a Wayland surface
#
# Trade-off: Xvfb's own GLX is llvmpipe, so only programs started through
# `vglrun -d egl0` (GLX/OpenGL) get the GPU. Vulkan is not intercepted by
# VirtualGL; Vulkan apps need their own offscreen/headless mode.
#
# Environment:
#   XFDISPLAY=:2        display to create (default :2, distinct from the real server)
#   GEOMETRY=1920x1080
#   DEPTH=24
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

XDISPLAY="${XFDISPLAY:-:2}"
GEOMETRY="${GEOMETRY:-1920x1080}"
DEPTH="${DEPTH:-24}"
RUNDIR="${XFDIR:-/tmp/xvfb-$XDISPLAY}"
XAUTH="$RUNDIR/Xauthority"
LOG="$RUNDIR/Xvfb.log"
PIDF="$RUNDIR/xvfb.pid"
W="${GEOMETRY%x*}"
H="${GEOMETRY#*x}"

export DISPLAY="$XDISPLAY"
msg() { echo "[xvfb-soft] $*"; }

alive() {
	local pid="$1"
	[ -n "$pid" ] && [ -e "/proc/$pid" ] || return 1
	[ "$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)" = "Z" ] && return 1
	return 0
}

vgl_state() {
	if [ -x /opt/VirtualGL/bin/vglrun ]; then
		local d
		d=$(/opt/VirtualGL/bin/eglinfo -e 2>/dev/null | grep -c "EGL device" || true)
		echo "installed${d:+ ($d EGL device(s) visible)}"
	elif command -v vglrun >/dev/null; then
		echo "installed"
	else
		echo "absent"
	fi
}

start() {
	command -v Xvfb >/dev/null || {
		msg "Xvfb not installed:"
		case "$(nv_distro 2>/dev/null)" in
			arch) msg "  sudo pacman -S xorg-server-xvfb" ;;
			*)    msg "  sudo apt install xvfb   (or: xorg-x11-server-Xvfb)" ;;
		esac
		return 1
	}
	if [ -f "$PIDF" ] && alive "$(cat "$PIDF" 2>/dev/null)"; then
		msg "already running (pid $(cat "$PIDF"))"
		check
		return $?
	fi

	mkdir -p "$RUNDIR"; chmod 700 "$RUNDIR"
	touch "$XAUTH"; chmod 600 "$XAUTH"
	xauth -f "$XAUTH" list 2>/dev/null | grep -q "^unix${XDISPLAY}" || \
		xauth -f "$XAUTH" add "$XDISPLAY" . "$(mcookie)"

	msg "starting Xvfb $XDISPLAY at ${W}x${H}x${DEPTH} (no DRM, no VT, no root)"
	nohup Xvfb "$XDISPLAY" -screen 0 "${W}x${H}x${DEPTH}" \
		+extension GLX +extension RANDR +extension Composite \
		+extension DAMAGE +extension XFIXES +render \
		-nolisten tcp -noreset -auth "$XAUTH" \
		> "$LOG" 2>&1 &
	echo $! > "$PIDF"

	for _ in $(seq 1 25); do
		XAUTHORITY="$XAUTH" xdpyinfo -display "$XDISPLAY" >/dev/null 2>&1 && break
		alive "$(cat "$PIDF")" || break
		sleep 0.4
	done
	if ! XAUTHORITY="$XAUTH" xdpyinfo -display "$XDISPLAY" >/dev/null 2>&1; then
		msg "ERROR: Xvfb did not come up"
		sed 's/^/    /' "$LOG" | tail -15
		return 1
	fi
	check
}

check() {
	msg "screen : $(XAUTHORITY="$XAUTH" xdpyinfo -display "$XDISPLAY" | awk '/dimensions:/{print $2}')"
	msg "virtualgl: $(vgl_state)"
	if command -v glxinfo >/dev/null; then
		msg "glxinfo (untouched) : $(XAUTHORITY="$XAUTH" glxinfo -B 2>/dev/null | awk -F': ' '/OpenGL renderer/{print $2}')   <- llvmpipe is expected here"
	fi
	if command -v vglrun >/dev/null || [ -x /opt/VirtualGL/bin/vglrun ]; then
		local vg; vg=$(command -v vglrun || echo /opt/VirtualGL/bin/vglrun)
		msg "glxinfo (vglrun)    : $(XAUTHORITY="$XAUTH" VGL_DISPLAY="${VGL_DISPLAY:-egl0}" "$vg" glxinfo -B 2>/dev/null | awk -F': ' '/OpenGL renderer/{print $2}')   <- should name the NVIDIA card"
	fi
	msg "use:  export DISPLAY=$XDISPLAY XAUTHORITY=$XAUTH"
	[ -n "${WAYLAND_DISPLAY:-}" ] && msg "mirror: ${here}/xfbridge --x-display $XDISPLAY --title 'X apps'"
	return 0
}

stop() {
	local p=""
	[ -f "$PIDF" ] && p=$(cat "$PIDF" 2>/dev/null)
	alive "$p" || p=""
	if [ -z "$p" ]; then
		msg "not running"; rm -f "$PIDF"; return 0
	fi
	msg "stopping Xvfb $XDISPLAY (pid $p)"
	kill "$p" 2>/dev/null
	for _ in $(seq 1 20); do alive "$p" || break; sleep 0.2; done
	alive "$p" && kill -9 "$p" 2>/dev/null
	rm -f "$PIDF"
	msg "stopped"
}

status() {
	echo "---- Xvfb (software, safe) ----"
	echo "display : $XDISPLAY"
	echo "pid     : $(cat "$PIDF" 2>/dev/null || echo -)"
	if XAUTHORITY="$XAUTH" xdpyinfo -display "$XDISPLAY" >/dev/null 2>&1; then
		echo "state   : UP"
		check
	else
		echo "state   : DOWN"
	fi
}

case "${1:-status}" in
	start)   start ;;
	stop)    stop ;;
	restart) stop; start ;;
	status)  status ;;
	*) echo "usage: $0 {start|stop|restart|status}"; exit 1 ;;
esac
