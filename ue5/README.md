# Unreal Engine 5.8.x on Headless Linux CUDA Containers

Scripts and patches for extracting, verifying, compiling **C++** projects, and running **Unreal Engine 5.8.x** (`Linux_Unreal_Engine_5.8.3.zip`) on disk-constrained Ubuntu 24.04 GPU containers.

## Choosing an Installer Script

| Script | Extracted Size | C++ Projects | Notes |
|---|---|---|---|
| **`install-ue5-full.sh`** *(recommended)* | ~42 GiB | **Yes (fast)** | Keeps `Engine/Source`, bundled Clang `20.1.8`, **prebuilt UHT headers** (`Engine/Intermediate/Build/Linux`), and **prebuilt shader DDC** (`Engine/DerivedDataCache/Compressed.ddp`), plus installs the `.NET` shim and `-NoUBA` automatically. |
| `install-ue5-lean.sh` | ~25.5 GiB | Yes (slower first build) | Fits tighter disks while the 38 GiB zip is still on disk; omits prebuilt UHT headers and DDC (regenerated on first launch/build). |
| `install-ue5.sh` + `finish-ue5-extract.sh` | ~19.5 GiB | Blueprint only | Minimal footprint; uses `patterns/` dependency-closure lists (`79,754` files) for all default-enabled & template-required plugin content. |

---

## Hard-Won Linux Container Fixes for UE 5.8 C++

1. **Bundled `.NET` 10.0.7 segfaults inside `coreclr_initialize`:**
   - Unreal ships a RockyLinux-8 build of `dotnet` at `Engine/Binaries/ThirdParty/DotNet/10.0/linux-x64/dotnet` that crashes in Ubuntu 24.04 containers.
   - **Fix:** Install Microsoft's `dotnet-sdk-10.0` (`/usr/bin/dotnet`, done in `gpu-desktop/prov_all.sh`) and either shim `Engine/Binaries/ThirdParty/DotNet/10.0/linux-x64/dotnet` (`install-ue5-full.sh` backs up `.bundled` and writes a 2-line `exec /usr/bin/dotnet "$@"` wrapper) or patch `SetupDotnet.sh` (`patch_setupdotnet.py` + `patch_setupdotnet2.py`, which also fixes bash integer parsing on SDK strings like `10.0.112`).
2. **Unreal Build Accelerator (`UBA`) container sandbox failures:**
   - **Fix:** Append `-NoUBA` to the `dotnet UnrealBuildTool.dll` invocation in `Engine/Build/BatchFiles/Linux/Build.sh` (automated in `install-ue5-full.sh`).
3. **Three archive directories that save hours if kept (`install-ue5-full.sh`):**
   - `Engine/Intermediate/Build/Linux/*` — prebuilt UnrealHeaderTool (`.generated.h`) headers for Engine and Plugins;
   - `Engine/DerivedDataCache/*` — `Compressed.ddp` prewarmed shader cache (~10,000 shaders otherwise compiled on first boot);
   - `Engine/Extras/ThirdPartyNotUE/SDKs/HostLinux/*` — bundled Clang `20.1.8` toolchain expected by UBT.
4. **Case-mixed `*.build.cs` files in the archive:**
   - Some plugins ship lowercase `.build.cs` filenames; `unzip -o -q -C "$Z" '*.Build.cs' '*.Target.cs'` ensures none are missed by case-sensitive globs.
5. **Direct Vulkan presentation on `:20` (`Run_UE5.sh`):**
   - Unreal Editor uses Vulkan on Linux (not GLX), so `vglrun` is unnecessary when `Xorg :20` runs on the NVIDIA driver with `/etc/vulkan/icd.d/nvidia_icd.json` and `/usr/lib64-nvidia` in `LD_LIBRARY_PATH`.
   - Never kill a running `UnrealEditor` or UBT build (`ConflictingInstance` means wait for the active UBT/Live Coding build to finish).

---

## Verification & Utilities

- `Run_UE5.sh` — Launches `UnrealEditor` on `DISPLAY=:20` with NVIDIA Vulkan ICD paths set.
- `verify-ue5.sh` — Checks `ldd` missing libraries (expects `0`), audits against `patterns/`, and runs a headless `-nullrhi` boot checking for `Engine is initialized` with `0` fatal errors.
- `watch-ue5zip.sh` — Watches `~/Downloads/Linux_Unreal_Engine_*.zip` until size stabilizes (>20 GiB and `unzip -l` passes) before starting extraction.
- `analyze/` — Python manifest analyzers (`48_ue5_analyze.py`, `48b_ue5_keepmath.py`, `48c_ue5_enabled.py`) that compute exact directory/plugin sizes and dependency closures from `unzip -l`.
