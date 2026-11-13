#!/bin/bash
# 05-system-config.sh - see and undo everything this toolkit changed in system paths.
#
#   scripts/05-system-config.sh list        # every file we touched + its backup
#   scripts/05-system-config.sh diff        # how our files differ from the backups
#   scripts/05-system-config.sh backup      # snapshot the X11 config *now* (before you experiment)
#   scripts/05-system-config.sh restore     # undo our changes (restore backups / delete what we created)
#   sudo scripts/05-system-config.sh restore
#
# Design rule this exists to enforce: the toolkit never writes into /etc/X11 by
# default, and when it does (INSTALL_GLOBAL_CONF=1, Vulkan ICD, modprobe) it
# first copies the old file aside and records the change in a manifest.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-nvidia.sh
. "$here/lib-nvidia.sh"

STATE=$(nv_state_dir)
MAN=$(NV_MANIFEST)
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

case "${1:-list}" in
list)
	echo "state dir : $STATE"
	echo "manifest  : $MAN"
	if [ -f "$MAN" ]; then
		echo "changes recorded by this toolkit:"
		manifest_list
		echo
		echo "current state of those files:"
		while IFS=$'\t' read -r p a b t; do
			[ -n "$p" ] || continue
			if [ -e "$p" ]; then
				printf '  present : %s\n' "$p"
			else
				printf '  absent  : %s  (was %s on %s)\n' "$p" "$a" "$t"
			fi
		done < "$MAN"
	else
		echo "  no changes recorded - this toolkit has not modified any system file."
	fi
	echo
	echo "files a normal X11/Wayland session depends on (for reference):"
	for f in /etc/X11/xorg.conf /etc/X11/xorg.conf.d/*.conf \
	         /etc/X11/Xwrapper.config /etc/modprobe.d/*nvidia*.conf; do
		[ -e "$f" ] && printf '  %s\n' "$f"
	done
	;;

diff)
	[ -f "$MAN" ] || { echo "nothing recorded"; exit 0; }
	while IFS=$'\t' read -r p a b t; do
		[ -n "$p" ] || continue
		case "$a" in
			modified)
				[ -f "$b" ] || { echo "== $p (backup missing: $b)"; continue; }
				echo "== $p  vs  $b"
				diff -u "$b" "$p" | head -40 ;;
			created)
				echo "== $p  (created by this toolkit, $t)"
				[ -e "$p" ] && sed 's/^/  | /' "$p" | head -20 ;;
		esac
	done < "$MAN"
	;;

backup)
	out="$STATE/snapshots/$(date +%Y%m%d-%H%M%S)"
	echo "snapshotting X11 configuration to $out"
	system_config_backup "$out"
	echo
	echo "restore one file with:   sudo cp -a $out/<name> /etc/X11/<name>"
	echo "restore everything with: sudo cp -a $out/. /etc/X11/  (check names first)"
	;;

restore)
	echo "restoring from the manifest (newest change first)"
	if [ ! -f "$MAN" ]; then
		echo "  nothing to restore: no manifest ($MAN)"
		exit 0
	fi
	n_root=0
	while IFS=$'\t' read -r p a b t; do
		case "$p" in /etc/*|/usr/*) n_root=$((n_root + 1)) ;; esac
	done < "$MAN"
	if [ "$n_root" -gt 0 ] && [ "$(id -u)" -ne 0 ]; then
		echo "  system paths are involved - re-run with sudo:" 
		echo "     sudo $0 restore"
		exit 1
	fi
	manifest_restore
	echo
	echo "note: this restores files, it does not restart any service."
	echo "      after restoring, log out/in (or reboot) for X/Wayland changes to take effect."
	;;

*)
	echo "usage: $0 {list|diff|backup|restore}"; exit 1 ;;
esac
