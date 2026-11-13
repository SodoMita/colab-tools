#!/bin/bash
# 00-build.sh - build xfbridge (installs the dev packages it needs)
#
#   ./scripts/00-build.sh            # install deps (if possible) and build
#   NO_APT=1 ./scripts/00-build.sh   # build only, no package installation
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

PKGS_DEB="build-essential pkg-config libwayland-dev wayland-protocols
          libxcb1-dev libxcb-shm0-dev libxcb-damage0-dev
          libxcb-xfixes0-dev libxcb-xtest0-dev"
PKGS_RPM="gcc make pkgconf-pkg-config wayland-devel wayland-protocols-devel
          libxcb-devel xcb-util-devel"
PKGS_ARCH="base-devel pkgconf wayland wayland-protocols libxcb"

have_pkg() { pkg-config --exists "$1" 2>/dev/null; }

missing=""
for p in wayland-client xcb xcb-shm xcb-damage xcb-xfixes xcb-xtest; do
	have_pkg "$p" || missing="$missing $p"
done
[ -n "$missing" ] || missing="$(command -v wayland-scanner >/dev/null || echo wayland-scanner)"

if [ -n "$missing" ]; then
	echo "== installing build dependencies:$missing"
	if [ "${NO_APT:-0}" = "1" ]; then
		echo "NO_APT=1 set - install them yourself, then re-run." >&2
		exit 1
	fi
	SUDO=""
	[ "$(id -u)" -ne 0 ] && SUDO="sudo"
	if command -v apt-get >/dev/null; then
		$SUDO apt-get update -qq
		# shellcheck disable=SC2086
		$SUDO apt-get install -y --no-install-recommends $PKGS_DEB
	elif command -v dnf >/dev/null; then
		# shellcheck disable=SC2086
		$SUDO dnf install -y $PKGS_RPM
	elif command -v pacman >/dev/null; then
		# shellcheck disable=SC2086
		$SUDO pacman -S --needed --noconfirm $PKGS_ARCH
	else
		echo "unknown package manager; install: $PKGS_DEB" >&2
		exit 1
	fi
fi

echo "== building"
make -j"$(nproc)"
echo
echo "built: $here/xfbridge"
./xfbridge --help 2>&1 | head -3
