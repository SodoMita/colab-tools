#!/usr/bin/env python3
"""Pass 2: exact keep-set math for selective UE5 extraction."""
import re
from collections import defaultdict

L = "/home/user/ue5_zip_list.txt"
GiB = 1073741824.0
MiB = 1048576.0

files = []
for line in open(L, encoding="utf-8", errors="replace"):
    m = re.match(r"^\s*(\d+)\s+\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}\s+(.*?)\s*$", line)
    if m:
        files.append((int(m.group(1)), m.group(2)))
def g(x): return f"{x/GiB:8.3f} GiB"
DBG = re.compile(r"\.(debug|sym|pdb)$", re.I)
def is_dbg(n): return bool(DBG.search(n))

# (a) debug sidecars by area
area = defaultdict(lambda: [0, 0])
for s, n in files:
    if is_dbg(n):
        if n.startswith("Engine/Binaries/Linux/"): k = "Binaries/Linux"
        elif n.startswith("Engine/Binaries/"): k = "Binaries/*"
        elif n.startswith("Engine/Plugins/"): k = "Plugins"
        else: k = "other"
        area[k][0] += s; area[k][1] += 1
print("=== [a] .debug/.sym/.pdb by area ===")
for k, (s, c) in sorted(area.items(), key=lambda kv: -kv[1][0]):
    print(f"{g(s)} {c:6d}  {k}")

# (d) DebugGame/-Debug standalone binaries
print("\n=== [d] '-DebugGame'/'-Debug' binaries (droppable builds) ===")
tot = 0
for s, n in sorted(files, reverse=True):
    if re.search(r"(DebugGame|(Windows|Linux)-Debug)$|-Debug\.so$", n) and not is_dbg(n):
        tot += s
        if s > 50*MiB: print(f"{g(s)}  {n}")
print(f"TOTAL: {g(tot)}")

# (e) mystery /Binaries/Linux/ outside Engine/Binaries/Linux and plugins
print("\n=== [e] '/Binaries/Linux/' outside Engine/Binaries/Linux & Engine/Plugins ===")
pref = defaultdict(int)
for s, n in files:
    if "/Binaries/Linux/" in n and not n.startswith("Engine/Binaries/Linux/") and not n.startswith("Engine/Plugins/"):
        parts = n.split("/")
        pref["/".join(parts[:3])] += s
for k, s in sorted(pref.items(), key=lambda kv: -kv[1])[:8]:
    print(f"{g(s)}  {k}")

# (b,c) per-plugin depth-3 breakdown
plug = defaultdict(lambda: defaultdict(int))
for s, n in files:
    if n.startswith("Engine/Plugins/"):
        p = n.split("/")
        if len(p) >= 4:
            name = p[2] + "/" + p[3]
            sub = p[4] if len(p) > 4 else "_file"
            plug[name][sub] += s
rows = []
for k, v in plug.items():
    total = sum(v.values())
    src = v.get("Source", 0)
    inter = v.get("Intermediate", 0)
    cont = v.get("Content", 0)
    bins = v.get("Binaries", 0)
    dbg = sum(s for s, n in files if n.startswith(f"Engine/Plugins/{k}/") and is_dbg(n))
    keep = total - src - inter - dbg
    rows.append((total, keep, src, inter, cont, bins, dbg, k))
rows.sort(reverse=True)
print("\n=== [b] per-plugin: total / keep(no Src,Interm,.debug) / src / inter / content / bin / dbg (top 30) ===")
for total, keep, src, inter, cont, bins, dbg, k in rows[:30]:
    print(f"{g(total)} keep={keep/GiB:6.3f} src={src/MiB:7.0f}M int={inter/MiB:6.0f}M cont={cont/MiB:7.0f}M bin={bins/MiB:6.0f}M dbg={dbg/MiB:6.0f}M  {k}")
print(f"\nplugin count: {len(rows)}")

st = {k: sum(v.get(k, 0) for v in plug.values()) for k in ("Source","Intermediate","Content","Binaries","Config","Resources","Shaders","ThirdParty")}
pl_total = sum(sum(v.values()) for v in plug.values())
pl_dbg = sum(s for s, n in files if n.startswith("Engine/Plugins/") and is_dbg(n))
print("\n=== [c] plugins totals ===")
for k, s in sorted(st.items(), key=lambda kv: -kv[1]): print(f"{g(s)}  {k}")
print(f"{g(pl_total)}  TOTAL Engine/Plugins")
print(f"{g(pl_dbg)}  .debug/.sym sidecars in plugins")
print(f"plugins keep (total-src-inter-dbg) = {g(pl_total - st['Source'] - st['Intermediate'] - pl_dbg)}")

# (f) keep-set variants
def sum_prefix(prefix): return sum(s for s, n in files if n.startswith(prefix))
def sum_match(pred): return sum(s for s, n in files if pred(n))

bin_linux = sum_prefix("Engine/Binaries/Linux/")
bin_linux_dbg = sum(s for s, n in files if n.startswith("Engine/Binaries/Linux/") and is_dbg(n))
bin_linux_dbg_builds = sum(s for s, n in files if n.startswith("Engine/Binaries/Linux/") and re.search(r"DebugGame|Linux-Debug$", n) and not is_dbg(n))
core = (sum_prefix("Engine/Content/") + sum_prefix("Engine/Shaders/") + sum_prefix("Engine/Config/")
        + sum_prefix("Engine/Build/") + sum_prefix("Engine/Programs/"))
tp = sum_prefix("Engine/Binaries/ThirdParty/")
dotnet = sum_prefix("Engine/Binaries/DotNET/")
src = sum_prefix("Engine/Source/")
ddc = sum_prefix("Engine/DerivedDataCache/")
extras_sdk = sum_match(lambda n: n.startswith("Engine/Extras/ThirdPartyNotUE/SDKs/"))
templates = sum_prefix("Templates/")
misc_top = sum_match(lambda n: "/" not in n) + sum_prefix("FeaturePacks/")
plugins_keep = pl_total - st['Source'] - st['Intermediate'] - pl_dbg

print("\n=== [f] keep-set variants ===")
print(f"Binaries/Linux total            {g(bin_linux)}")
print(f"  minus .debug/.sym             {g(bin_linux - bin_linux_dbg)}")
print(f"  minus also DebugGame builds   {g(bin_linux - bin_linux_dbg - bin_linux_dbg_builds)}")
print(f"core (Content+Shaders+Cfg+Bld+Prog) {g(core)}")
print(f"ThirdParty (runtime libs)       {g(tp)}")
print(f"DotNET                          {g(dotnet)}")
print(f"plugins keep                    {g(plugins_keep)}")
print(f"templates                       {g(templates)}")
print(f"top-level misc                  {g(misc_top)}")
base = (bin_linux - bin_linux_dbg) + core + tp + dotnet + plugins_keep + templates + misc_top
print(f"BASE keep                       {g(base)}")
print(f"  + Engine/Source               {g(base + src)}")
print(f"  + Source + SDKs(Extras)       {g(base + src + extras_sdk)}")
print(f"  + DDC Compressed.ddp          {g(base + src + extras_sdk + ddc)}")
print(f"free now 26.28 GiB; zip=37.09 GiB")
