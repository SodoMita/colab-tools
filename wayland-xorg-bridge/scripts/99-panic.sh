#!/bin/bash
# 99-panic.sh - get your machine back when a headless X server grabbed the screen.
#
#   scripts/99-panic.sh            # report what is running, kill nothing
#   scripts/99-panic.sh --kill     # kill our X servers / bridges, keep the session
#   sudo scripts/99-panic.sh --kill --chvt 2   # ...and switch to VT2
#
# Run this from ANOTHER machine over SSH if the screen is frozen - that is the
# whole point. Keep an SSH session open whenever you experiment with X servers
# on a GPU that drives your display.
#
# What a hijack looks like: the picture freezes on the last compositor frame,
# keyboard/VT switching appears dead, and the mouse may still move (the kernel
# handles input). The compositor is alive but lost DRM master and cannot
# page-flip. Killing the X server that stole master restores it.
set -uo pipefail
DO_KILL=0
CHVT=""
for a in "$@"; do
	case "$a" in
		--kill) DO_KILL=1 ;;
		--chvt) CHVT=next ;;
		[0-9]*) [ "$CHVT" = "next" ] && CHVT="$a" ;;
	esac
done

say() { printf '%s\n' "$*"; }
hdr() { printf '\n== %s\n' "$*"; }

hdr "X servers"
if command -v pgrep >/dev/null; then
	pgrep -a -x Xorg 2>/dev/null | sed 's/^/   /' || say "   none"
	pgrep -a -x Xvfb 2>/dev/null | sed 's/^/   /'
fi
say "   (flags: -sharevts = no VT switching; -novtswitch = never switch)"
say "   NOTE: only servers with a pid file in /tmp/xfd-*/ or /tmp/xvfb-*/ are killed."
for p in $(pgrep -x Xorg 2>/dev/null); do
	say "   pid $p: $(tr '\0' ' ' < /proc/"$p"/cmdline 2>/dev/null | cut -c1-120)"
done

hdr "our bridges / displays"
pgrep -a -x xfbridge 2>/dev/null | sed 's/^/   /' || say "   none"
for d in /tmp/xfd-* /tmp/xvfb-*; do [ -d "$d" ] && say "   $d"; done

hdr "who owns the DRM cards"
for c in /sys/class/drm/card[0-9]; do
	[ -e "$c/device/vendor" ] || continue
	v=$(cat "$c/device/vendor" 2>/dev/null)
	[ "$v" = "0x10de" ] && say "   $(basename "$c"): NVIDIA"
done
for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
	for fd in /proc/"$pid"/fd/*; do
		t=$(readlink "$fd" 2>/dev/null) || continue
		case "$t" in
			/dev/dri/card*|/dev/nvidia[0-9]*)
				say "   $t held by $pid ($(cat /proc/"$pid"/comm 2>/dev/null))"
				break ;;
		esac
	done
done

hdr "current VT / sessions"
[ -e /sys/class/tty/tty0/active ] && say "   active VT: $(cat /sys/class/tty/tty0/active)"
command -v loginctl >/dev/null && loginctl list-sessions --no-legend 2>/dev/null | sed 's/^/   /'

if [ "$DO_KILL" = "0" ]; then
	hdr "nothing was killed"
	say "   re-run with --kill to stop our X servers and bridges"
	say "   the safe headless server is: scripts/15-xvfb-soft.sh (no DRM, no VT)"
	exit 0
fi

hdr "killing our X servers and bridges"
# Only displays we created: /tmp/xfd-* and /tmp/xvfb-* pid files, plus any Xorg
# started on those displays. Deliberately narrow - never touch :0 of a seat.
for f in /tmp/xfd-*/xorg.pid /tmp/xvfb-*/xvfb.pid; do
	[ -f "$f" ] || continue
	p=$(cat "$f" 2>/dev/null)
	if [ -n "$p" ] && [ -e "/proc/$p" ]; then
		say "   kill $p ($f)"
		kill "$p" 2>/dev/null || sudo -n kill "$p" 2>/dev/null
		sleep 0.5
		[ -e "/proc/$p" ] && { kill -9 "$p" 2>/dev/null || sudo -n kill -9 "$p" 2>/dev/null; }
	fi
	rm -f "$f"
done
# -x (exact process name) only: pgrep -f would also match shells whose command
# line merely mentions the bridge, and killing those is unacceptable.
for p in $(pgrep -x xfbridge 2>/dev/null); do
	[ "$p" = "$$" ] && continue
	[ "$p" = "$PPID" ] && continue
	say "   kill bridge $p"
	kill "$p" 2>/dev/null
done

if [ -n "$CHVT" ] && [ "$CHVT" != "next" ]; then
	hdr "switching to VT$CHVT"
	if command -v chvt >/dev/null; then
		sudo -n chvt "$CHVT" 2>/dev/null && say "   ok" || say "   chvt failed (try as root)"
	else
		sudo -n sh -c "echo $CHVT > /dev/tty0" 2>/dev/null || say "   install chvt (kbd package)"
	fi
fi

hdr "aftermath"
say "   If the picture is still frozen, your compositor lost DRM master and needs a"
say "   restart of its session (not the whole machine):"
say "     - switch VT with Ctrl+Alt+F3, log in, then restart the display manager, e.g."
say "         sudo systemctl restart sddm     # or gdm / greetd / ly"
say "     - or from SSH:  loginctl terminate-session \$XDG_SESSION_ID"
say "   Last resort, without a hard reset:  SysRq: Alt+SysRq+R, then K, then B"
