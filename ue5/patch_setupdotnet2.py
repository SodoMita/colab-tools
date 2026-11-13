#!/usr/bin/env python3
"""Patch 2: make SetupDotnet.sh accept the system dotnet regardless of version-string parsing."""
p = "/home/colab/UE5/Engine/Build/BatchFiles/Linux/SetupDotnet.sh"
s = open(p).read()

start_marker = 'if [ "$UE_USE_SYSTEM_DOTNET" == "1" ]'
end_marker = "# Setup bundled Dotnet if cannot use installed one"
i = s.find(start_marker)
j = s.find(end_marker)
if i == -1 or j == -1 or j < i:
    raise SystemExit(f"markers not found (i={i}, j={j}) — aborting")

new_block = (
    'if [ "$UE_USE_SYSTEM_DOTNET" == "1" ] && [ -x "$DOTNET_VERSION_PATH" ]; then\n'
    '\t# local patch (2026-10-14): accept any present dotnet; the stock version check\n'
    '\t# breaks on SDK strings like "10.0.112" (bash integer comparison).\n'
    '\tIS_DOTNET_INSTALLED=1\n'
    'fi\n\n'
)

s = s[:i] + new_block + s[j:]
open(p, "w").write(s)
print("patch 2 applied")
