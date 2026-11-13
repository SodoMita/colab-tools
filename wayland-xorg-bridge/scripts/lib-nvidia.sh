# lib-nvidia.sh - shared, distro-aware NVIDIA/driver detection.
#
# Sourced by 10-provision-xorg-legacy.sh, 20-xorg-headless.sh, 90-doctor.sh.
# Never fails the caller: every function prints what it found and returns 0/1.
#
# Detection order for the driver version (first hit wins):
#   1. /sys/module/nvidia/version      <- most reliable, works for open + proprietary
#   2. nvidia-smi --query-gpu=driver_version
#   3. /proc/driver/nvidia/version     <- parsed tolerantly (format varies by branch!)
#   4. modinfo -F version nvidia
#
# The 3rd one is why this file exists: 495+ prints
#   "NVRM version: NVIDIA UNIX Open Kernel Module for x86_64  580.82.07 ..."
# while 470 and older print
#   "NVRM version: NVIDIA UNIX x86_64 Kernel Module  470.256.02 ..."
# and 304/340-era print yet another variant. Match the arch token, then take the
# first version-looking number after it.

# ---- overridable paths (also makes the functions unit-testable) ----
NV_SYSFS_VERSION="${NV_SYSFS_VERSION:-/sys/module/nvidia/version}"
NV_SYSFS_DIR="${NV_SYSFS_DIR:-/sys/module/nvidia}"
NV_PROC_VERSION="${NV_PROC_VERSION:-/proc/driver/nvidia/version}"
NV_DEVCTL="${NV_DEVCTL:-/dev/nvidiactl}"

# ------------------------------------------------------------------ distro
nv_distro() {
	if [ -f /etc/arch-release ]; then echo arch
	elif [ -f /etc/debian_version ]; then echo debian
	elif [ -f /etc/fedora-release ]; then echo fedora
	elif [ -f /etc/os-release ]; then
		. /etc/os-release 2>/dev/null
		case "${ID:-}" in
			arch|manjaro|endeavouros|garuda|artix) echo arch ;;
			*) echo "${ID:-unknown}" ;;
		esac
	else echo unknown; fi
}

# --------------------------------------------------------------- "loaded?"
nv_loaded() {
	[ -d "$NV_SYSFS_DIR" ] && return 0
	[ -r "$NV_PROC_VERSION" ] && return 0
	[ -e "$NV_DEVCTL" ] && return 0
	if command -v lsmod >/dev/null 2>&1; then
		lsmod 2>/dev/null | awk '$1=="nvidia"{f=1} END{exit !f}' && return 0
	fi
	return 1
}

nv_version() {
	local v

	# 1. sysfs
	if [ -r "$NV_SYSFS_VERSION" ]; then
		v=$(tr -d ' \t\r\n' < "$NV_SYSFS_VERSION")
		[ -n "$v" ] && { echo "$v"; return 0; }
	fi

	# 2. nvidia-smi (avoid the container lib path trap)
	if command -v nvidia-smi >/dev/null 2>&1; then
		v=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | tr -d ' \r')
		case "$v" in ''|*[!0-9.]*) : ;; *) echo "$v"; return 0 ;; esac
	fi

	# 3. /proc - tolerant of every known format
	if [ -r "$NV_PROC_VERSION" ]; then
		v=$(sed -n 's/.*\(x86_64\|aarch64\|arm64\|ppc64le\)[^0-9]*\([0-9][0-9]*\.[0-9][0-9]*\(\.[0-9][0-9]*\)\?\).*/\2/p' \
			"$NV_PROC_VERSION" 2>/dev/null | head -1)
		[ -n "$v" ] && { echo "$v"; return 0; }
		# last resort: any nnn.nn(.nn) in the file
		v=$(grep -oE '[0-9]{3}\.[0-9]{2,3}(\.[0-9]{2})?' "$NV_PROC_VERSION" 2>/dev/null | head -1)
		[ -n "$v" ] && { echo "$v"; return 0; }
	fi

	# 4. modinfo
	if command -v modinfo >/dev/null 2>&1; then
		v=$(modinfo -F version nvidia 2>/dev/null | head -1 | tr -d ' ')
		[ -n "$v" ] && { echo "$v"; return 0; }
	fi
	return 1
}

nv_branch() {
	local v; v=$(nv_version) || return 1
	echo "${v%%.*}"
}

# ------------------------------------------------------------- libs & modules
# Directories that actually contain the driver's user-space libraries.
nv_libdirs() {
	local d
	for d in /usr/lib /usr/lib64 /usr/lib/x86_64-linux-gnu \
	         /usr/lib64-nvidia /usr/lib/nvidia /usr/local/nvidia/lib /usr/local/nvidia/lib64; do
		[ -e "$d/libGLX_nvidia.so.0" ] || [ -e "$d/libEGL_nvidia.so.0" ] && echo "$d"
	done | awk '!seen[$0]++'
}

# Is a directory on the loader's default search path already?
nv_libdir_on_loader_path() {
	case "$1" in
		/usr/lib|/usr/lib64|/usr/lib/x86_64-linux-gnu|/lib|/lib64) return 0 ;;
	esac
	ldconfig -p 2>/dev/null | grep -q "=> $1/" && return 0
	return 1
}

# The Xorg driver module (DDX).
nv_ddx_module() {
	local f
	for f in /usr/lib/xorg/modules/drivers/nvidia_drv.so \
	         /usr/lib64/xorg/modules/drivers/nvidia_drv.so \
	         /usr/lib/xorg/modules/nvidia/nvidia_drv.so \
	         /usr/lib/x86_64-linux-gnu/nvidia/xorg/nvidia_drv.so; do
		[ -e "$f" ] && { echo "$f"; return 0; }
	done
	return 1
}

# The GLX *server* module - if this is not linked into the extensions dir, GLX
# silently degrades to software.
nv_glx_server_module() {
	local f
	for f in /usr/lib/xorg/modules/extensions/libglxserver_nvidia.so \
	         /usr/lib64/xorg/modules/extensions/libglxserver_nvidia.so \
	         /usr/lib64-nvidia/xorg/modules/extensions/libglxserver_nvidia.so.* \
	         /usr/lib/x86_64-linux-gnu/nvidia/xorg/libglxserver_nvidia.so.* \
	         /usr/lib/nvidia/xorg/libglxserver_nvidia.so.*; do
		for g in $f; do [ -e "$g" ] && { echo "$g"; return 0; }; done
	done
	return 1
}

nv_glx_extensions_dir() {
	for d in /usr/lib/xorg/modules/extensions /usr/lib64/xorg/modules/extensions; do
		[ -d "$d" ] && { echo "$d"; return 0; }
	done
	echo /usr/lib/xorg/modules/extensions
}

# Vulkan ICD + glvnd vendor files, wherever the distro put them.
nv_icd_json() {
	local f
	for f in /usr/share/vulkan/icd.d/nvidia_icd.json /etc/vulkan/icd.d/nvidia_icd.json \
	         /usr/share/vulkan/icd.d/nvidia_icd.*.json; do
		for g in $f; do [ -e "$g" ] && { echo "$g"; return 0; }; done
	done
	return 1
}

nv_egl_vendor_json() {
	local f
	for f in /usr/share/glvnd/egl_vendor.d/10_nvidia.json /usr/share/glvnd/egl_vendor.d/*nvidia*.json; do
		for g in $f; do [ -e "$g" ] && { echo "$g"; return 0; }; done
	done
	return 1
}

# --------------------------------------------------------------- packaging
# Package names that provide the pieces, per distro and branch.
nv_pkg_ddx() {
	local branch="$1"
	case "$(nv_distro)" in
		arch)   echo "nvidia-utils (DDX ships inside it; no separate package)" ;;
		debian) echo "xserver-xorg-video-nvidia-$branch + libnvidia-cfg1-$branch" ;;
		fedora) echo "xorg-x11-drv-nvidia-$branch-cuda (or akmod-nvidia-$branch)" ;;
		*)      echo "the xorg driver for branch $branch" ;;
	esac
}

nv_pkg_driver_hint() {
	local branch="$1"
	case "$(nv_distro)" in
		arch)
			case "$branch" in
				390|470) echo "nvidia-${branch}xx-dkms + nvidia-${branch}xx-utils (AUR) - mainline 'nvidia' dropped Kepler/Maxwell" ;;
				*)       echo "nvidia-open-dkms (or nvidia-dkms) + nvidia-utils" ;;
			esac ;;
		debian) echo "nvidia-driver-$branch (or nvidia-driver-${branch}-open)" ;;
		fedora) echo "akmod-nvidia-$branch" ;;
		*) echo "your distro's driver package for branch $branch" ;;
	esac
}

nv_branch_note() {
	case "$1" in
		390|418|440|450|460) echo "pre-470: no accelerated Xwayland at all - the headless-Xorg mirror is the only route" ;;
		470) echo "470.x: last Kepler branch, EGLStreams only, no GBM - the headless-Xorg mirror is the right answer" ;;
		495|510|515|520|525|530|535|540|545|550) echo "495+: GBM exists; native accelerated Xwayland is possible with a matching compositor" ;;
		*) echo "modern branch: GBM + explicit sync; native Wayland is usually the better path" ;;
	esac
}

nv_x_packages() {
	case "$(nv_distro)" in
		arch)   echo "xorg-server xorg-xauth xorg-xdpyinfo xorg-xwininfo xorg-xrandr xorg-xsetroot mesa-utils" ;;
		debian) echo "xserver-xorg-core xserver-xorg x11-xserver-utils xauth x11-utils mesa-utils x11-apps" ;;
		fedora) echo "xorg-x11-server-Xorg xorg-x11-xauth xorg-x11-utils mesa-demos xdotool" ;;
		*)      echo "" ;;
	esac
}

nv_install_x_packages() {
	local pkgs; pkgs=$(nv_x_packages)
	[ -z "$pkgs" ] && return 1
	case "$(nv_distro)" in
		arch)   pacman -S --needed --noconfirm $pkgs ;;
		debian) apt-get install -y --no-install-recommends $pkgs ;;
		fedora) dnf install -y $pkgs ;;
	esac
}

# Where should the headless xorg.conf live?
# Where the per-display config lives. PRIVATE by default: nothing in /etc is
# touched, so a normal X11 session is never affected by this tool.
# (An earlier version defaulted to /etc/X11/xorg.conf.d/, which both overwrote
#  user configuration and merged into every other X server on the machine.)
nv_xorg_conf() {
	local rundir="${XFDIR:-/tmp/xfd-${XFDISPLAY:-:1}}"
	echo "${XORG_CONF:-$rundir/xorg.conf}"
}

# The one global file a distro may need, only written when explicitly asked:
nv_global_conf_path() {
	case "$(nv_distro)" in
		arch) echo /etc/X11/xorg.conf.d/90-wayland-xorg-bridge.conf ;;
		*)    echo /etc/X11/xorg-gpu.conf ;;
	esac
}

# Xorg module path argument: only needed when the DDX lives somewhere unusual.
nv_modulepath() {
	local dirs=""
	local d
	for d in /usr/lib/xorg/modules /usr/lib64/xorg/modules \
	         /usr/lib/x86_64-linux-gnu/xorg/modules \
	         /usr/lib/x86_64-linux-gnu/nvidia/xorg /usr/lib/nvidia/xorg; do
		[ -d "$d" ] && dirs="$dirs,$d"
	done
	echo "${dirs#,}"
}

# ------------------------------------------------------- display ownership
# All of this exists because a second X server on a GPU that is CURRENTLY
# driving a monitor will take the display away from the running compositor
# (DRM master / modeset). That is not a VT-switching bug, it is a hijack, and it
# is what FORCE exists to prevent.

nv_drm_sysfs() { echo "${DRM_SYSFS:-/sys/class/drm}"; }

# cardN nodes whose PCI vendor is NVIDIA
nv_nvidia_cards() {
	local d; d=$(nv_drm_sysfs)/card
	local c v
	for c in "$(nv_drm_sysfs)"/card[0-9]*; do
		[ -e "$c/device/vendor" ] || continue
		v=$(cat "$c/device/vendor" 2>/dev/null)
		[ "$v" = "0x10de" ] && basename "$c"
	done
}

# Is a monitor currently connected to an NVIDIA card?
nv_display_attached() {
	local c f st
	for c in $(nv_nvidia_cards); do
		for f in "$(nv_drm_sysfs)/$c/$c"-*/status; do
			[ -e "$f" ] || continue
			st=$(cat "$f" 2>/dev/null)
			[ "$st" = "connected" ] && return 0
		done
	done
	return 1
}

# PIDs (other than $1) holding the NVIDIA DRM nodes open - i.e. a compositor or
# another X server already owns the card.
nv_card_holders() {
	local skip="${1:-0}" c node pid fd found=""
	for c in $(nv_nvidia_cards); do
		node="/dev/dri/$c"
		[ -e "$node" ] || continue
		for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
			[ "$pid" = "$skip" ] && continue
			for fd in /proc/"$pid"/fd/*; do
				if [ "$(readlink "$fd" 2>/dev/null)" = "$node" ]; then
					found="$found $pid:$(cat /proc/"$pid"/comm 2>/dev/null)"
					break
				fi
			done
		done
	done
	echo "$found" | tr ' ' '\n' | grep -v '^$' | sort -u
}

# A Wayland compositor process that might own the card
nv_compositor_running() {
	pgrep -x kwin_wayland >/dev/null 2>&1 && { echo "kwin_wayland"; return 0; }
	pgrep -x gnome-shell  >/dev/null 2>&1 && { echo "gnome-shell"; return 0; }
	pgrep -x sway         >/dev/null 2>&1 && { echo "sway"; return 0; }
	pgrep -x Hyprland     >/dev/null 2>&1 && { echo "Hyprland"; return 0; }
	pgrep -x weston       >/dev/null 2>&1 && { echo "weston"; return 0; }
	return 1
}

nv_modeset_enabled() {
	[ -r /sys/module/nvidia_drm/parameters/modeset ] || return 1
	[ "$(cat /sys/module/nvidia_drm/parameters/modeset)" = "Y" ]
}

# ============================================================================
# Managed writes: nothing global is ever touched without a backup + a manifest
# entry, so every change can be listed and undone (scripts/05-system-config.sh).
# ============================================================================

nv_state_dir() {
	echo "${XDG_DATA_HOME:-$HOME/.local/share}/wayland-xorg-bridge"
}
NV_MANIFEST() { echo "$(nv_state_dir)/manifest.tsv"; }

# managed_write <path>   (content on stdin)
#   - creates parent dirs
#   - if the file exists and differs: backs it up, records "modified"
#   - if it does not exist: records "created"
#   - if identical: does nothing
#   - refuses to run as non-root for paths outside $HOME unless $MANAGED_AS_ROOT=1
managed_write() {
	local path="$1"
	local st dir man ts flat backup
	st=$(nv_state_dir); dir="$st/backups"; man="$st/manifest.tsv"
	mkdir -p "$dir" "$(dirname "$path")" 2>/dev/null || true
	ts=$(date +%Y%m%d-%H%M%S)

	local tmp; tmp=$(mktemp) || return 1
	cat > "$tmp"

	if [ -e "$path" ] && cmp -s "$tmp" "$path"; then
		rm -f "$tmp"
		echo "  = unchanged: $path"
		return 0
	fi

	if [ -e "$path" ]; then
		flat=$(printf '%s' "$path" | sed 's|^/||; s|/|__|g')
		backup="$dir/${ts}.${flat}"
		cp -a "$path" "$backup" || { rm -f "$tmp"; echo "  !! cannot back up $path" >&2; return 1; }
		printf '%s\tmodified\t%s\t%s\n' "$path" "$backup" "$ts" >> "$man"
		echo "  ~ replaced: $path   (backup: $backup)"
	else
		printf '%s\tcreated\t-\t%s\n' "$path" "$ts" >> "$man"
		echo "  + created: $path"
	fi
	mv "$tmp" "$path"
}

manifest_list() {
	local man; man=$(NV_MANIFEST)
	[ -f "$man" ] || { echo "  (manifest is empty - this tool has not written any system file)"; return 0; }
	printf '  %-52s %-9s %s\n' "PATH" "ACTION" "BACKUP"
	while IFS=$'\t' read -r p a b t; do
		printf '  %-52s %-9s %s\n' "$p" "$a" "$b"
	done < "$man"
}

manifest_restore() {
	local man; man=$(NV_MANIFEST)
	[ -f "$man" ] || { echo "nothing to restore: no manifest"; return 0; }
	# restore in reverse order so repeated writes unwind correctly
	tac "$man" > "$man.rev" 2>/dev/null || cp "$man" "$man.rev"
	while IFS=$'\t' read -r p a b t; do
		[ -n "$p" ] || continue
		if [ "$a" = "modified" ] && [ -f "$b" ]; then
			cp -a "$b" "$p" && echo "  restored: $p  (from $b)"
		elif [ "$a" = "created" ]; then
			[ -e "$p" ] && { rm -f "$p" && echo "  removed:  $p  (was created by this tool)"; }
		fi
	done < "$man.rev"
	rm -f "$man.rev"
	mv "$man" "$man.restored.$(date +%Y%m%d-%H%M%S)"
	echo "  manifest archived"
}

# a snapshot of the files that matter for a normal X11 session, before touching
# anything - so a restore is possible even without our manifest
system_config_backup() {
	local out="$1"
	mkdir -p "$out" || return 1
	local f
	for f in /etc/X11/xorg.conf /etc/X11/xorg.conf.d/*.conf \
	         /etc/X11/Xwrapper.config /etc/modprobe.d/*nvidia*.conf \
	         /etc/X11/xorg-gpu.conf; do
		[ -e "$f" ] || continue
		cp -a "$f" "$out/" 2>/dev/null && echo "  saved $f"
	done
	echo "  -> $out"
}

# ------------------------------------------------------------------ geometry
nv_busid() {
	local b
	if command -v nvidia-smi >/dev/null 2>&1; then
		b=$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader 2>/dev/null | head -1)
	fi
	if [ -z "${b:-}" ]; then
		# fall back to sysfs
		local c
		for c in "$(nv_drm_sysfs)"/card[0-9]*; do
			[ "$(cat "$c/device/vendor" 2>/dev/null)" = "0x10de" ] || continue
			b=$(cat "$c/device/uevent" 2>/dev/null | sed -n 's/^PCI_SLOT_NAME=//p')
			[ -n "$b" ] && break
		done
	fi
	[ -n "${b:-}" ] || { echo "${XORG_BUSID:-PCI:1:0:0}"; return; }
	local dom rest bus dev fn
	dom=${b%%:*}; rest=${b#*:}; bus=${rest%%:*}; rest=${rest#*:}; dev=${rest%%.*}; fn=${rest##*.}
	echo "PCI:$((16#$bus)):$((16#$dev)):$((16#$fn))"
}

# Write a headless-capable Device/Screen config. Used both for a private
# per-display conf (default) and for a global snippet (opt-in).
nv_render_headless_conf() {
	local busid; busid=$(nv_busid)
	cat <<CONF
# Generated by wayland-xorg-bridge - headless-capable, GPU-accelerated Xorg.
# No monitor required (AllowEmptyInitialConfiguration); no /dev/dri needed.
Section "ServerLayout"
    Identifier "Layout0"
    Screen 0 "Screen0"
EndSection

Section "ServerFlags"
    Option "AutoAddDevices"    "false"
    Option "AutoEnableDevices" "false"
EndSection

Section "Device"
    Identifier "GPU"
    Driver     "nvidia"
    BusID      "$busid"
    Option     "AllowEmptyInitialConfiguration" "true"
    # Kepler/Maxwell that still refuse to start with no display attached:
    #Option    "UseDisplayDevice" "none"
EndSection

Section "Monitor"
    Identifier  "Monitor0"
    HorizSync   1-1000
    VertRefresh 1-1000
EndSection

Section "Screen"
    Identifier  "Screen0"
    Device      "GPU"
    Monitor     "Monitor0"
    DefaultDepth 24
    SubSection "Display"
        Depth   24
        Modes   "1920x1080" "1600x900" "1280x720" "1024x768"
        Virtual 1920 1080
    EndSubSection
EndSection
CONF
}
