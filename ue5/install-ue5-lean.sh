#!/bin/bash
# install-ue5-lean.sh — extract UE 5.8.3 for C++ work on the fresh box (as colab)
# Lean keep-set (~25.5 GiB) chosen from the archive manifest, so zip(37 GiB)+extract fits in ~69 GiB.
# Log: /tmp/ue5_install2.log   Marker: INSTALL2_DONE
set -u
Z=${1:-/home/colab/Downloads/Linux_Unreal_Engine_5.8.3.zip}
OUT=/home/colab/UE5
LOG=/tmp/ue5_install2.log

log() { echo "$*" >> "$LOG"; }
freek() { df -k --output=avail / | tail -1 | tr -d ' '; }

[ -f "$Z" ] || { log "FATAL: no zip at $Z"; echo "FATAL no zip"; exit 1; }
sz=$(stat -c %s "$Z")
log "=== install2 start $(date -Is) zip=$((sz/1048576)) MiB free=$(( $(freek)/1048576 ))GiB"
[ "$sz" -lt 20000000000 ] && { log "FATAL: zip too small ($sz) - incomplete download?"; echo "FATAL small zip"; exit 2; }
mkdir -p "$OUT" || exit 1
cd "$OUT" || exit 1

ex() { # ex <label> <min_free_GiB> <unzip args...>
  local label=$1 need=$2; shift 2
  local f; f=$(freek)
  if [ "$f" -lt $((need*1048576)) ]; then log "[$label] ABORT: free $((f/1048576))GiB < ${need}GiB"; echo "ABORT disk $label"; return 9; fi
  log "--- [$label] start $(date -Is) free=$((f/1048576))GiB"
  unzip -o -q "$Z" "$@" >>"$LOG" 2>&1; local rc=$?
  [ $rc -ge 20 ] && { log "[$label] HARD ERROR rc=$rc"; echo "ERR $label rc=$rc"; return $rc; }
  log "--- [$label] rc=$rc end $(date -Is) free=$(( $(freek)/1048576 ))GiB"
  return 0
}

NOJUNK=(-x '*.debug' '*.sym' '*.pdb' '*.dylib' '*/Mac/*' '*/Win64/*' '*/Android/*' '*/IOS/*' '*/TVOS/*' '*/WinArm64/*' '*/aarch64/*')

# 1) engine core: binaries, assets, shaders, build system, sources, rules DLLs
ex 1-engine-core 20 \
  'Engine/Binaries/Linux/*' 'Engine/Binaries/ThirdParty/*' 'Engine/Binaries/DotNET/*' \
  'Engine/Content/*' 'Engine/Shaders/*' 'Engine/Config/*' 'Engine/Build/*' 'Engine/Programs/*' \
  'Engine/Source/*' 'Engine/Intermediate/Build/BuildRules/*' \
  'Directory.Build.targets' 'Directory.Build.props' 'zen-manifest.json' 'FeaturePacks/*' \
  "${NOJUNK[@]}" || exit $?

# 2) bundled clang 20.1.8 toolchain (UBT's default Linux compiler)
ex 2-toolchain 3 'Engine/Extras/ThirdPartyNotUE/SDKs/HostLinux/*' || exit $?

# 3) project templates (C++ blank project comes from here)
ex 3-templates 1 'Templates/*' || exit $?

# 4) plugins: sources + Linux third-party only (no Content/Intermediate/Deploy)
ex 4-plugins 2 'Engine/Plugins/*' \
  -x '*/Content/*' '*/Intermediate/*' '*/Deploy/*' '*.lib' '*.dll' '*.pdb' '*.dylib' '*.debug' '*.sym' \
     '*/Mac/*' '*/Win64/*' '*/Android/*' '*/IOS/*' '*/TVOS/*' '*/WinArm64/*' '*/aarch64/*' '*/LinuxArm64/*' || exit $?

# 5) case-insensitive safety net for Build.cs / Target.cs (archive has lowercase variants)
unzip -o -q -C "$Z" '*.Build.cs' '*.Target.cs' >>"$LOG" 2>&1

{
  echo "=== summary $(date -Is)"
  echo "UE5: $(du -sh $OUT 2>/dev/null | cut -f1)  files: $(find $OUT -type f | wc -l)"
  echo "editor: $(ls -l $OUT/Engine/Binaries/Linux/UnrealEditor 2>/dev/null | awk '{print $5}') bytes"
  echo "clang:  $(ls -d $OUT/Engine/Extras/ThirdPartyNotUE/SDKs/HostLinux/Linux_x64/* 2>/dev/null)"
  echo "rules:  $(ls $OUT/Engine/Intermediate/Build/BuildRules/*.dll 2>/dev/null | tr '\n' ' ')"
  echo "bcs:    $(find $OUT/Engine -name '*.Build.cs' | wc -l) Build.cs"
  echo "tpl:    $(ls -d $OUT/Templates/TP_* 2>/dev/null | wc -l) templates"
  df -h / | tail -1
} >> "$LOG" 2>&1
echo "INSTALL2_DONE" >> "$LOG"
echo "INSTALL2_DONE"; tail -14 "$LOG"
