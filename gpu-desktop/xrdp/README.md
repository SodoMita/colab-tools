# Headless NVIDIA GPU Desktop (`:20`) + xrdp Notes

*(Note: For lowest-latency desktop + working audio + Vulkan/UE5 on a single connection, prefer `prov_rd.sh` / `prov_all.sh` + `rustdesk-audio/peer-as-colab.sh`. The notes and scripts here document the `xrdp` setups tested earlier.)*

## Architecture Overview

On compute-only CUDA containers (Ubuntu 24.04, NVIDIA 580.x in `/usr/lib64-nvidia`, `nvidia_drm modeset=N`, no `/dev/dri`):

1. **Wayland compositors cannot use the GPU** because `nvidia_drm` has `modeset=N` and `/dev/dri/card0` does not exist.
2. **Headless `Xorg :20` with the NVIDIA DDX works directly** using `Option "AllowEmptyInitialConfiguration" "true"`, matching `xserver-xorg-video-nvidia-580` to `/proc/driver/nvidia/version`, and linking `libglxserver_nvidia.so`.
   - Verified `glxinfo -B`: `direct rendering: Yes`, `OpenGL renderer: Tesla T4/PCIe/SSE2`, `OpenGL 4.6.0 NVIDIA`, `glxgears` ~10,000–14,600 FPS.
   - Verified `vulkaninfo`: `DEVICE = Tesla T4`, Vulkan 1.4.

## Two `xrdp` Paths Compared

| Feature | GPU Desktop via `libvnc.so` (`gpu-desktop-provision.sh`) | Native `xrdp` via `xrdpdev` (`switch-sesman-xrdpdev.sh`) |
|---|---|---|
| X Server | `Xorg :20` (NVIDIA DDX) + `x11vnc` (`127.0.0.1:5910`) | `Xorg` + `xorgxrdp` (`xrdp/xorg.conf`) |
| OpenGL / Vulkan | **Hardware (Tesla T4)** | Software (`llvmpipe`), or GPU via `vglrun` |
| Video transport | Double-encoded (`Xorg` → `x11vnc` → `libvnc.so` → RDP) | Direct frame socket (`xrdp_display_*`), ~3.3 Mbit/s @ 1080p |
| RDP Audio | Not supported by `libvnc.so` | Working via `pulseaudio-module-xrdp` (`build-pa-module-xrdp.sh`) |

### Why Native `xrdp` Sessions Had Blank Video Originally

`sesman.ini` had `param=xrdp/xorg_nvidia.conf` under `[Xorg]`. `xorgxrdp` only creates its frame-transport socket (`xrdp_display_*` via `rdpClientConInit`) when the standard `xrdpdev` driver (`param=xrdp/xorg.conf`) is used — sessions started with `xorg_nvidia.conf` have no frame transport. `switch-sesman-xrdpdev.sh` backs up `/etc/xrdp/sesman.ini` and restores `param=xrdp/xorg.conf`.

### Client Connection Examples

```bash
# GPU-XFCE (libvnc bridge, fixed 1920x1080):
xfreerdp3 /v:<BORE_HOST>:<RDP_PORT> /u:na /p:<VNC_PASSWORD> /cert:ignore /size:1920x1080

# Native xrdp with PulseAudio redirection:
xfreerdp3 /v:<BORE_HOST>:<NATIVE_RDP_PORT> /u:colab /p:<SSH_PASSWORD> /cert:ignore /size:1920x1080 /sound:sys:pulse
```
