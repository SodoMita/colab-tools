#!/bin/bash
# install-ue5.sh — UE5 5.8.3 selective extraction onto the fresh container (as colab)
# Rebuilt 2026-10-14 from the proven steps/49+51 pipeline. Log: /tmp/ue5_extract.log
set -u
Z=/home/colab/Downloads/Linux_Unreal_Engine_5.8.3.zip
OUT=/home/colab/UE5
LOG=/tmp/ue5_extract.log

[ -f "$Z" ] || { echo "FATAL: no zip at $Z" >> "$LOG"; exit 1; }
sz=$(stat -c %s "$Z")
echo "=== install-ue5 start $(date -Is) zip=${sz} bytes ($((sz/1048576)) MiB)" >> "$LOG"
if [ "$sz" -lt 10000000000 ]; then echo "FATAL: zip < 10G — download incomplete?" >> "$LOG"; exit 2; fi

mkdir -p "$OUT"; cd "$OUT" || exit 1

freek() { df -k --output=avail / | tail -1 | tr -d ' '; }
ex() {  # ex <label> <unzip args...>
  local label="$1"; shift
  local f; f=$(freek)
  echo "--- [$label] start $(date -Is) free=$((f/1048576))GiB" >> "$LOG"
  if [ "$f" -lt 4194304 ]; then echo "[$label] ABORT: <4GiB free" >> "$LOG"; return 9; fi
  unzip -o -q "$Z" "$@" >>"$LOG" 2>&1
  local rc=$?
  echo "--- [$label] rc=$rc end $(date -Is) free=$(( $(freek)/1048576 ))GiB" >> "$LOG"
  return $rc
}

# NOTE: unzip rc=11 ("no matching files for some patterns") is EXPECTED here
# (e.g. plugins without a Content dir) — it must NOT stop the chain. Only
# rc>=20 (real errors) should.
rc=0
ex "1-engine-core" \
   'Engine/Binaries/Linux/*' 'Engine/Binaries/ThirdParty/*' 'Engine/Binaries/DotNET/*' \
   'Engine/Content/*' 'Engine/Shaders/*' 'Engine/Config/*' 'Engine/Build/*' 'Engine/Programs/*' \
   'Engine/Documentation/*' 'Engine/DerivedDataCache/*' 'Templates/*' \
   'Directory.Build.targets' 'Directory.Build.props' 'zen-manifest.json' 'FeaturePacks/*' \
   -x '*.debug' '*.sym' '*.pdb' 'Engine/Binaries/Linux/UnrealGame-Linux-DebugGame' || true

ex "2-plugins-no-content" 'Engine/Plugins/*' \
   -x '*/Content/*' '*/Source/*' '*/Intermediate/*' '*.debug' '*.sym' '*.pdb' || true

mapfile -t P1 < /tmp/ue5_patterns_enabled.txt
ex "3-enabled-content" "${P1[@]}" || true

mapfile -t P2 < /tmp/ue5_patterns_tpl_extra.txt
ex "4-template-extra-content" "${P2[@]}" || true

mapfile -t P3 < /tmp/ue5_patterns_closure_extra.txt
ex "5-closure-content" "${P3[@]}" || true

# completeness re-runs (expect ~0 delta)
for L in /tmp/ue5_patterns_enabled.txt /tmp/ue5_patterns_tpl_extra.txt /tmp/ue5_patterns_closure_extra.txt; do
  mapfile -t A < "$L"
  b=$(du -sb "$OUT" 2>/dev/null | cut -f1)
  unzip -o -q "$Z" "${A[@]}" 2>/dev/null; r=$?
  a=$(du -sb "$OUT" 2>/dev/null | cut -f1)
  echo "--- re-run [$(basename $L)] rc=$r delta=$((a-b)) bytes" >> "$LOG"
done

# launcher on the desktop
if [ -f /home/colab/Run_UE5.sh ]; then
  install -m 755 /home/colab/Run_UE5.sh /home/colab/Desktop/Run_UE5.sh && echo "--- launcher installed to Desktop" >> "$LOG"
fi

{
  echo "=== summary $(date -Is) final_rc=$rc"
  echo "UE5 total: $(du -sh $OUT 2>/dev/null | cut -f1)"
  echo "files: $(find $OUT -type f 2>/dev/null | wc -l)"
  echo "editor: $(ls -l $OUT/Engine/Binaries/Linux/UnrealEditor 2>/dev/null | awk '{print $5" bytes"}')"
  echo "debug sidecars: $(find $OUT \( -name '*.debug' -o -name '*.sym' \) 2>/dev/null | wc -l)"
  df -h / | tail -1
} >> "$LOG" 2>&1
echo "UE5_INSTALL_DONE rc=$rc" >> "$LOG"
exit $rc
