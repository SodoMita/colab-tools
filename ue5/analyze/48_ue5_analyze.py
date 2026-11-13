#!/usr/bin/env python3
"""UE5 zip listing analyzer -> decides a selective-extract keep-set.
Input: /home/user/ue5_zip_list.txt (unzip -l of Linux_Unreal_Engine_5.8.3.zip)
"""
import re, sys
from collections import defaultdict

L = "/home/user/ue5_zip_list.txt"
GiB = 1073741824.0
MiB = 1048576.0

entries = []  # (size, name)  name has trailing / for dirs
for line in open(L, encoding="utf-8", errors="replace"):
    m = re.match(r"^\s*(\d+)\s+\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}\s+(.*?)\s*$", line)
    if m:
        entries.append((int(m.group(1)), m.group(2)))

files = [(s, n) for s, n in entries if not n.endswith("/")]
print(f"entries={len(entries)} files={len(files)}  total={sum(s for s,_ in files)/GiB:.2f} GiB\n")

def g(x): return f"{x/GiB:7.3f} GiB"

# ---------- 1. debug/sym/pdb ----------
tot = cnt = 0
for s, n in files:
    if re.search(r"\.(debug|sym|pdb)$", n, re.I):
        tot += s; cnt += 1
print(f"[1] .debug/.sym/.pdb: {g(tot)} in {cnt} files")

# ---------- helper: aggregate by path prefix ----------
def buckets(prefix, depth, filt=lambda n: True):
    agg = defaultdict(lambda: [0, 0])
    plen = len(prefix)
    for s, n in files:
        if n.startswith(prefix) and filt(n):
            rest = n[plen:]
            parts = rest.split("/")
            key = "/".join(parts[:depth]) if depth else parts[0]
            agg[key][0] += s; agg[key][1] += 1
    return sorted(((v[0], v[1], k) for k, v in agg.items()), reverse=True)

def show(title, rows, limit=25):
    print(f"\n=== {title} ===")
    for s, c, k in rows[:limit]:
        print(f"{g(s)} {c:7d}  {k}")

show("[2] Engine/Binaries/* (2nd level)",
     buckets("Engine/Binaries/", 1), 15)
show("[3] Engine/Binaries/ThirdParty/*",
     buckets("Engine/Binaries/ThirdParty/", 1), 10)

# ---------- 4. platform-binaries sums ----------
print("\n=== [4] platform binary dirs ===")
PLAT = ["Linux", "LinuxArm64", "Android", "Win64", "Windows", "Mac", "IOS", "TVOS", "Unix"]
for p in PLAT:
    pat = f"/Binaries/{p}/"
    s = sum(sz for sz, n in files if pat in n)
    c = sum(1 for sz, n in files if pat in n)
    if s: print(f"{p:12s} {g(s)} {c:7d} files")

# ---------- 5. Engine/Binaries/Linux detail ----------
rows = []
for s, n in files:
    if n.startswith("Engine/Binaries/Linux/"):
        rest = n[len("Engine/Binaries/Linux/"):]
        parts = rest.split("/")
        key = parts[0] if len(parts) == 1 else parts[0] + "/"
        rows.append((s, key, n))
agg = defaultdict(lambda: [0, 0])
for s, k, n in rows:
    agg[k][0] += s; agg[k][1] += 1
print("\n=== [5] Engine/Binaries/Linux/* (top-level files & dirs) ===")
for k, (s, c) in sorted(agg.items(), key=lambda kv: -kv[1][0])[:40]:
    print(f"{g(s)} {c:6d}  {k}")

# ---------- 6. Engine/Plugins per-plugin w/ sub-buckets ----------
plug = defaultdict(lambda: defaultdict(int))
for s, n in files:
    p = n.split("/")
    if len(p) > 3 and p[0] == "Engine" and p[1] == "Plugins":
        name = p[2]
        sub = p[3] if len(p) > 3 else ""
        if len(p) > 4:
            sub = p[3]  # top subdir
        plug[name][sub] += s
print("\n=== [6] Engine/Plugins/<name> totals (top 40) ===")
tot_per = {k: sum(v.values()) for k, v in plug.items()}
for k, v in sorted(tot_per.items(), key=lambda kv: -kv[1])[:40]:
    b = plug[k]
    lin = b.get("Binaries", 0)
    print(f"{g(v)} {k:46s} Content={b.get('Content',0)/MiB:8.0f}M Bin={lin/MiB:7.0f}M Interm={b.get('Intermediate',0)/MiB:7.0f}M Src={b.get('Source',0)/MiB:7.0f}M")

# per-plugin Binaries/<platform> vs Content sums
print("\n=== [7] Engine/Plugins: which sub-trees cost what (whole tree) ===")
sub_agg = defaultdict(int)
for k, v in plug.items():
    for sub, s in v.items():
        sub_agg[sub] += s
for sub, s in sorted(sub_agg.items(), key=lambda kv: -kv[1])[:15]:
    print(f"{g(s)}  {sub}")

# plugin Binaries/Linux size
s_pl_linux = sum(s for s, n in files if re.match(r"^Engine/Plugins/[^/]+/Binaries/Linux/", n))
s_pl_bin_other = sum(s for s, n in files if re.match(r"^Engine/Plugins/[^/]+/Binaries/", n) and "/Binaries/Linux/" not in n)
print(f"\nplugins Binaries/Linux   = {g(s_pl_linux)}")
print(f"plugins Binaries(other)  = {g(s_pl_bin_other)}")

# ---------- 8. Engine/* top dirs recomputed w/ finer keys ----------
show("[8] Engine/Intermediate/*", buckets("Engine/Intermediate/", 1), 8)
show("[9] Engine/Source/* (2nd)", buckets("Engine/Source/", 1), 12)
show("[10] Engine/Content/* (2nd)", buckets("Engine/Content/", 1), 10)
show("[11] Engine/Extras/* (2nd)", buckets("Engine/Extras/", 1), 10)
show("[12] Engine/Platforms/*", buckets("Engine/Platforms/", 1), 20)

# ---------- 13. candidate keep-set math ----------
KEEP_EXACT = [
    "Engine/Binaries/Linux/",
    "Engine/Content/",
    "Engine/Shaders/",
    "Engine/Config/",
    "Engine/Build/",
    "Engine/Programs/",
]
keep = sum(s for s, n in files if any(n.startswith(p) for p in KEEP_EXACT))
keep_linux_detail = sum(s for s, n in files if n.startswith("Engine/Binaries/Linux/"))
print(f"\n=== [13] candidate keep math ===")
print(f"Engine/Binaries/Linux            {g(keep_linux_detail)}")
print(f"+ Content/Shaders/Config/Build/Programs => {g(keep)}")
print(f"+ ALL plugins Binaries/Linux      => {g(keep + s_pl_linux)}")
print(f"+ plugins Content                 => {g(keep + s_pl_linux + sum(s for s,n in files if re.match(r'^Engine/Plugins/[^/]+/Content/', n)))}")
print(f"+ plugins Source                  => {g(keep + s_pl_linux + sum(s for s,n in files if re.match(r'^Engine/Plugins/[^/]+/Content/', n)) + sum(s for s,n in files if re.match(r'^Engine/Plugins/[^/]+/Source/', n)))}")
print(f"Engine/Source (all)              {g(sum(s for s,n in files if n.startswith('Engine/Source/')))}")
print(f"Engine/DerivedDataCache          {g(sum(s for s,n in files if n.startswith('Engine/DerivedDataCache/')))}")
print(f"Engine/Extras (all)              {g(sum(s for s,n in files if n.startswith('Engine/Extras/')))}")
print(f"Templates (all)                  {g(sum(s for s,n in files if n.startswith('Templates/')))}")

# top-30 biggest files overall (sanity)
print("\n=== [14] largest 30 files ===")
for s, n in sorted(files, reverse=True)[:30]:
    print(f"{g(s)}  {n}")
