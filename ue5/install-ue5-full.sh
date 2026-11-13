#!/bin/bash
# install-ue5-full.sh — UE 5.8.x install that is correct the FIRST time (as colab).
# Includes the three things the earlier lean extract missed and that cost hours:
#   Engine/Intermediate/Build/Linux   -> prebuilt UHT headers for engine AND plugins
#   Engine/DerivedDataCache           -> prebuilt shader DDC (~10k shaders otherwise)
#   Engine/Extras/ThirdPartyNotUE     -> bundled clang 20.1.8
# Zip is ~38 GiB, extraction ~42 GiB. Needs ~50 GiB free AFTER the zip is present.
# Usage: bash install-ue5-full.sh /path/to/Linux_Unreal_Engine_X.Y.Z.zip
set -u
Z=${1:-}
OUT=/home/colab/UE5
LOG=/tmp/ue5_install_full.log
log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }
freek() { df -k --output=avail / | tail -1 | tr -d ' '; }

[ -n "$Z" ] && [ -f "$Z" ] || { echo "FATAL: no zip"; log "FATAL no zip arg='$Z'"; exit 1; }
sz=$(stat -c %s "$Z")
log "=== start zip=$Z size=$((sz/1048576))MiB free=$(( $(freek)/1048576 ))GiB"
[ "$sz" -lt 20000000000 ] && { log "FATAL zip too small"; echo "FATAL small"; exit 2; }
unzip -l "$Z" >/dev/null 2>&1 || { log "FATAL zip unreadable"; echo "FATAL corrupt"; exit 3; }
mkdir -p "$OUT" || exit 1
cd "$OUT" || exit 1

# junk we never need on this box
EXCL=(-x '*.pdb' '*.dylib' '*.dll' '*.lib' '*/Mac/*' '*/Win64/*' '*/WinArm64/*' '*/Android/*' '*/IOS/*' '*/TVOS/*' '*/aarch64/*' '*/LinuxArm64/*')
# debug sidecars: keep none (they only bulk up the install; UBT regenerates .sym as needed)
EXCL+=(-x '*.debug' '*.sym')

ex() { local label=$1 need=$2; shift 2
  local f; f=$(freek)
  if [ "$f" -lt $((need*1048576)) ]; then log "[$label] ABORT free=$((f/1048576))GiB < ${need}"; echo "ABORT $label"; return 9; fi
  log "--- [$label] start free=$((f/1048576))GiB"
  unzip -o -q "$Z" "$@" >>"$LOG" 2>&1; local rc=$?
  [ $rc -ge 20 ] && { log "[$label] HARD ERROR rc=$rc"; echo "ERR $label"; return $rc; }
  log "--- [$label] rc=$rc free=$(( $(freek)/1048576 ))GiB"
  return 0
}

# engine core + sources + shaders + prebuilt UHT headers + shader DDC
ex 1-engine 10 \
  'Engine/Binaries/Linux/*' 'Engine/Binaries/ThirdParty/*' 'Engine/Binaries/DotNET/*' \
  'Engine/Content/*' 'Engine/Shaders/*' 'Engine/Config/*' 'Engine/Build/*' 'Engine/Programs/*' \
  'Engine/Source/*' 'Engine/Intermediate/Build/BuildRules/*' 'Engine/Intermediate/Build/Linux/*' \
  'Engine/DerivedDataCache/*' \
  'Directory.Build.targets' 'Directory.Build.props' 'zen-manifest.json' 'FeaturePacks/*' \
  "${EXCL[@]}" -x 'Engine/Binaries/DotNET/AutomationTool/AutomationScripts/*' || exit $?
# AutomationScripts (2.2 GiB) only matter for UAT cook/package from the command line,
# not for editor or UBT builds - dropped to keep the disk budget safe.

# bundled clang toolchain
ex 2-toolchain 3 'Engine/Extras/ThirdPartyNotUE/SDKs/HostLinux/*' "${EXCL[@]}" || exit $?

# templates (C++ blank project etc.)
ex 3-templates 1 'Templates/*' "${EXCL[@]}" || exit $?

# plugins with prebuilt UHT headers (tmp copies excluded)
ex 4-plugins 4 'Engine/Plugins/*' "${EXCL[@]}" \
  -x '*/Content/*' '*/Intermediate/*/Inc/*/UHT/*.gen.cpp' || exit $?
# NOTE: plugin Content (~12.9 GiB) is skipped to fit the disk. Add it later with
# add-plugin-content.sh while the zip is still present if a project needs it.

# case-insensitive safety net for lowercase *.build.cs in this archive
unzip -o -q -C "$Z" '*.Build.cs' '*.Target.cs' >>"$LOG" 2>&1

# --- toolchain wiring: dotnet shim + -NoUBA exec line ---
D=$OUT/Engine/Binaries/ThirdParty/DotNet/10.0/linux-x64/dotnet
if [ -f "$D" ] && [ ! -f "$D.bundled" ]; then
  cp -a "$D" "$D.bundled"; chmod u+w "$D"
  printf '#!/bin/bash\nexec /usr/bin/dotnet "$@"\n' > "$D"; chmod 755 "$D"
  log "--- dotnet shim installed"
fi
B=$OUT/Engine/Build/BatchFiles/Linux/Build.sh
grep -q 'NoUBA' "$B" || sed -i '37s|"\$@"|"$@" -NoUBA|' "$B"
log "--- Build.sh exec line: $(sed -n '37p' "$B")"

{
  echo "=== summary $(date -Is)"
  echo "UE5: $(du -sh $OUT | cut -f1)  files: $(find $OUT -type f | wc -l)"
  echo "editor: $(stat -c %s $OUT/Engine/Binaries/Linux/UnrealEditor 2>/dev/null) bytes"
  echo "clang:  $(ls -d $OUT/Engine/Extras/ThirdPartyNotUE/SDKs/HostLinux/Linux_x64/* 2>/dev/null)"
  echo "ddc:    $(stat -c %s $OUT/Engine/DerivedDataCache/Compressed.ddp 2>/dev/null) bytes"
  echo "plugin UHT: $(find $OUT/Engine/Plugins -name '*.generated.h' 2>/dev/null | wc -l) headers"
  echo "zh: $(find $OUT/Engine/Plugins -name '*.zh' 2>/dev/null | wc -l)"
  echo "bcs:    $(find $OUT/Engine -name '*.Build.cs' | wc -l)"
  df -h / | tail -1
} >>"$LOG" 2>&1
log "INSTALL_FULL_DONE"
echo "INSTALL_FULL_DONE"
