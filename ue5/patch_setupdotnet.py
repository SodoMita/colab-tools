#!/usr/bin/env python3
"""Patch UE5 SetupDotnet.sh to prefer the system dotnet (bundled 10.0.7 coreclr segfaults here)."""
import os, shutil, time

p = "/home/colab/UE5/Engine/Build/BatchFiles/Linux/SetupDotnet.sh"
bak = f"{p}.orig-{int(time.time())}"

if not os.path.exists(p):
    raise SystemExit("SetupDotnet.sh not found")

shutil.copy2(p, bak)
print("backup:", bak)

os.chmod(p, 0o755)
s = open(p).read()

if "local patch (2026-10-14)" in s:
    print("already patched")
    raise SystemExit(0)

marker = "export DOTNET_ROLL_FORWARD=Major\n"
ins = marker + (
    "\n"
    "# --- local patch (2026-10-14): prefer the system dotnet install.\n"
    "# The bundled dotnet 10.0.7 (rockylinux8 build) segfaults inside coreclr_initialize\n"
    "# in this container; the Microsoft Ubuntu build (10.0.12, /usr/bin/dotnet) works.\n"
    "if [ -z \"$UE_USE_SYSTEM_DOTNET\" ] && [ -x /usr/bin/dotnet ]; then\n"
    "\texport UE_USE_SYSTEM_DOTNET=1\n"
    "fi\n"
)
if marker not in s:
    raise SystemExit("marker not found — script layout changed, aborting")
s = s.replace(marker, ins, 1)
open(p, "w").write(s)
print("patched OK")
