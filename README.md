# colab-tools

Provisioning scripts, remote-desktop fixes, Unreal Engine 5.8 Linux tooling, and an X11-to-Wayland GPU bridge built for headless NVIDIA CUDA/Colab containers (Ubuntu 24.04, compute-only NVIDIA userspace, no `systemd` as PID 1, no `/dev/dri`, no `/dev/snd`) as well as legacy NVIDIA Linux desktops.

## Safety & Configuration Principles

- **Never clobber existing configuration:** scripts that touch X11, PulseAudio, ALSA, or RustDesk configs either write isolated files (e.g. `/etc/pulse/system-colab.pa`, `/etc/X11/xorg-gpu.conf`) or create timestamped `.bak-*` backups first.
- **No hardcoded credentials:** passwords and tunnel ports are read from environment variables (`RD_PASSWORD`, `VNC_PASSWORD`, `SSH_PASSWORD`, `BORE_PORT`, `BORE_HOST`).

---

## Repository Layout

| Directory | What it solves |
|---|---|
| [`gpu-desktop/`](gpu-desktop/) | Turns a compute-only NVIDIA container (`/usr/lib64-nvidia`, no `nvidia_drv.so` link, no `/dev/dri`) into a hardware-accelerated headless `Xorg :20` + XFCE desktop with OpenGL 4.6 & Vulkan 1.4 direct rendering, plus a 30 s keepalive supervisor and optional `xrdp` recipes. |
| [`rustdesk-audio/`](rustdesk-audio/) | Working system audio over **RustDesk 1.5.x** on headless containers without `systemd-logind` or `/dev/snd`. Includes system-wide anonymous PulseAudio (`DummyOutput`) and non-root peer launcher (`peer-as-colab.sh`) so RustDesk spawns `rustdesk --cm` (`_pa` capture IPC) without `loginctl`. |
| [`ue5/`](ue5/) | **Unreal Engine 5.8.x** selective archive extractors (C++-full, C++-lean, and Blueprint-only budgets), C++ UBT fixes (`dotnet` shim for Ubuntu 24.04 containers, `-NoUBA`, prebuilt UHT headers + shader DDC + clang 20.1.8), and direct Vulkan `:20` launcher (`Run_UE5.sh`). |
| [`browsers/`](browsers/) | Idempotent **Waterfox** APT installer (verified GPG fingerprint) + non-intrusive `Xvfb :77` smoke test (`wf-verify.sh`) that never disturbs a live `:20` session. |
| [`ssh-helpers/`](ssh-helpers/) | Small `paramiko` SSH/SFTP/root-exec helpers (`remote.py`, `rootrun.py`, `upload.py`, `fetch.py`) for boxes exposed behind `bore.pub` or another TCP tunnel. |
| [`wayland-xorg-bridge/`](wayland-xorg-bridge/) | **`xfbridge` (C)**: mirrors a headless GPU `Xorg` screen into a native Wayland `xdg_toplevel` surface via `XDamage` + `MIT-SHM` + `XFixes` cursor blending + `XTEST` input, designed for Kepler/legacy NVIDIA drivers (`470.xx`) where GBM Xwayland is unavailable. Enforces dedicated VT isolation (refuses `-sharevts`) and private `-config` / `-configdir` isolation with full backup/restore (`05-system-config.sh`). |
| [`docs/`](docs/) | [`xvfb-xwayland-nvidia-hwaccel.md`](docs/xvfb-xwayland-nvidia-hwaccel.md) — field guide to hardware acceleration across `Xvfb`, VirtualGL EGL, headless `Xorg`, `Xwayland`, and legacy NVIDIA drivers (390–470+). |

---

## Quickstart: Fresh Headless CUDA Container (GPU Desktop + RustDesk + Audio + UE5)

```bash
# 1. As root: wire /usr/lib64-nvidia BEFORE starting Xorg, install NVIDIA DDX + XFCE + RustDesk + dotnet 10
bash gpu-desktop/prov_all.sh          # or gpu-desktop/prov_rd.sh if you do not want ML-image disk reclamation

# 2. As root: start system-wide PulseAudio with DummyOutput null sink + ALSA pulse bridge
bash rustdesk-audio/audio-setup.sh

# 3. As colab: start headless NVIDIA Xorg :20 + persistent XFCE session
su - colab -c "bash $(pwd)/gpu-desktop/gpu-desktop.sh start"

# 4. As root: start RustDesk peer as `colab` (NOT root — required for Linux audio without systemd-logind)
RD_PASSWORD='YourStrongPasswordHere' bash rustdesk-audio/peer-as-colab.sh

# 5. Optional: install Waterfox and/or supervise everything every 30 s
bash browsers/install-waterfox.sh
setsid nohup bash gpu-desktop/gpu-desktop-keepalive.sh </dev/null >/dev/null 2>&1 &

# 6. Optional (as colab): extract & wire Unreal Engine 5.8.x for C++ + Vulkan on :20
su - colab -c "bash $(pwd)/ue5/install-ue5-full.sh /home/colab/Downloads/Linux_Unreal_Engine_5.8.3.zip"
```

---

## Key Root Causes Documented Here

1. **Why RustDesk Linux audio was completely silent in containers (`rustdesk-audio/README.md`):**
   - On Linux, `rustdesk --server` does **not** record PulseAudio directly. `audio_service::run` connects to an IPC socket named `_pa` (`ipc::connect(1000, "_pa")`), which is only hosted by the connection-manager process (`rustdesk --cm` → `ipc::start_pa()`).
   - When the peer runs as **root**, `start_ipc` (`src/server/connection.rs`) spawns `--cm` via `platform::run_as_user()`, which shells out to `loginctl` (`libs/base/src/platform/linux.rs`). Without `systemd` as PID 1, `loginctl` fails (`"No valid uid"`), `--cm` never starts, `ipc_pa` never exists, and audio fails with zero log errors.
   - Running the peer as the non-root desktop user (`colab`, via `peer-as-colab.sh`) makes `start_ipc` call `run_me(["--cm"])` directly — bringing up `ipc_cm` and `ipc_pa` and capturing `DummyOutput.monitor`.
   - Also note: in RustDesk 1.5.0, **"Enable audio"** is a peer permission checkbox under *Settings → Security → Permissions*, **not** a button in the remote session toolbar.
2. **Why NVIDIA Vulkan/GLX failed if `Xorg` started before `ldconfig` (`gpu-desktop/prov_all.sh`):**
   - Compute containers mount driver libraries in `/usr/lib64-nvidia` without `/etc/ld.so.conf.d/10-nvidia.conf`, `libglxserver_nvidia.so` symlink, or GLVND/Vulkan ICD JSONs. Wiring those **before** starting `Xorg :20` gives direct hardware OpenGL 4.6 and Vulkan 1.4 on the Tesla T4 without `/dev/dri`.
3. **Why UE 5.8 Linux C++ builds failed out-of-the-box in Ubuntu 24.04 containers (`ue5/README.md`):**
   - Unreal's bundled RockyLinux-built `dotnet` 10.0.7 segfaults inside `coreclr_initialize` in container environments, and Unreal Build Accelerator (`UBA`) hits container sandbox limits. Shimming `Engine/Binaries/ThirdParty/DotNet/10.0/linux-x64/dotnet` to Microsoft's Ubuntu `dotnet-sdk-10.0` (`/usr/bin/dotnet`) and passing `-NoUBA` in `Build.sh` makes C++ projects compile cleanly with bundled Clang 20.1.8.
4. **Why `Xorg -sharevts` hard-locks a Linux desktop (`wayland-xorg-bridge/README.md`):**
   - `-sharevts` skips `VT_PROCESS` and `xf86VTRequest`, trapping DRM master and input grabs permanently. `wayland-xorg-bridge/scripts/20-xorg-headless.sh` forbids `-sharevts`, assigns a dedicated free `vtN`, isolates `-config` and `-configdir` under `/tmp`, and provides `15-xvfb-soft.sh` (`Xvfb` + `vglrun -d egl0`) as a zero-VT alternative.
