#!/bin/bash
# 10-provision-xorg-legacy.sh - make a legacy NVIDIA box able to run a HEADLESS,
# hardware-accelerated Xorg (no monitor, no Xwayland, no GBM needed).
#
# Target: Kepler/Maxwell/Pascal on the 390-470 drivers - e.g. a GTX 660 Ti on
# 470.256.02 - and equally fine on modern cards.
#
# RUN AS ROOT.  Idempotent, and **never overwrites a file without backing it up**
# (see scripts/05-system-config.sh list|restore).
#
# It does NOT write anything into /etc/X11 by default, because a file there is
# merged into *every* X server on the machine - including the one your desktop
# uses. The per-display config is written privately by 20-xorg-headless.sh.
# To install a global snippet anyway (e.g. for a headless server with no desktop):
#     INSTALL_GLOBAL_CONF=1 sudo -E bash scripts/10-provision-xorg-legacy.sh
#
#   sudo bash scripts/10-provision-xorg-legacy.sh
#   sudo XORG_CONF=/etc/X11/xorg.conf.d/20-nvidia-headless.conf bash scripts/10-...
#
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-nvidia.sh
. "$here/lib-nvidia.sh"

DISTRO=$(nv_distro)
echo "== distro: $DISTRO"

# ------------------------------------------------------------- 0. driver?
if ! nv_loaded; then
	echo
	echo "!! The NVIDIA kernel module does not look loaded." >&2
	echo "   checked: $NV_SYSFS_DIR  $NV_PROC_VERSION  $NV_DEVCTL  lsmod" >&2
	case "$DISTRO" in
		arch) echo "   Arch: pacman -Q nvidia-utils | and check 'dmesg | grep -i nvidia'" >&2
		      echo "   If you use Kepler/Maxwell: the driver is nvidia-470xx-dkms + nvidia-470xx-utils (AUR)." >&2 ;;
	esac
	echo "   In a container the GPU must be passed through (/dev/nvidia*)." >&2
	exit 1
fi

KVER=$(nv_version) || KVER=""
if [ -z "$KVER" ]; then
	echo "!! module is loaded but the version could not be determined from:" >&2
	echo "   $NV_SYSFS_VERSION / nvidia-smi / $NV_PROC_VERSION / modinfo" >&2
	echo "   continuing anyway; only the version-matched package step is affected." >&2
	BRANCH=""
else
	BRANCH="${KVER%%.*}"
	echo "== driver $KVER  -> branch $BRANCH"
	echo "   $(nv_branch_note "$BRANCH")"
fi

# Known packaged layouts ------------------------------------------------
echo "== layout"
printf '   libs      : %s\n' "$(nv_libdirs | tr '\n' ' ')"
printf '   DDX       : %s\n' "$(nv_ddx_module || echo MISSING)"
printf '   GLX server: %s\n' "$(nv_glx_server_module || echo MISSING)"
printf '   vulkan ICD: %s\n' "$(nv_icd_json || echo MISSING)"
printf '   egl vendor: %s\n' "$(nv_egl_vendor_json || echo MISSING)"

# ---------------------------------------------------------- 1. loader path
# Only needed where the driver libs live outside the default search path
# (typical for CUDA/Colab images). Arch/Debian/Fedora packages install into
# /usr/lib, which is already searched - nothing to do there.
needs_path=0
for d in $(nv_libdirs); do
	nv_libdir_on_loader_path "$d" || needs_path=1
done
if [ "$needs_path" = "1" ]; then
	for d in $(nv_libdirs); do
		nv_libdir_on_loader_path "$d" && continue
		echo "== adding $d to the loader path"
		printf '%s\n' "$d" > "/etc/ld.so.conf.d/10-nvidia-$(printf '%s' "$d" | tr '/' '_').conf"
	done
	ldconfig
else
	echo "== loader path already covers the driver libs"
fi

# ------------------------------------------------------- 2. Xorg + nvidia DDX
PKG_HINT=$(nv_pkg_ddx "${BRANCH:-<branch>}")
echo "== X package that provides the DDX: $PKG_HINT"

DDXFOUND=0; nv_ddx_module >/dev/null && DDXFOUND=1
if [ "$DDXFOUND" = "0" ]; then
	case "$DISTRO" in
		arch)
			echo "!! nvidia_drv.so missing but nvidia-utils is supposed to ship it." >&2
			echo "   reinstall:  pacman -S nvidia-utils   (or nvidia-${BRANCH}xx-utils for 470)" >&2
			echo "   if your driver is DKMS/AUR: pacman -S --overwrite '*' ${PKG_HINT%% *}" >&2 ;;
		debian)
			if [ -n "$BRANCH" ]; then
				apt-get update -qq
				apt-get install -y --no-install-recommends \
					"xserver-xorg-video-nvidia-$BRANCH=$KVER-0ubuntu1" \
					"libnvidia-cfg1-$BRANCH=$KVER-0ubuntu1" \
					|| apt-get install -y --no-install-recommends \
						"xserver-xorg-video-nvidia-$BRANCH" "libnvidia-cfg1-$BRANCH" || true
			fi ;;
		fedora)
			dnf install -y "xorg-x11-drv-nvidia-${BRANCH}-cuda" || true ;;
	esac
	nv_ddx_module >/dev/null && echo "== DDX installed: $(nv_ddx_module)" \
		|| echo "!! DDX still missing; Xorg will not be able to drive the GPU" >&2
fi

# ---------------------------------------------------- 3. GLX server module link
GLXSRV=$(nv_glx_server_module || true)
EXTDIR=$(nv_glx_extensions_dir)
if [ -n "$GLXSRV" ]; then
	base=$(basename "$GLXSRV")
	if [ "$base" = "libglxserver_nvidia.so" ]; then
		echo "== GLX server module already in place: $GLXSRV"
	else
		mkdir -p "$EXTDIR"
		ln -sf "$GLXSRV" "$EXTDIR/libglxserver_nvidia.so"
		echo "== linked $EXTDIR/libglxserver_nvidia.so -> $GLXSRV"
	fi
else
	echo "!! libglxserver_nvidia.so not found - GLX will fall back to software." >&2
	echo "   Arch: it lives in nvidia-utils (/usr/lib/xorg/modules/extensions/)." >&2
fi

# some layouts need the DDX dir exposed to Xorg's module path
if [ -d /usr/lib64-nvidia/xorg/modules ]; then
	mkdir -p /usr/lib/x86_64-linux-gnu/nvidia/xorg
	for f in /usr/lib64-nvidia/xorg/modules/*.so*; do
		[ -e "$f" ] && ln -sf "$f" /usr/lib/x86_64-linux-gnu/nvidia/xorg/
	done
	ldconfig
fi

# ------------------------------------------------------- 4. Vulkan / glvnd
if ! nv_icd_json >/dev/null; then
	ICDLIB=$(nv_libdirs | while read -r d; do [ -e "$d/libGLX_nvidia.so.0" ] && { echo "$d/libGLX_nvidia.so.0"; break; }; done)
	if [ -n "$ICDLIB" ]; then
		printf '{"file_format_version":"1.0.0","ICD":{"library_path":"%s"}}\n' "$ICDLIB" \
			| managed_write /etc/vulkan/icd.d/nvidia_icd.json
		echo "== Vulkan ICD -> $ICDLIB"
	fi
else
	echo "== Vulkan ICD present: $(nv_icd_json)"
fi
if ! nv_egl_vendor_json >/dev/null; then
	printf '{"file_format_version":"1.0.0","ICD":{"library_path":"libEGL_nvidia.so.0"}}\n' \
		| managed_write /usr/share/glvnd/egl_vendor.d/10_nvidia.json
	echo "== glvnd EGL vendor json"
fi

# ------------------------------------------- 5. configuration: NOT in /etc
# Nothing here writes to /etc/X11 unless INSTALL_GLOBAL_CONF=1. The private
# per-display config is generated by 20-xorg-headless.sh into /tmp/xfd-:N/.
echo "== configuration"
if [ "${INSTALL_GLOBAL_CONF:-0}" = "1" ]; then
	GCONF=$(nv_global_conf_path)
	echo "   INSTALL_GLOBAL_CONF=1 -> $GCONF (a backup is kept; undo with 05-system-config.sh restore)"
	nv_render_headless_conf | managed_write "$GCONF"
else
	echo "   /etc/X11 left untouched (private config is written per display by"
	echo "   20-xorg-headless.sh; use INSTALL_GLOBAL_CONF=1 for a system-wide snippet)"
	echo "   existing files that a global snippet would have merged with:"
	for f in /etc/X11/xorg.conf /etc/X11/xorg.conf.d/*.conf; do
		[ -e "$f" ] && echo "     - $f"
	done
fi

# ------------------------------------------------------- 6. nvidia-drm modeset
MODESET_OK=0
[ -r /sys/module/nvidia_drm/parameters/modeset ] && \
	[ "$(cat /sys/module/nvidia_drm/parameters/modeset)" = "Y" ] && MODESET_OK=1
if [ "$MODESET_OK" = "1" ]; then
	echo "== nvidia-drm modeset=1 already active"
else
	printf 'options nvidia_drm modeset=1\n' | managed_write /etc/modprobe.d/nvidia-drm-modeset.conf
	echo "== /etc/modprobe.d/nvidia-drm-modeset.conf managed (needed by Wayland compositors)"
	[ "$DISTRO" = "arch" ] && echo "   rebuild the initramfs to apply early:  mkinitcpio -P"
fi

echo
echo "== files this tool has ever changed on this machine:"
manifest_list
echo
echo "provisioning done. Next, as your normal user:"
echo "   bash scripts/20-xorg-headless.sh start"
echo "   bash scripts/90-doctor.sh"
