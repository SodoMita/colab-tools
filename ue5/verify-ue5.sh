#!/bin/bash
# verify-ue5.sh — audit the fresh UE5 install vs the known-good keep list + smoke test.
# Log: /tmp/ue5_verify.log   Run as colab.
set -u
OUT=/home/colab/UE5
LOG=/tmp/ue5_verify.log
: > "$LOG"

{
echo "=== UE5 verify $(date -Is)"
du -sh "$OUT" 2>/dev/null
echo "files: $(find $OUT -type f 2>/dev/null | wc -l)"
ls -l "$OUT/Engine/Binaries/Linux/UnrealEditor" 2>/dev/null
echo "debug sidecars (want 0): $(find $OUT \( -name '*.debug' -o -name '*.sym' \) 2>/dev/null | wc -l)"
} >> "$LOG" 2>&1

# ---- audit vs keep list -----------------------------------------------------
gunzip -c /home/colab/ue5_keep_list.txt.gz > /tmp/ue5_keep.txt
python3 - <<'PY' >> "$LOG" 2>&1
import os
root = "/home/colab/UE5"
missing, total = [], 0
with open("/tmp/ue5_keep.txt") as f:
    for line in f:
        p = line.rstrip("\n")
        if not p: continue
        total += 1
        if not os.path.exists(os.path.join(root, p)):
            missing.append(p)
print(f"=== keep-list audit: total={total} present={total-len(missing)} missing={len(missing)}")
for m in missing[:30]:
    print("MISSING:", m)
PY

# ---- ldd --------------------------------------------------------------------
echo "--- ldd missing libs (want 0):" >> "$LOG"
ldd "$OUT/Engine/Binaries/Linux/UnrealEditor" 2>&1 | grep -c "not found" >> "$LOG" 2>&1

# ---- smoke: boot the editor headless, expect 'Engine is initialized' --------
cd "$OUT/Engine/Binaries/Linux" 2>/dev/null
rm -f /tmp/ue5_smoke_new.log
timeout 150 ./UnrealEditor -nullrhi -nosplash -abslog=/tmp/ue5_smoke_new.log > /dev/null 2>&1
rc=$?
{
echo "--- smoke rc=$rc (124=timeout while running = OK if initialized)"
echo "init lines: $(grep -c 'Engine is initialized' /tmp/ue5_smoke_new.log 2>/dev/null)"
echo "fatal lines: $(grep -ci 'FatalError\|Fatal error' /tmp/ue5_smoke_new.log 2>/dev/null)"
} >> "$LOG" 2>&1
echo "=== verify done $(date -Is)" >> "$LOG"
