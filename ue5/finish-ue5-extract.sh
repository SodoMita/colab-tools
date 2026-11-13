#!/bin/bash
# finish-ue5-extract.sh — extract the content sets skipped by the rc=11 short-circuit
# (steps 3-recheck + 4 + 5), then re-audit. Runs as colab. Log: /tmp/ue5_finish.log
set -u
Z=/home/colab/Downloads/Linux_Unreal_Engine_5.8.3.zip
OUT=/home/colab/UE5
LOG=/tmp/ue5_finish.log
[ -f "$Z" ] || { echo "FATAL: no zip" > "$LOG"; exit 1; }
cd "$OUT" || exit 1
: > "$LOG"
echo "=== finish-extract start $(date -Is) free=$(df -h / | awk 'NR==2{print $4}')" >> "$LOG"

run() {  # run <label> <patterns...>
  local label="$1"; shift
  echo "--- [$label] start $(date -Is)" >> "$LOG"
  unzip -o -q "$Z" "$@" >>"$LOG" 2>&1
  local rc=$?
  echo "--- [$label] rc=$rc end $(date -Is) free=$(df -h / | awk 'NR==2{print $4}')" >> "$LOG"
  return 0   # rc=11 on unmatched patterns is expected/benign here
}

mapfile -t E < /tmp/ue5_patterns_enabled.txt;   run "3-enabled-content"   "${E[@]}"
mapfile -t T < /tmp/ue5_patterns_tpl_extra.txt; run "4-template-extra"    "${T[@]}"
mapfile -t C < /tmp/ue5_patterns_closure_extra.txt; run "5-closure-extra" "${C[@]}"

gunzip -c /home/colab/ue5_keep_list.txt.gz > /tmp/ue5_keep.txt
python3 - >> "$LOG" 2>&1 <<'PY'
import os
root="/home/colab/UE5"; missing=[]; total=0
for line in open("/tmp/ue5_keep.txt"):
    p=line.rstrip("\n")
    if not p: continue
    total+=1
    if not os.path.exists(os.path.join(root,p)): missing.append(p)
print(f"audit: total={total} missing={len(missing)}")
for m in missing[:25]: print("MISSING:", m)
PY
echo "UE5 total: $(du -sh $OUT | cut -f1)  files: $(find $OUT -type f | wc -l)" >> "$LOG"
echo "FINISH_DONE $(date -Is)" >> "$LOG"
