#!/bin/bash
# 90-doctor.sh - diagnose "why is my app software-rendered / why is the window black?"
#
#   scripts/90-doctor.sh            # read-only checks
#   scripts/90-doctor.sh --test     # also run a 5-frame bridge self-test
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib-nvidia.sh
. "$here/scripts/lib-nvidia.sh"

XDISPLAY="${XFDISPLAY:-:1}"
RUNDIR="${XFDIR:-/tmp/xfd-$XDISPLAY}"
XAUTH="$RUNDIR/Xauthority"
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
info() { printf '       %s\n' "$*"; }

DISTRO=$(nv_distro)
V=""

echo "=== 1. driver (distro: $DISTRO) ==="
if nv_loaded; then
	V=$(nv_version || true)
	if [ -n "$V" ]; then
		ok "kernel module loaded, version $V (branch ${V%%.*})"
		info "$(nv_branch_note "${V%%.*}")"
	else
		bad "module is loaded (sysfs/$NV_DEVCTL present) but its version is unreadable"
		info "checked: $NV_SYSFS_VERSION, nvidia-smi, $NV_PROC_VERSION, modinfo"
		info "the module IS loaded - only the version-dependent steps are affected"
	fi
else
	bad "NVIDIA kernel module not loaded"
	info "checked: $NV_SYSFS_DIR, $NV_PROC_VERSION, $NV_DEVCTL, lsmod"
	case "$DISTRO" in
		arch) info "Arch: pacman -Q nvidia-utils; Kepler/Maxwell need nvidia-470xx-dkms (AUR)" ;;
	esac
fi
if command -v nvidia-smi >/dev/null 2>&1; then
	nvidia-smi --query-gpu=name,driver_version,pci.bus_id --format=csv,noheader 2>/dev/null | sed 's/^/       /'
elif [ "$DISTRO" = arch ]; then
	warn "nvidia-smi not found (it lives in nvidia-utils / nvidia-<branch>xx-utils)"
fi
[ -e /dev/nvidia0 ]   && ok "/dev/nvidia0 present"   || warn "/dev/nvidia0 missing (fine on some container setups, fatal on others)"
[ -e /dev/uinput ]    && ok "/dev/uinput present"    || warn "/dev/uinput missing - X input injection may not work"
[ -r /sys/module/nvidia_drm/parameters/modeset ] && \
	ok "nvidia-drm modeset=$(cat /sys/module/nvidia_drm/parameters/modeset)" || \
	warn "nvidia-drm not loaded (irrelevant for the mirror, needed for a Wayland compositor on the GPU)"

echo "=== 1b. console access (decides whether root is needed) ==="
if [ -w /dev/tty0 ]; then
	ok "/dev/tty0 is writable by $(id -un) - the server can run as you"
else
	warn "/dev/tty0 is not writable by $(id -un) - the server must run as root"
	info "reason: xf86OpenConsole() -> linux_parse_vt_settings() opens /dev/tty0;"
	info "        only drivers answering HW_SKIP_CONSOLE (dummy) skip it, nvidia does not."
	if [ -f /etc/X11/Xwrapper.config ] && \
	   grep -qiE '^[[:space:]]*needs_root_rights[[:space:]]*=[[:space:]]*yes' /etc/X11/Xwrapper.config; then
		ok "/etc/X11/Xwrapper.config keeps root rights (needs_root_rights = yes)"
		ok "allowed_users = $(sed -n 's/^[[:space:]]*allowed_users[[:space:]]*=[[:space:]]*//p' /etc/X11/Xwrapper.config)"
	else
		warn "/etc/X11/Xwrapper.config does not keep root rights"
		info "the wrapper DROPS root when every /dev/dri/cardN supports KMS - which is"
		info "the normal case with nvidia-drm, and then the server cannot open /dev/tty0."
		info "fix: printf 'allowed_users = anybody\\nneeds_root_rights = yes\\n' | sudo tee /etc/X11/Xwrapper.config"
		info "  or: SUDO=1 scripts/20-xorg-headless.sh start"
	fi
fi

echo "=== 2. driver layout ==="
LIBS=$(nv_libdirs | tr '\n' ' ')
[ -n "$LIBS" ] && ok "driver libs in: $LIBS" || bad "no libGLX_nvidia.so.0 / libEGL_nvidia.so.0 found anywhere"
if command -v ldconfig >/dev/null && ldconfig -p 2>/dev/null | grep -q libGLX_nvidia; then
	ok "libGLX_nvidia is on the loader path"
else
	bad "libGLX_nvidia is NOT on the loader path"
	info "fix: echo <libdir> > /etc/ld.so.conf.d/10-nvidia.conf && ldconfig"
	info "or just run scripts/10-provision-xorg-legacy.sh as root"
fi
DDX=$(nv_ddx_module || true)
[ -n "$DDX" ] && ok "Xorg DDX: $DDX" || bad "nvidia_drv.so missing - need: $(nv_pkg_ddx "${V%%.*}")"
GLX=$(nv_glx_server_module || true)
[ -n "$GLX" ] && ok "GLX server module: $GLX" \
	|| bad "libglxserver_nvidia.so missing -> GLX will be software"
ICD=$(nv_icd_json || true)
[ -n "$ICD" ] && ok "Vulkan ICD: $ICD" || warn "no Vulkan ICD (Vulkan apps would not see the GPU)"
CONF=$(nv_xorg_conf)
[ -f "$CONF" ] && ok "headless xorg conf: $CONF" || bad "$CONF missing - run scripts/10-provision-xorg-legacy.sh"

echo "=== 3. headless X + GL ==="
if XAUTHORITY="$XAUTH" xdpyinfo -display "$XDISPLAY" >/dev/null 2>&1; then
	ok "Xorg running on $XDISPLAY ($(XAUTHORITY="$XAUTH" xdpyinfo -display "$XDISPLAY" | awk '/dimensions:/{print $2}'))"
	if command -v glxinfo >/dev/null; then
		r=$(XAUTHORITY="$XAUTH" glxinfo -B 2>/dev/null | awk -F': ' '/OpenGL renderer/{print $2}')
		case "$r" in
			*NVIDIA*|*Tesla*|*GeForce*|*Quadro*) ok "GL renderer: $r" ;;
			"") warn "glxinfo produced no renderer line" ;;
			*llvmpipe*|*softpipe*|*swrast*) bad "GL renderer is SOFTWARE ($r)" ;;
			*) warn "GL renderer: $r" ;;
		esac
	else
		warn "glxinfo not installed ($( [ "$DISTRO" = arch ] && echo 'pacman -S mesa-utils' || echo 'apt install mesa-utils'))"
	fi
else
	warn "Xorg not running on $XDISPLAY (scripts/20-xorg-headless.sh start)"
	grep -hE '^\(EE\)' "$RUNDIR/Xorg.log" 2>/dev/null | tail -5 | sed 's/^/       /'
fi

echo "=== 4. Wayland side ==="
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
	ok "WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
	if command -v wayland-info >/dev/null; then
		wayland-info 2>/dev/null | grep -q xdg_wm_base && ok "compositor offers xdg_wm_base" \
			|| bad "compositor has no xdg_wm_base"
		wayland-info 2>/dev/null | grep -q zwp_linux_dmabuf_v1 \
			&& ok "compositor offers linux-dmabuf" || warn "no linux-dmabuf (shm copy is the only path)"
	fi
else
	bad "not inside a Wayland session (WAYLAND_DISPLAY unset)"
fi

echo "=== 5. bridge self-test ==="
if [ "${1:-}" = "--test" ]; then
	if [ -x "$here/xfbridge" ] && [ -n "${WAYLAND_DISPLAY:-}" ] &&
	   XAUTHORITY="$XAUTH" xdpyinfo -display "$XDISPLAY" >/dev/null 2>&1; then
		if XAUTHORITY="$XAUTH" timeout 20 "$here/xfbridge" --x-display "$XDISPLAY" \
		     --frames 5 --dump-frame /tmp/xfbridge-selftest.ppm -v 2>&1 | sed 's/^/       /'; then
			ok "committed 5 frames; dump: /tmp/xfbridge-selftest.ppm"
		else
			bad "bridge self-test failed"
		fi
	else
		warn "skipped (no Xorg / no Wayland / not built)"
	fi
else
	echo "  (re-run with --test to commit 5 frames and dump one)"
fi
