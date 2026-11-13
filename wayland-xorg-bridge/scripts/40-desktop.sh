#!/bin/bash
# 40-desktop.sh - a whole X11 desktop (XFCE by default) inside one Wayland window.
#
#   scripts/40-desktop.sh start|stop|status
#
# Handy when you want a fast X session (all GL apps accelerated on the NVIDIA
# GPU) while your compositor stays whatever it is - even a software-rendered
# wlroots session, which only has to blit one opaque surface.
#
# Environment:
#   XFDISPLAY=:1              X display for the desktop
#   GEOMETRY=1920x1080        X screen size == window content size
#   DESKTOP=startxfce4        session command (startxfce4, mate-session, ...)
#   FULLSCREEN=1
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XDISPLAY="${XFDISPLAY:-:1}"
DISPLAYNAME="$XDISPLAY"
RUNDIR="${XFDIR:-/tmp/xfd-$XDISPLAY}"
XAUTH="$RUNDIR/Xauthority"
BRIDGE="$here/xfbridge"
PIDFILE="$RUNDIR/bridge.pid"
DESKTOP="${DESKTOP:-startxfce4}"
TOPLEVEL_CMD="${TOPLEVEL_CMD:-startxfce4}"

msg() { echo "[desktop] $*"; }
export XFDISPLAY="$XDISPLAY"

start() {
	[ -x "$BRIDGE" ] || { msg "build first: scripts/00-build.sh"; return 1; }
	[ -n "${WAYLAND_DISPLAY:-}" ] || { msg "WAYLAND_DISPLAY unset - run inside the Wayland session"; return 1; }

	bash "$here/scripts/20-xorg-headless.sh" start || return 1
	export DISPLAY="$DISPLAYNAME" XAUTHORITY="$XAUTH"

	# session
	if ! XAUTHORITY="$XAUTH" pgrep -f -u "$(id -u)" "xfce4-session" >/dev/null 2>&1; then
		msg "starting $DESKTOP on $DISPLAYNAME"
		mkdir -p "$RUNDIR"
		(
			export DISPLAY="$DISPLAYNAME" XAUTHORITY="$XAUTH"
			export XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP=XFCE
			export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-$USER}"
			mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
			if command -v dbus-launch >/dev/null; then
				setsid nohup dbus-launch --exit-with-session $DESKTOP \
					</dev/null >"$RUNDIR/session.log" 2>&1 &
			else
				setsid nohup $DESKTOP </dev/null >"$RUNDIR/session.log" 2>&1 &
			fi
		)
		sleep 4
	fi

	# bridge
	if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
		msg "bridge already running (pid $(cat "$PIDFILE"))"
	else
		local args=(--x-display "$DISPLAYNAME" --title "X $DISPLAYNAME desktop"
			    --fps "${BRIDGE_FPS:-60}")
		[ "${FULLSCREEN:-0}" = "1" ] && args+=(--fullscreen)
		[ "${NO_INPUT:-0}" = "1" ] && args+=(--no-input)
		nohup "$BRIDGE" "${args[@]}" >"$RUNDIR/bridge.log" 2>&1 &
		echo $! > "$PIDFILE"
		sleep 1
		kill -0 "$(cat "$PIDFILE")" 2>/dev/null || { msg "bridge died:"; sed 's/^/   /' "$RUNDIR/bridge.log"; return 1; }
		msg "bridge pid $(cat "$PIDFILE")"
	fi
	status
}

stop() {
	if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
		kill "$(cat "$PIDFILE")" 2>/dev/null; msg "bridge stopped"
	fi
	rm -f "$PIDFILE"
	pkill -u "$(id -u)" -f "xfce4-session" 2>/dev/null
	bash "$here/scripts/20-xorg-headless.sh" stop
}

status() {
	bash "$here/scripts/20-xorg-headless.sh" status
	echo "bridge    : $( [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null && echo "running (pid $(cat "$PIDFILE"))" || echo "not running")"
}

case "${1:-start}" in
	start)  start ;;
	stop)   stop ;;
	status) status ;;
	*) echo "usage: $0 {start|stop|status}"; exit 1 ;;
esac
