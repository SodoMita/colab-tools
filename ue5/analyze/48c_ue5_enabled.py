#!/usr/bin/env python3
"""Pass 3: sizes for enabled-by-default plugins only."""
import re
from collections import defaultdict

L = "/home/user/ue5_zip_list.txt"
EN = "/home/user/ue5_enabled_plugins.txt"
GiB = 1073741824.0
MiB = 1048576.0
DBG = re.compile(r"\.(debug|sym|pdb)$", re.I)

files = []
for line in open(L, encoding="utf-8", errors="replace"):
    m = re.match(r"^\s*(\d+)\s+\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}\s+(.*?)\s*$", line)
    if m:
        files.append((int(m.group(1)), m.group(2)))

# plugin roots from .uplugin paths
roots = []
for l in open(EN, encoding="utf-8"):
    l = l.strip()
    if not l:
        continue
    root = "Engine/Plugins/" + l.rsplit("/", 1)[0]
    roots.append(root)
print(f"enabled plugin roots: {len(roots)}")

def g(x): return f"{x/GiB:7.3f} GiB"

# aggregate by subtree
buckets = defaultdict(lambda: [0, 0, 0, 0])  # content, bins_clean, other, total(clean)
for s, n in files:
    for r in roots:
        if n.startswith(r + "/"):
            rest = n[len(r) + 1:]
            top = rest.split("/")[0]
            dbg = bool(DBG.search(n))
            if top == "Content":
                buckets[r][0] += s
            elif top == "Binaries":
                if not dbg:
                    buckets[r][1] += s
            elif top in ("Source", "Intermediate"):
                pass  # excluded
            else:
                if not dbg:
                    buckets[r][2] += s
            if not dbg and top not in ("Source", "Intermediate"):
                buckets[r][3] += s
            break

rows = sorted((v[3], k) for k, v in buckets.items())
content_tot = sum(v[0] for v in buckets.values())
bin_tot = sum(v[1] for v in buckets.values())
oth_tot = sum(v[2] for v in buckets.values())
keep_tot = sum(v[3] for v in buckets.values())
print(f"\nenabled plugins KEEP (content+bins+other, no src/inter/debug): {g(keep_tot)}")
print(f"  of which Content {g(content_tot)}, Binaries(clean) {g(bin_tot)}, other {g(oth_tot)}")
print("\n=== heaviest enabled plugins ===")
for s, k in sorted(rows, reverse=True)[:30]:
    v = buckets[k]
    print(f"{g(s)}  C={v[0]/MiB:7.0f}M B={v[1]/MiB:6.0f}M o={v[2]/MiB:5.0f}M  {k[len('Engine/Plugins/'):]}")

for probe in ("MetaHuman", "MetaHumanCharacter", "Niagara", "TextureSynthesis"):
    hits = [k for k in buckets if probe in k]
    if hits:
        for h in hits:
            print(f"[probe {probe}] {h}  keep={buckets[h][3]/MiB:.0f}M content={buckets[h][0]/MiB:.0f}M")

# MetaHuman optional TextureSynthesis archive size
ts = sum(s for s, n in files if "TextureSynthesis" in n)
print(f"\nTextureSynthesis optional payload total: {g(ts)}")

# Big-three: content of the TOP heaviest enabled plugins for exclusion decision
print("\n=== top-5 enabled by content ===")
for s, k in sorted(((v[0], k) for k, v in buckets.items()), reverse=True)[:5]:
    print(f"{g(s)}  {k}")
