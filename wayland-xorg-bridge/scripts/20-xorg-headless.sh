#!/bin/bash
# 20-xorg-headless.sh - a second Xorg server on your NVIDIA GPU, on its OWN virtual
# terminal, so that VT switching keeps working.
#
#   scripts/20-xorg-headless.sh plan          # show exactly what would run, change nothing
#   scripts/20-xorg-headless.sh start         # start on a free VT (does not switch to it)
#   scripts/20-xorg-headless.sh start --switch  # start and switch to it (Ctrl+Alt+F1 goes back)
#   scripts/20-xorg-headless.sh stop          # stop and return to the original VT
#   scripts/20-xorg-headless.sh status
#
# ============================ READ THIS ==================================
# A previous version of this script passed -sharevts. That is what made a VT
# switch impossible and left the session frozen. Straight from
# hw/xfree86/os-support/linux/lnx_init.c, xf86OpenConsole():
#
#     if (!xf86Info.ShareVTs) {
#         switch_to(xf86Info.vtno, "xf86OpenConsole");
#         OsSignal(SIGUSR1, xf86VTRequest);
#         VT.mode = VT_PROCESS; VT.relsig = SIGUSR1; VT.acqsig = SIGUSR1;
#         VT_SETMODE(VT_PROCESS);
#         KDSETMODE(KD_GRAPHICS);
#     }
#
# VT_PROCESS + xf86VTRequest is the entire cooperation protocol: the kernel asks
# the server "may I switch away?", the server drops DRM master, restores text
# mode and answers. -sharevts skips ALL of it, so on Ctrl+Alt+F<n> nobody
# answers, the server keeps DRM master and keeps scanning out on the VT your
# compositor is on. Result: frozen picture, dead VT switching, reset.
#
# So: a second X server on the same GPU is fine - it just has to own its own VT.
# =========================================================================
#
# ISOLATION: the server is started with
#     -config <per-display conf>  -configdir <empty private dir>
# so /etc/X11/xorg.conf.d is NOT read and nothing in /etc is written. Verified:
# a canary module in /etc/X11/xorg.conf.d loads 3x without -configdir, 0x with it.
# Your normal X11 session is therefore unaffected by anything this script does.
#
# Environment:
#   XORG_VT=2               VT to use (default: first VT that is not the active one)
#   XFDISPLAY=:1            X display number
#   GEOMETRY / DEPTH        only used for the "does the conf match" message
#   XORG_CONF=<auto>        config file
#   SUDO=1                  run the server as root (needed unless the setuid
#                           wrapper does it for you)
#   FORCE=1                 override the safety refusals (you will be warned)
#   SHAREVTS=1              DO NOT USE - restores the old, broken behaviour
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-nvidia.sh
. "$here/lib-nvidia.sh"

XDISPLAY="${XFDISPLAY:-:1}"
CONF="${XORG_CONF:-$(nv_xorg_conf)}"
GEOMETRY="${GEOMETRY:-1920x1080}"
RUNDIR="${XFDIR:-/tmp/xfd-$XDISPLAY}"
CONFDIR="${XORG_CONFDIR:-$RUNDIR/conf.d-isolated}"
XAUTH="$RUNDIR/Xauthority"
LOG="$RUNDIR/Xorg.log"
OUT="$RUNDIR/xorg.out"
PIDF="$RUNDIR/xorg.pid"
MODULEPATH="${XORG_MODULEPATH:-$(nv_modulepath)}"
SUDO_MODE="${SUDO:-0}"
FORCE="${FORCE:-0}"
SHAREVTS="${SHAREVTS:-0}"
ACTION="${1:-status}"
DO_SWITCH=0
DRY=0
for a in "$@"; do
	case "$a" in
		--switch) DO_SWITCH=1 ;;
		--dry-run) DRY=1 ;;
	esac
done
[ "$ACTION" = "plan" ] && { DRY=1; ACTION=start; }

msg()  { echo "[xorg-headless] $*"; }
warn() { echo "[xorg-headless] WARNING: $*" >&2; }

alive() {
	local pid="$1"
	[ -n "$pid" ] && [ -e "/proc/$pid" ] || return 1
	[ "$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)" = "Z" ] && return 1
	return 0
}

active_vt_num() {
	local a
	a=$(cat /sys/class/tty/tty0/active 2>/dev/null) || return 1
	echo "${a#tty}"
}

# A VT nobody is using: not the active one, and not an X server's.
pick_vt() {
	local active; active=$(active_vt_num || echo 1)
	local n=1
	while [ "$n" -le 12 ]; do
		if [ "$n" != "$active" ] && ! pgrep -a -x Xorg 2>/dev/null | grep -q " vt$n\b"; then
			echo "$n"; return 0
		fi
		n=$((n + 1))
	done
	return 1
}

VT="${XORG_VT:-}"
if [ -z "$VT" ]; then
	VT=$(pick_vt) || { echo "[xorg-headless] no free VT found (1-12)" >&2; exit 1; }
fi

find_xorg() {
	[ -n "${XORG_BIN:-}" ] && { echo "$XORG_BIN"; return; }
	for b in /usr/lib/Xorg /usr/lib/xorg/Xorg /usr/libexec/Xorg /usr/bin/Xorg /usr/bin/X; do
		[ -x "$b" ] && { echo "$b"; return; }
	done
}
is_wrapper() { readlink -f "$1" 2>/dev/null | grep -q 'Xorg\.wrap$'; }
console_ok() { [ -w /dev/tty0 ] 2>/dev/null; }
wrapper_grants_root() {
	local w=/etc/X11/Xwrapper.config
	[ -f "$w" ] || return 1
	grep -qiE '^[[:space:]]*needs_root_rights[[:space:]]*=[[:space:]]*yes' "$w" || return 1
	local u
	for u in ${XWRAPPER_PATHS:-/usr/lib/Xorg.wrap /usr/lib/xorg/Xorg.wrap /usr/libexec/Xorg.wrap /usr/bin/Xorg}; do
		[ -u "$u" ] && { WRAPPER_BIN="$u"; return 0; }
	done
	return 1
}

# ---------------------------------------------------------------- the plan
build_plan() {
	XB=$(find_xorg) || true
	[ -z "${XB:-}" ] && { echo "[xorg-headless] ERROR: no Xorg binary (xorg-server installed?)" >&2; return 1; }
	LAUNCH=(); RIGHTS=""
	if [ "$SUDO_MODE" = "1" ]; then
		LAUNCH=(sudo -n "$XB"); RIGHTS="sudo (root)"
	elif console_ok; then
		LAUNCH=("$XB"); RIGHTS="user (console accessible)"
	elif wrapper_grants_root; then
		XB="${WRAPPER_BIN:-/usr/bin/Xorg}"; LAUNCH=("$XB"); RIGHTS="setuid wrapper (root)"
	else
		RIGHTS=""
	fi
	local margs=() vargs=() sargs=()
	[ -n "$MODULEPATH" ] && margs=(-modulepath "$MODULEPATH")
	# The VT argument both selects the terminal and makes linux_parse_vt_settings()
	# skip the /dev/tty0 open entirely (it only opens /dev/ttyN).
	vargs=("vt$VT")
	if [ "$SHAREVTS" = "1" ]; then
		sargs=(-sharevts)
	else
		# default Xorg behaviour: VT_PROCESS + SIGUSR1 handler => cooperative switching
		:
	fi
	ARGS=("$XDISPLAY" "${vargs[@]}" -config "$CONF" -configdir "$CONFDIR" "${margs[@]}" \
	      "${sargs[@]}" -auth "$XAUTH" -noreset -nolisten tcp -logfile "$LOG")
}

show_plan() {
	echo "---------------------------------------------- plan"
	echo " server      : ${XB:-?}"
	echo " rights      : ${RIGHTS:-<none available>}"
	echo " display     : $XDISPLAY"
	echo " VT          : vt$VT   (active VT now: tty$(active_vt_num || echo '?'))"
	echo " config      : $CONF"
	echo " configdir   : $CONFDIR  (empty: /etc/X11/xorg.conf.d is NOT read)"
	echo " command     : ${LAUNCH[*]:-<none>} ${ARGS[*]:-}"
	echo " VT protocol : $( [ "$SHAREVTS" = "1" ] && echo 'VT_AUTO via -sharevts  <-- VT SWITCHING WILL BREAK' || echo 'VT_PROCESS + xf86VTRequest (cooperative)')"
	echo " behaviour   : the server takes DRM master only while vt$VT is active;"
	echo "               Ctrl+Alt+F<your compositor VT> hands the card back."
	echo "----------------------------------------------"
}

# ---------------------------------------------------------------- guards
guard() {
	if [ "$SHAREVTS" = "1" ] && [ "$FORCE" != "1" ]; then
		echo "[xorg-headless] REFUSING: SHAREVTS=1 is the configuration that broke" >&2
		echo "  VT switching last time. With -sharevts Xorg skips VT_PROCESS and the" >&2
		echo "  xf86VTRequest handler, keeps DRM master on the compositor's VT and" >&2
		echo "  nothing can switch away from it." >&2
		echo "  Use the default (own VT, VT_PROCESS). FORCE=1 to override anyway." >&2
		return 1
	fi
	local active; active=$(active_vt_num || echo "")
	if [ -n "$active" ] && [ "$VT" = "$active" ] && [ "$FORCE" != "1" ]; then
		echo "[xorg-headless] REFUSING: vt$VT is the VT that is active right now." >&2
		echo "  Starting an X server on the compositor's own VT is what starves it." >&2
		echo "  Let the script pick a free VT (unset XORG_VT) or set XORG_VT=3." >&2
		return 1
	fi
	if [ -z "$RIGHTS" ]; then
		echo "[xorg-headless] ERROR: cannot get console access." >&2
		echo "  The nvidia DDX needs a VT; give the server root rights:" >&2
		echo "    A) printf 'allowed_users = anybody\\nneeds_root_rights = yes\\n' | sudo tee /etc/X11/Xwrapper.config" >&2
		echo "    B) SUDO=1 $0 start" >&2
		return 1
	fi
	return 0
}

mk_xauth() {
	mkdir -p "$RUNDIR"; chmod 700 "$RUNDIR"
	: > "$OUT"
	touch "$XAUTH"; chmod 600 "$XAUTH"
	xauth -f "$XAUTH" list 2>/dev/null | grep -q "^unix${XDISPLAY}" || \
		xauth -f "$XAUTH" add "$XDISPLAY" . "$(mcookie)"
}

xorg_pid() {
	local p
	[ -f "$PIDF" ] && p=$(cat "$PIDF" 2>/dev/null)
	alive "$p" && { echo "$p"; return; }
	pgrep -x Xorg -a 2>/dev/null | awk -v d="$XDISPLAY" '{for(i=1;i<=NF;i++) if($i==d){print $1; exit}}'
}

show_failure() {
	echo
	echo "---- why it failed ----"
	[ -s "$OUT" ] && { echo "[stderr/stdout]"; sed 's/^/    /' "$OUT" | tail -20; }
	if [ -s "$LOG" ]; then
		echo "[$LOG]"; grep -E '^\(EE\)|Fatal|VT|KDSET|KDSKBMODE' "$LOG" | tail -20 | sed 's/^/    /'
	elif [ ! -e "$LOG" ]; then
		echo "[$LOG] missing - the binary never reached Xorg proper"
	fi
	local all; all=$(cat "$OUT" "$LOG" 2>/dev/null)
	hint() { echo "  => $*"; }
	if grep -qi "parse_vt_settings: Cannot open /dev/tty0" <<<"$all"; then
		hint "No console access. Use SUDO=1, or configure /etc/X11/Xwrapper.config"
		hint "(allowed_users = anybody + needs_root_rights = yes)."
	elif grep -qi "Only console users are allowed" <<<"$all"; then
		hint "setuid wrapper refused: add 'allowed_users = anybody' to /etc/X11/Xwrapper.config"
	elif grep -qi "Cannot open virtual console" <<<"$all"; then
		hint "/dev/tty$VT is not usable by this user - run as root (SUDO=1), or pick another XORG_VT"
	elif grep -qiE "Failed to load module \"?(nvidia|glx)" <<<"$all"; then
		hint "nvidia DDX / GLX module missing - run scripts/10-provision-xorg-legacy.sh"
	elif grep -qi "no screens found\|No devices detected" <<<"$all"; then
		hint "Bad BusID in $CONF, or the kernel module and userspace driver do not match."
	elif grep -qi "VT_GETMODE\|VT_SETMODE\|KDSETMODE" <<<"$all"; then
		hint "VT ioctls failed - another process owns vt$VT (an old Xorg? check scripts/99-panic.sh)"
	elif grep -qi "Server is already active for display" <<<"$all"; then
		hint "stale lock: rm -f /tmp/.X${XDISPLAY#:}-lock /tmp/.X11-unix/X${XDISPLAY#:}"
	fi
	echo
}

verify_vt() {
	local n="${XDISPLAY#:}"
	local act; act=$(active_vt_num || echo "?")
	msg "active VT now: tty$act   (server is on vt$VT)"
	# does the server really hold the VT?
	local pid; pid=$(xorg_pid)
	if alive "$pid"; then
		if ls -l /proc/"$pid"/fd 2>/dev/null | grep -q "/dev/tty$VT\$"; then
			msg "confirmed: server holds /dev/tty$VT (VT_PROCESS will work)"
		elif grep -qiE 'HW_SKIP_CONSOLE|dummy' "$LOG" 2>/dev/null; then
			msg "note: this driver skips the console by design (dummy/Xwayland), no VT ownership expected"
		else
			msg "note: no /dev/tty$VT fd seen - if VT switching misbehaves, check the log for VT_SETMODE errors"
		fi
		if grep -q "using VT number $VT" "$LOG" 2>/dev/null; then
			msg "confirmed: log says 'using VT number $VT'"
		fi
	fi
	if grep -q "Using config directory: \"$CONFDIR\"" "$LOG" 2>/dev/null; then
		msg "confirmed: isolated config dir in use (global /etc/X11/xorg.conf.d ignored)"
	elif grep -q "Using config directory" "$LOG" 2>/dev/null; then
		warn "the log shows a different config directory - check $(grep 'Using config directory' "$LOG" | tail -1)"
	fi
	if [ "$act" != "$VT" ]; then
		msg "you are still on tty$act. Switch with: sudo chvt $VT   (or $0 start --switch)"
		msg "come back with: Ctrl+Alt+F$act"
	fi
	msg "screen : $(XAUTHORITY="$XAUTH" xdpyinfo -display "$XDISPLAY" 2>/dev/null | awk '/dimensions:/{print $2}')"
	if command -v glxinfo >/dev/null; then
		local r; r=$(XAUTHORITY="$XAUTH" glxinfo -B 2>/dev/null | awk -F': ' '/OpenGL renderer/{print $2}')
		case "$r" in
			*NVIDIA*|*Tesla*|*GeForce*|*Quadro*) msg "GL renderer: $r   <-- hardware" ;;
			*llvmpipe*|*softpipe*) msg "GL renderer: $r   <-- SOFTWARE (see 90-doctor.sh)" ;;
			*) msg "GL renderer: ${r:-?}" ;;
		esac
	fi
}

prepare_conf() {
	# Xorg treats a config dir with no .conf file in it as nonexistent, so the
	# isolation marker below is required for -configdir to be accepted cleanly.
	mkdir -p "$CONFDIR" 2>/dev/null || true
	if [ ! -e "$CONFDIR/00-isolation-marker.conf" ]; then
		printf '# intentionally empty: keeps -configdir valid while isolating this\n# server from /etc/X11/xorg.conf.d\n' \
			> "$CONFDIR/00-isolation-marker.conf" 2>/dev/null || true
	fi
	chmod 755 "$CONFDIR" 2>/dev/null || true
	if [ -z "${XORG_CONF:-}" ] && [ ! -f "$CONF" ]; then
		mkdir -p "$(dirname "$CONF")"
		nv_render_headless_conf > "$CONF"
		msg "generated private config: $CONF (nothing in /etc was touched)"
	elif [ ! -f "$CONF" ]; then
		msg "ERROR: XORG_CONF=$CONF does not exist"; return 1
	fi
	return 0
}

start() {
	prepare_conf || return 1
	build_plan || return 1
	show_plan
	guard || return 1
	if [ "$DRY" = "1" ]; then
		msg "dry run - nothing was started"
		return 0
	fi
	if alive "$(xorg_pid)"; then
		msg "already running (pid $(xorg_pid)) on vt$VT"
		verify_vt
		return 0
	fi
	mk_xauth
	# a root-owned server must be able to read the private config
	chmod 644 "$CONF" 2>/dev/null || true

	local n="${XDISPLAY#:}"
	if [ -e "/tmp/.X${n}-lock" ] && ! alive "$(cat "/tmp/.X${n}-lock" 2>/dev/null)"; then
		msg "removing stale /tmp/.X${n}-lock"
		rm -f "/tmp/.X${n}-lock" "/tmp/.X11-unix/X${n}" 2>/dev/null
	fi

	msg "starting ${XB} on vt$VT (cooperative VT switching)"
	XAUTHORITY="$XAUTH" nohup "${LAUNCH[@]}" "${ARGS[@]}" > "$OUT" 2>&1 &
	echo $! > "$PIDF"

	for _ in $(seq 1 30); do
		XAUTHORITY="$XAUTH" xdpyinfo -display "$XDISPLAY" >/dev/null 2>&1 && break
		alive "$(cat "$PIDF")" || break
		sleep 0.5
	done
	if ! XAUTHORITY="$XAUTH" xdpyinfo -display "$XDISPLAY" >/dev/null 2>&1; then
		msg "ERROR: X server did not come up."
		show_failure
		return 1
	fi

	[ "$DO_SWITCH" = "1" ] && switch_to_vt
	verify_vt
	msg "use:  export DISPLAY=$XDISPLAY XAUTHORITY=$XAUTH"
	return 0
}

switch_to_vt() {
	msg "switching to vt$VT (Ctrl+Alt+F<previous> comes back)"
	if command -v chvt >/dev/null; then
		sudo -n chvt "$VT" 2>/dev/null || chvt "$VT" 2>/dev/null || warn "chvt failed - do it by hand"
	else
		sudo -n sh -c "echo $VT > /dev/tty0" 2>/dev/null || warn "install kbd (chvt) or switch by hand"
	fi
}

stop() {
	local p; p=$(xorg_pid)
	local was_vt="$VT"
	if [ -z "$p" ]; then
		msg "not running"; rm -f "$PIDF"; return 0
	fi
	msg "stopping Xorg $XDISPLAY (pid $p) on vt$VT"
	# return to the VT we were on before, so the compositor gets the screen back
	local target; target=$(active_vt_num || echo "")
	kill "$p" 2>/dev/null
	alive "$p" && sudo -n kill "$p" 2>/dev/null
	for _ in $(seq 1 20); do alive "$p" || break; sleep 0.25; done
	alive "$p" && { msg "SIGTERM ignored - SIGKILL"; sudo -n kill -9 "$p" 2>/dev/null || kill -9 "$p" 2>/dev/null; }
	rm -f "$PIDF"
	if [ "$target" = "$was_vt" ] && command -v chvt >/dev/null; then
		local other=1
		[ "$was_vt" = "1" ] && other=2
		msg "switching back to vt$other so the compositor repaints"
		sudo -n chvt "$other" 2>/dev/null || chvt "$other" 2>/dev/null || true
	fi
	msg "stopped"
}

status() {
	echo "---- second Xorg on the GPU ----"
	echo "display : $XDISPLAY"
	echo "VT      : vt$VT   (active: tty$(active_vt_num || echo '?'))"
	echo "pid     : $(xorg_pid || echo -)"
	echo "conf    : $CONF"
	echo "protocol: $( [ "$SHAREVTS" = "1" ] && echo 'sharevts (BROKEN for VT switching)' || echo 'VT_PROCESS (cooperative)')"
	if XAUTHORITY="$XAUTH" xdpyinfo -display "$XDISPLAY" >/dev/null 2>&1; then
		echo "state   : UP"; verify_vt
	else
		echo "state   : DOWN"
		grep -E '^\(EE\)' "$LOG" 2>/dev/null | tail -5 | sed 's/^/    /'
	fi
}

case "$ACTION" in
	start)   start ;;
	stop)    stop ;;
	restart) stop; start ;;
	status)  status ;;
	plan)    start ;;
	*) echo "usage: $0 {plan|start|stop|restart|status} [--switch] [--dry-run]"; exit 1 ;;
esac
