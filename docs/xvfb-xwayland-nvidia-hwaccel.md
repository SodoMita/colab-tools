# Hardware-accelerated Xvfb and Xwayland on old NVIDIA proprietary drivers

*Field guide for headless / container / CI setups where the GPU is an NVIDIA card on a **legacy proprietary driver** (390 / 418 / 440 / 450 / 460 / 470 series) and you still need OpenGL, Vulkan or a 3D app without a physical monitor.*

---

## 0. TL;DR — pick your path

| What you want | Old driver reality | Recommended approach |
|---|---|---|
| 3D app on `Xvfb` | `Xvfb` is a **software framebuffer**; its GLX is `swrast`/`llvmpipe` only. Never hardware. | **VirtualGL with the EGL back end** (`vglrun -d egl0`) → no X server on the GPU needed |
| 3D app, X11, headless host | Better than Xvfb: a real X server on the GPU | **Headless Xorg + `nvidia` DDX** with `AllowEmptyInitialConfiguration` |
| Vulkan app on `Xvfb` | Vulkan device works, **presentation does not** (no DRI3 in Xvfb) | Render offscreen (`VK_EXT_headless_surface`), or use headless Xorg, or the app's own `-nullrhi`-style mode |
| X11 app under Wayland | Accelerated Xwayland requires **driver ≥ 470** and an **EGLStreams-capable compositor** | Mutter (GNOME ≤ 50) or KWin (Plasma 5.16–5.2x); see Part B |
| Wayland session itself | Compositor must speak **EGLStreams** (pre-495) | GNOME/Mutter, or KWin with `KWIN_DRM_USE_EGL_STREAMS=1` |
| X11 app **inside** a Wayland session, pre-495 driver | Accelerated Xwayland is impossible — don't fight it | **Part C**: run headless Xorg on the GPU and mirror its framebuffer into a Wayland surface (`wayland-xorg-bridge/`) |

### Driver-version thresholds that matter

| Driver | Wayland compositing | Xwayland acceleration | Notes |
|---|---|---|---|
| ≤ 460 | EGLStreams only | **None** | X11 only in practice |
| **470** | EGLStreams | **Yes** — DMA-BUF + `glamor` EGLStream backend (Xwayland ≥ 21.1.2) | Last legacy branch; the sweet spot for "old driver" |
| **495+** | GBM (and still EGLStreams) | Yes, **GBM** path (Xwayland ≥ 21.1.3) | `GBM_BACKEND=nvidia-drm` |
| 555+ / 565+ | GBM + explicit sync | Yes, stable | Modern setups; not the topic here |

Two hard "it's over" boundaries to keep in mind when reading old recipes:

* **Xwayland 24.1 (March 2024) removed the EGLStream back end.** On an EGLStreams-only driver (< 495) that means no accelerated Xwayland regardless of compositor. Pin an older Xwayland or accept software X11.
* **GNOME 51 dropped EGLStreams.** Mutter no longer offers the fallback for pre-495 drivers.

---

# Part A — Xvfb with hardware acceleration

## A.0 What Xvfb actually is (and is not)

`Xvfb` allocates a framebuffer in **main memory** and renders everything with the CPU. Consequences:

* `glxinfo` under plain `Xvfb` reports `llvmpipe` (Mesa's LLVM rasteriser). Enabling `+extension GLX` does **not** change that — it only exposes the software GLX provider.
* `Xvfb` has **no DRI3** and no GPU-backed presentation. Xorg 21.1 nominally shipped `glamor` support for Xvfb, but that work was reverted/partial in mainline; do not build a production workflow on it. (XLibre's 25.2 fork re-added "Xvfb: DRI3/glamor and GLX", which tells you it was missing.)
* Therefore "Xvfb with hardware acceleration" always means **decoupling rendering from display**: the app renders on the GPU and only the finished frames land in Xvfb's framebuffer. That is exactly what VirtualGL does.

```bash
# What you get with nothing else installed:
Xvfb :20 -screen 0 1920x1080x24 +extension GLX +render -noreset &
DISPLAY=:20 glxinfo -B | grep -i "renderer"     # → llvmpipe (software)
```

## A.1 Option 1 (recommended): VirtualGL EGL back end

VirtualGL intercepts GLX/EGL in the app (`LD_PRELOAD`), renders off-screen on the GPU, and ships pixels to the X server you actually display from. **The EGL back end needs no X server on the GPU at all** — it opens the DRM device / EGL device directly. This is the cleanest and fastest headless path.

### Install

```bash
# Debian/Ubuntu
sudo apt-get install -y virtualgl mesa-utils

# Verify what VirtualGL can see
/opt/VirtualGL/bin/eglinfo -e        # lists egl0, egl1, ... and which GPU is which
```

### Run

```bash
Xvfb :20 -screen 0 1920x1080x24 +extension GLX +render -noreset &
export DISPLAY=:20

# egl0 == first EGL device; or pass /dev/dri/cardN explicitly
vglrun -d egl0 glxinfo -B | grep -i renderer      # → NVIDIA ... (hardware)
vglrun -d egl0 ./my_app
```

Make it the default so you don't have to type `-d` everywhere:

```bash
export VGL_DISPLAY=egl0
vglrun ./my_app
```

For a whole desktop / multi-process tree (VNC containers, CI workers), use `vglrun +wm` (VirtualGL installs itself as the window manager and follows all child processes):

```bash
vglrun +wm -d egl0 startxfce4
```

### Health checks

```bash
# 1. GPU visible to EGL at all?
eglinfo -e | grep -iE "device|vendor"

# 2. Does the card node exist and is it openable?
ls -l /dev/dri/
# (containers: pass --device /dev/dri, --device /dev/nvidiactl, --device /dev/nvidia0)

# 3. Confirm the app really used the GPU, not llvmpipe
VGL_LOGO=1 vglrun -d egl0 glxspheres64      # red "VGL" watermark + FPS counter
```

### Notes and gotchas

* **Library path.** On containers where the userspace driver lives outside the standard path (e.g. `/usr/lib64-nvidia`), add it to the loader **before** starting anything:
  ```bash
  echo /usr/lib64-nvidia | sudo tee /etc/ld.so.conf.d/10-nvidia.conf && sudo ldconfig
  ```
  If you skip this you get exactly the class of failure that looks like "driver is broken": `libnvidia-tls.so.XXXX: cannot open shared object file` when a module tries to `dlopen` a client GL library.
* **Vulkan is not covered by VirtualGL's GLX interception.** Most Vulkan apps will still try to present to the X server. See A.3.
* The EGL back end does not support every legacy GLX feature (accumulation buffer, some stereo/overlay visuals). If an old app breaks, fall back to A.2.
* `-d /dev/dri/card0` and `-d egl0` are equivalent on a single-GPU box; on multi-GPU use `eglinfo -e` to map indices to cards.

## A.2 Option 2: VirtualGL GLX back end (needs a GPU-backed X server)

Use this when the EGL back end misbehaves with an old app. It needs a *second* X server that does have the GPU.

Terminal 1 — headless GPU X server (see A.4 for the config):

```bash
sudo Xorg :0 -config /etc/X11/xorg-gpu.conf -noreset -nolisten tcp
```

Terminal 2 — display Xvfb, render with the GPU:

```bash
Xvfb :20 -screen 0 1920x1080x24 &
DISPLAY=:20 VGL_DISPLAY=:0 vglrun ./my_app        # render on :0, display on :20
```

Make sure the user running the app can open `:0` (`xhost +si:localuser:$USER` or a shared `XAUTHORITY`).

## A.3 Vulkan on Xvfb — the trap

Vulkan does not go through GLX, so VirtualGL cannot help. The driver's ICD will enumerate the GPU fine, but as soon as the app creates an `Xlib`/`Xcb` surface on **Xvfb**, presentation fails. The distinguishing error is:

```
vkGetPhysicalDeviceSurfacePresentModesKHR failed with ERROR_UNKNOWN
VK_ERROR_INCOMPATIBLE_DRIVER / VK_ERROR_UNKNOWN on vkCreateSwapchainKHR
```

…even though `vulkaninfo --summary` happily prints `deviceName = ...`. Cause: no DRI3 / no GPU-backed presentation path in Xvfb. Three workable answers:

1. **Render offscreen.** `VK_EXT_headless_surface`, or the application's own offscreen mode (Unreal's `-nullrhi`, Blender's `-b`, `--headless` flags, etc.). Screenshots/PNG output instead of a window.
2. **Display on a real headless Xorg** (A.4) instead of Xvfb — then surfaces work, because that server *is* the GPU driver.
3. **Copy the frame out.** Render into an offscreen surface, then blit the result into an Xvfb window yourself (XShm/`xcb_put_image`). This is what a compositor-less streaming setup effectively does.

Sanity check which Vulkan path is live:

```bash
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json vulkaninfo --summary
# If the loader says "Failed loading library associated with ICD JSON", the
# ICD's library_path is wrong -> check ldd on that .so and ld.so.conf (see A.1).
```

## A.4 Better than Xvfb for GLX/Vulkan: headless Xorg on the T4-style setup

If the app must have a real X display *and* real GL, skip Xvfb. NVIDIA's DDX runs happily with no monitor attached.

`/etc/X11/xorg-gpu.conf`:

```
Section "ServerLayout"
    Identifier "Layout0"
    Screen 0 "Screen0"
EndSection

Section "ServerFlags"
    Option "AutoAddDevices"   "false"
    Option "AutoEnableDevices" "false"
EndSection

Section "Device"
    Identifier "T4"
    Driver     "nvidia"
    BusID      "PCI:0:4:0"                    # lspci | grep -i vga
    Option     "AllowEmptyInitialConfiguration" "true"
EndSection

Section "Monitor"
    Identifier  "Monitor0"
    HorizSync   1-1000
    VertRefresh 1-1000
EndSection

Section "Screen"
    Identifier  "Screen0"
    Device      "T4"
    Monitor     "Monitor0"
    DefaultDepth 24
    SubSection "Display"
        Depth   24
        Modes   "1920x1080" "1600x900" "1280x720"
        Virtual 1920 1080
    EndSubSection
EndSection
```

```bash
sudo Xorg :20 -config /etc/X11/xorg-gpu.conf \
  -modulepath /usr/lib/x86_64-linux-gnu/nvidia/xorg,/usr/lib/xorg/modules \
  -auth /home/user/.Xauthority -noreset -nolisten tcp
```

**Order matters.** Put `/usr/lib64-nvidia` (or wherever the driver's user-space libs live) into `ld.so.conf` and run `ldconfig` **before** starting X. If the NVIDIA **GLX server module** can't resolve its libraries, Xorg silently falls back to software GLX and you get a server that looks healthy but cannot present:

```
(EE) Failed to load .../libglxserver_nvidia.so: libnvidia-tls.so.580.82.07: cannot open shared object file
(EE) NVIDIA(0): Failed to initialize the GLX module
(II) GLX: Initialized DRISWRAST GL provider for screen 0     <-- software!
```

Verify:

```bash
glxinfo | grep -E "OpenGL renderer|OpenGL version"   # must say NVIDIA, not llvmpipe
vulkaninfo --summary | grep -E "deviceName|apiVersion"
timeout 10 vkcube --c 3                              # must present, not assert
```

## A.5 Xvfb flags worth knowing

```bash
Xvfb :20 \
  -screen 0 1920x1080x24 \      # geometry x depth; 24 required for most GL apps
  +extension GLX +extension RANDR +extension RENDER \
  -ac \                          # disable access control (trusted networks only!)
  -noreset \                     # do NOT reset when the last client exits
  -nolisten tcp                  # unix socket only
```

* `-screen 0 WxHx24` — depth 16 breaks many GL/EGL paths.
* `-nolisten tcp` + `-ac` is a common CI combination; prefer `xauth` where possible.
* `Xvfb` has no `Present`/`DRI3`; anything that queries them will take a software path or fail.
* For a maximised "screen" of arbitrary size, Xvfb's `Virtual` equivalent is simply the `-screen` size — there is no mode list.

## A.6 Worked example: the Colab / Tesla T4 desktop (no Xvfb, no VirtualGL)

A real setup that hit every trap above and still ended up with hardware
acceleration — because **none** of A.1–A.3 was used. A Colab-style CUDA image
ships a compute-only userspace; the fix is to give it a real X server on the GPU.

```
UE5 (Vulkan RHI) ──► libGLX_nvidia / nvidia ICD ──► /dev/nvidia0 (Tesla T4)
        │
        └──► Xorg :20, Driver "nvidia", GLX from libglxserver_nvidia.so
                  └── RustDesk peer → remote client
```

What is missing in such an image, and what each gap looks like:

| Missing piece | Symptom if not fixed |
|---|---|
| `/usr/lib64-nvidia` not on the loader path | `libglxserver_nvidia.so` can't resolve `libnvidia-glsi`/`libnvidia-tls` → Xorg silently falls back to `DRISWRAST` and still reports a healthy screen |
| no `xserver-xorg-video-nvidia` DDX package | "no screens found" |
| `libglxserver_nvidia.so.<kver>` not linked into `/usr/lib/xorg/modules/extensions/` | GLX never initialised; `glxinfo` → llvmpipe |
| no Vulkan ICD json | `vulkaninfo` finds no GPU |

The four provisioning steps, in this order:

```bash
# 1. loader path first - before any X server exists
echo /usr/lib64-nvidia > /etc/ld.so.conf.d/10-nvidia.conf && ldconfig

# 2. version-matched DDX against the *running* kernel module, not "latest"
KVER=$(grep -oP 'Module for x86_64\s+\K[0-9.]+' /proc/driver/nvidia/version)   # 580.82.07
apt-get install -y "xserver-xorg-video-nvidia-580=${KVER}-0ubuntu1" \
                   "libnvidia-cfg1-580=${KVER}-0ubuntu1"

# 3. GLX server extension + vulkan/egl vendor json
ln -sf /usr/lib64-nvidia/xorg/modules/extensions/libglxserver_nvidia.so.${KVER} \
       /usr/lib/xorg/modules/extensions/libglxserver_nvidia.so
printf '{"file_format_version":"1.0.0","ICD":{"library_path":"%s"}}\n' \
       /usr/lib64-nvidia/libGLX_nvidia.so.0 > /usr/share/vulkan/icd.d/nvidia_icd.json
```

```ini
# 4. /etc/X11/xorg-gpu.conf - headless: the two lines that matter
Section "Device"
    Driver "nvidia"
    BusID  "PCI:0:4:0"                              # lspci | grep -i vga
    Option "AllowEmptyInitialConfiguration" "true"   # no monitor attached
EndSection
Section "Screen" ... Depth 24 ... Modes "1920x1080" "1600x900" "1280x720"
```

Start it as the user (not root), then the app needs no wrapper at all:

```bash
Xorg :20 -config /etc/X11/xorg-gpu.conf \
     -modulepath /usr/lib/x86_64-linux-gnu/nvidia/xorg,/usr/lib/xorg/modules \
     -noreset -nolisten tcp

export VK_ICD_FILENAMES=/etc/vulkan/icd.d/nvidia_icd.json
export DISPLAY=:20
UnrealEditor            # no vglrun, no VGL_DISPLAY
```

Evidence it was really on the GPU: `glxinfo` → **NVIDIA Tesla T4, OpenGL 4.6**,
`direct rendering: Yes`; `vulkaninfo` → **1.4.312**; the editor logged a Vulkan
device with a **15,360 MB heap** on an 8.4 GB host (impossible for `llvmpipe`).

Lesson: on a workstation/container that is allowed to own the GPU, "hardware
acceleration" is not a bridge problem at all — it is a *provisioning* problem.
VirtualGL is only needed when the pixels must land somewhere the GPU driver
cannot present to.

---

# Part B — Xwayland with hardware acceleration on old proprietary drivers

## B.0 The one-paragraph theory

A Wayland compositor allocates buffers through either **GBM** (everyone except old NVIDIA) or **EGLStreams** (old NVIDIA). Xwayland lives *inside* the compositor and gets its pixels through the same mechanism, via `glamor`. So acceleration requires the **pair** to match:

```
Xwayland (with the right glamor backend)  ⟷  compositor (with the same buffer API)  ⟷  driver
```

Pre-495 there is no GBM in the driver, so you need the EGLStreams chain end-to-end. That is why "just install a newer Xwayland" doesn't help, and why wlroots-based compositors (sway, Hyprland, river) simply do not work.

## B.1 Prerequisites checklist

```bash
# 1. Kernel modesetting must be ON — everything Wayland-related depends on it
cat /sys/module/nvidia_drm/parameters/modeset      # must print Y
# else: add nvidia-drm.modeset=1 to the kernel command line and reboot

# 2. Driver version — this decides which path you are on
nvidia-smi --query-gpu=driver_version --format=csv,noheader

# 3. Xwayland present and versioned
Xwayland -version 2>&1 | head -2

# 4. egl-wayland (the EGL external platform that lets Wayland clients use the blob)
dpkg -l | grep -E "egl-wayland|libnvidia-egl-wayland" || rpm -qa | grep egl-wayland

# 5. libglvnd dispatches to NVIDIA
ls /usr/share/glvnd/egl_vendor.d/        # expect 10_nvidia.json
```

Typical environment for the whole session:

```bash
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export GBM_BACKEND=nvidia-drm            # 495+ only
export XDG_SESSION_TYPE=wayland
export MOZ_ENABLE_WAYLAND=1              # per-app, example
```

## B.2 Driver 470–494: EGLStreams recipe

**You need:** driver 470.x, Xwayland **≥ 21.1.2**, `egl-wayland`, `libglvnd`, and a compositor with an EGLStreams back end.

Compositor options:

| Compositor | How to get EGLStreams |
|---|---|
| **Mutter / GNOME** | Built in (dropped in GNOME 51). Force it if it picks the wrong path: `MUTTER_DEBUG_FORCE_EGL_STREAM=1` |
| **KWin / Plasma** | Plasma ≥ 5.16, built with `KWIN_BUILD_EGL_STREAM_BACKEND=ON` (default). Enable with `KWIN_DRM_USE_EGL_STREAMS=1`; newer KWin also honours `KWIN_DRM_FORCE_EGL_STREAMS=1` |
| wlroots (sway et al.) | **Not supported.** Third-party `wlroots-eglstreams` fork + sway's `--my-next-gpu-wont-be-nvidia` flag exist, but they are unmaintained and incomplete (multi-GPU broken, DMA-BUF partial) |

```bash
# KWin path
echo 'export KWIN_DRM_USE_EGL_STREAMS=1' | sudo tee /etc/profile.d/kwin.sh
# log out, choose the Plasma (Wayland) session, log in

# Mutter path (only if it misbehaves)
export MUTTER_DEBUG_FORCE_EGL_STREAM=1
```

Verify the session is really on the blob:

```bash
journalctl -b 0 --grep "renderer for" | tail -3     # should mention nvidia, not llvmpipe
glxinfo | grep "OpenGL renderer"                     # inside an X11/Xwayland app
__GLX_VENDOR_LIBRARY_NAME=nvidia glxinfo -B | grep renderer
```

Inside Xwayland, the accelerated GLX context is provided by the driver; `glxinfo` should print the NVIDIA renderer string, not `llvmpipe`.

## B.3 Driver 495+: switch to the GBM path

From 495 the driver exposes GBM, so use the standard route (and keep EGLStreams only as a fallback):

```bash
export GBM_BACKEND=nvidia-drm
export __GLX_VENDOR_LIBRARY_NAME=nvidia
# Xwayland >= 21.1.3 for the GBM fixes
```

Mutter and KWin pick GBM automatically for ≥ 495. Confirm the compositor's choice in its log (`journalctl -b 0 --grep "renderer for"`), and if you deliberately need the old path on KWin: `KWIN_DRM_FORCE_EGL_STREAMS=1`.

## B.4 Verification: is Xwayland actually accelerated?

```bash
# Which glamor backend did Xwayland initialise?
journalctl -b 0 --grep -i "glamor"
#   "glamor: 'wl_drm' not supported / Missing Wayland requirements for glamor GBM backend"
#   "glamor: 'wl_eglstream_display' not supported / Missing ... EGLStream backend"
#   "Failed to initialize glamor, falling back to sw"          <-- software, this is the bad one

# Direct test
DISPLAY=:0 glxinfo -B | grep -E "renderer|OpenGL version"
DISPLAY=:0 glxgears                     # then check CPU: 100% CPU == software path

# Vulkan under Xwayland
DISPLAY=:0 vkcube
```

Signs you are on the software path: `llvmpipe`, very high CPU for trivial GL, tearing/flicker (a known symptom of the implicit-sync emulation on the blob), or `XWAYLAND_NO_GLAMOR` left set in the environment.

## B.5 Troubleshooting matrix

| Symptom | Cause | Fix |
|---|---|---|
| `Xwayland` windows appear but everything is slow, CPU pegged | glamor fell back to software | check compositor buffer API matches driver (B.2/B.3); verify `nvidia-drm.modeset=1` |
| `MUTTER_DEBUG_FORCE_EGL_STREAM` documented everywhere but ignored | GNOME ≥ 51 | EGLStreams removed upstream; stay on GNOME ≤ 50 or move to driver ≥ 495 |
| `Missing Wayland requirements for glamor EGLStream backend` | compositor has no EGLStream support (wlroots, or newer KWin) | use Mutter/KWin with EGLStreams, or upgrade the driver |
| `wl_drm not supported`, then software fallback | compositor offers GBM, driver doesn't (< 495) | wrong pairing — go EGLStreams, or upgrade driver |
| Characters deleted while typing in X11 apps under Xwayland | glamor + blob interaction | `XWAYLAND_NO_GLAMOR=1` (works, but everything becomes software — use only as a workaround) |
| Windows flicker / out of order frames | blob's implicit-sync emulation | unavoidable pre-555; mitigate with explicit-sync-capable drivers (555+) |
| Steam/Proton won't start | glamor disabled via `XWAYLAND_NO_GLAMOR` | unset it |
| `glxinfo` says NVIDIA but games still stutter | app is Wayland-native and hits the EGLStreams path, or vulkan surface copy | test with `vkcube`, check `wayland-info` for `zwp_linux_dmabuf_v1` |
| Xwayland 24.1 + driver < 495 → no acceleration | EGLStream backend removed | pin Xwayland ≤ 23.x, or upgrade the driver |

## B.6 What genuinely does not work

Be blunt with yourself before burning a weekend:

* **Driver < 470**: no hardware-accelerated Xwayland, full stop.
* **wlroots compositors** (sway, Hyprland, river, Wayfire) with a pre-495 blob: unsupported upstream; the fork is a dead end for production.
* **GNOME ≥ 51 + driver < 495**: Mutter no longer has the fallback.
* **Xwayland ≥ 24.1 + driver < 495**: EGLStream glamor code is gone.
* **Wayland-native GL clients** (not Xwayland) on EGLStreams work only through the compositor's special protocol; apps that require `zwp_linux_dmabuf_v1` directly may still fail.

If the driver is pinned for a reason (legacy Quadro/Tesla, vendor certification, kernel ABI), the practical answer is usually: **stay on X11 (or headless Xorg) for the GPU work**, and expose it remotely — that is a well-trodden path, while accelerated Xwayland on a 4xx driver is a research project.

---

# Part C — When Xwayland is a dead end: mirror a headless X server into the compositor

This is the inversion that works on a **Kepler card (GTX 660 Ti, driver 470.x)**:
do not fight for accelerated Xwayland, and do not run GL apps inside the
compositor at all. Let Xorg own the GPU and *copy its picture* into a Wayland
surface.

```
app (GLX/Vulkan) ──► headless Xorg on the nvidia DDX      full HW acceleration
                            │ root window framebuffer
                            ▼
                      xfbridge                            XDamage + MIT-SHM
                            │ changed rectangles only
                            ▼
                  native wl_surface (xdg-toplevel)        wl_shm
                            ▼
                  your Wayland compositor (unchanged)
```

Companion code: **`/home/user/wayland-xorg-bridge/`** (C program + provisioning
scripts, `README.md` there).

> ### ⚠ The failure mode that matters more than the throughput numbers
>
> An X server **cannot share a GPU with a compositor that is scanning out from
> it.** Starting a real Xorg on the card that drives your monitor makes it take
> **DRM master**; the compositor cannot page-flip any more. Observed symptom on a
> Kepler desktop: the picture freezes on the last frame, `Ctrl+Alt+F*` seems
> dead (the kernel switches VT, but nothing repaints), and a hard reset follows.
>
> Note that this has **nothing to do with VT ioctls**: `-sharevts` correctly
> suppresses `VT_SETMODE`/`KDSETMODE` and Xorg still hijacks the display,
> because the takeover happens at the DRM level. Reading `lnx_init.c` is not
> enough to conclude "safe" — that was the mistake made while writing this.
>
> Two architectures are actually safe:
>
> | Setup | X server on the GPU? | Result |
> |---|---|---|
> | **Xvfb + VirtualGL EGL** (`vglrun -d egl0`) | no — renders offscreen, presents into Xvfb's CPU framebuffer | safe alongside any compositor; OpenGL on the GPU, 2D/X chrome on llvmpipe |
> | real Xorg on a GPU with **no monitor attached** (headless server, VM, container) | yes, but nothing else owns the card | safe; the fastest option, full GLX + Vulkan + hardware cursor |
> | real Xorg on the GPU that drives your monitor | yes | **hijack** — do not |
>
> The provisioning scripts now refuse the third case automatically.

## C.0 Why this beats the Part B options on pre-495 hardware

| Approach | On Kepler |
|---|---|
| Xwayland + EGLStreams | needs Xwayland ≤ 23.1 **and** Mutter ≤ 50 / old KWin; both defaults have moved on |
| wlroots + EGLStreams fork | unmaintained, multi-GPU broken |
| Xwayland with `XWAYLAND_NO_GLAMOR` | works, but every X app is on llvmpipe |
| **headless Xorg + mirror** | app gets the *full* driver: GLX, Vulkan, CUDA, DRI3, hardware cursor |
| X11 session + VNC/RustDesk | same acceleration, but you stay outside Wayland |

The mirror is the only option that gives the app the *real* driver while the
compositor stays whatever you already run — including a software-rendered
wlroots session, which then only has to blit one opaque buffer.

## C.1 How the copy stays cheap

* **XDamage** on the root window reports damaged rectangles; the bridge transfers
  only their bounding box, not the frame.
* **MIT-SHM** (`shm_get_image`) pulls it out of the X server in one round trip.
* Pixels land in **`wl_shm` buffers**; three are used, each carrying its own
  damage list so a skipped buffer still receives everything it missed.
* The **X cursor** is a hardware overlay (absent from the framebuffer), so it is
  fetched via XFixes and alpha-blended in; the compositor's cursor is hidden.
* **Input** goes the other way: `wl_pointer`/`wl_keyboard` → XTEST, with
  `X keycode = evdev keycode + 8`.

Measured on 2 shared vCPUs with a software compositor (worst-case environment),
1920×1080:

| Workload | Traffic | Rate |
|---|---|---|
| desktop, clock ticking (damage path) | 1.7 MB/s | ~36 fps |
| continuous full-screen redraw | 299 MB/s | ~36 fps |

So the cost model is `≈ 2 × W × H × 4 × fps` bytes/s only when *everything*
changes; normal UI is ~0.1 % of that. 1080p60 full-screen is about 1 GB/s of
memcpy — fine on a real desktop, tight on 2 vCPUs.

## C.2 What it costs you

* No scaling: surface = X screen size; change `GEOMETRY` instead.
* No dmabuf zero-copy: Kepler has no GBM, so `wl_shm` is the portable path. A
  `wl_eglstream_controller` exporter would be the GPU option and needs a
  compositor that still speaks it.
* One surface per **X screen**, not per window.
* Clipboard is not shared between the two worlds.
* Input is injected: no IME, no touch, no tablet.
* If the compositor is llvmpipe, the final blit is still CPU — but it is one
  opaque copy instead of rendering the app in software.

## C.3 The rule of thumb

> Hardware acceleration for X11 apps under Wayland on a legacy NVIDIA driver is
> not a compositor feature to be patched in. It is a matter of **deciding which
> process owns the GPU** and copying finished pixels across the boundary.

Pick per workload:

* **app needs the driver, compositor is secondary** → headless Xorg + mirror (Part C)
* **must be a Wayland-native window with zero copies** → upgrade the driver (≥495)
  and fix the compositor pairing (Part B)
* **no display needed at all** (CI, rendering, screenshots) → headless Xorg, or
  offscreen rendering, and skip Wayland entirely (Part A)

---

# Part D — The correct way: a second Xorg on its own VT (and why `-sharevts` is a trap)

Everything in Part C assumed the X server would sit on the *same* VT as the
compositor. That is what causes the hijack. The supported arrangement is older
and simpler: **one VT per display owner**, which is exactly how multiple X
servers coexisted for decades.

## D.1 What actually broke (source, not folklore)

`hw/xfree86/os-support/linux/lnx_init.c`, `xf86OpenConsole()`:

```c
if (!xf86Info.ShareVTs) {
        switch_to(xf86Info.vtno, "xf86OpenConsole");
        OsSignal(SIGUSR1, xf86VTRequest);      /* <-- the cooperation handler */
        VT.mode  = VT_PROCESS;
        VT.relsig = SIGUSR1;  VT.acqsig = SIGUSR1;
        ioctl(consoleFd, VT_SETMODE, &VT);
        ioctl(consoleFd, KDSETMODE, KD_GRAPHICS);
}
```

`VT_PROCESS` + `xf86VTRequest` **is** the whole cooperation protocol: the kernel
asks "may I switch away?", the server answers by running `LeaveVT()` (which drops
DRM master and restores text mode) and replying to the VT layer. When the VT
becomes active again, `EnterVT()` re-takes master.

`-sharevts` sets `xf86Info.ShareVTs = TRUE` and **skips that entire block**. So:

* no `VT_PROCESS` owner → nobody to notify → no release, no `VT_RELDISP`;
* the server keeps **DRM master** and keeps scanning out on the VT it was started on;
* the server also keeps its **input grab**, so `Ctrl+Alt+F<n>` may never even reach
  the kernel;
* the compositor cannot reclaim master and cannot page-flip.

Net effect: frozen picture, dead VT switching, hard reset. This was observed on a
GTX 660 Ti desktop and reproduced in reasoning by two independent LLM consults and
by the source above.

## D.2 The correct recipe

```bash
# no -sharevts, no -novtswitch; explicit VT on the command line
Xorg :1 vt2 -config /etc/X11/xorg.conf.d/20-nvidia-headless.conf \
     -nolisten tcp -noreset
```

* `vt2` makes `linux_parse_vt_settings()` take the `vtno != -1` branch, so it does
  **not** open `/dev/tty0` — it opens `/dev/tty2` only. That also removes the
  "Cannot open /dev/tty0" failure for a root-started server.
* `Ctrl+Alt+F1` → kernel asks the X server to release → X drops DRM master →
  compositor reclaims the card and repaints. `Ctrl+Alt+F2` brings X back.
* Nothing is copied, nothing is mirrored: the app has the GPU to itself while its
  VT is active.

## D.3 Can Xorg be told not to open a VT at all?

With the NVIDIA proprietary DDX: **no.**

| Mechanism | Works? | Notes |
|---|---|---|
| `HW_SKIP_CONSOLE` driver flag | only `dummy`, `Xwayland`, `Xvfb` | proprietary `nvidia_drv.so` does not set it, so `xf86OpenConsole()` always runs |
| `vtN` argument | yes | avoids `/dev/tty0`, still owns `/dev/ttyN` |
| `-sharevts` | **no — do not use** | skips `VT_PROCESS` (see D.1) |
| `-novtswitch` | irrelevant | only suppresses switching back on exit; harmless but pointless |
| `nvidia-drm modeset=0` | removes the DRM-master contest | but then no Wayland compositor can use that GPU for KMS at all — X owns the screen outright |
| `Option "UseDisplayDevice" "none"` + `AllowEmptyInitialConfiguration` | X configures no connector | still opens a VT; useful for a genuinely headless box, **not verified** to leave a running compositor's scanout untouched — treat as an experiment, not a guarantee |
| DRM leases (`drm_mode_create_lease`) | theoretically | the compositor would have to export `wp_drm_lease_v1`; Mutter/KWin do not, and the blob's support is untested — research project |
| Xvfb | yes, fully | no DRM, no VT, no root; GPU only through VirtualGL's EGL backend |

Rule of thumb:

```
compositor visible + GL app inside it  -> Xvfb + vglrun (Part A.1), or nouveau+Mesa
full GPU for the app                   -> own VT per owner (Part D.2)
nothing else using the card            -> headless Xorg, Part A.4
```

## D.3b Never write X configuration into `/etc/X11` for this

Two independent hazards, both hit while building this:

1. **Overwriting.** A generator that does `cat > /etc/X11/xorg.conf` (or a
   `xorg.conf.d` snippet with a name that may already exist) destroys a working
   configuration. Always: back up, then write, then keep a manifest you can
   reverse.
2. **Merging.** `/etc/X11/xorg.conf.d/*.conf` is read by **every** X server on the
   machine — including the one your desktop or display manager starts. A snippet
   containing `ServerFlags AutoAddDevices false` silently changes input behaviour
   for your normal session. A second, special-purpose server must not leave
   anything global behind.

The safe form, verified with a canary module (`Load "poisoncanary"` in
`/etc/X11/xorg.conf.d/`, which shows up in the log whenever that directory is
read):

```bash
Xorg :1 vt2 -config /tmp/xfd-:1/xorg.conf -configdir /tmp/xfd-:1/conf.d-isolated ...
# log: (++) Using config file: "/tmp/xfd-:1/xorg.conf"
#      (++) Using config directory: "/tmp/xfd-:1/conf.d-isolated"
#      canary loads: 3 without -configdir, 0 with it
```

Two details worth knowing:

* Xorg treats a `-configdir` directory containing **no `.conf` file** as
  nonexistent (`(EE) Unable to locate/open config directory`), so the isolated dir
  needs at least one (empty/comment-only) `.conf` as a marker.
* `/usr/share/X11/xorg.conf.d` is still read; only the admin directory can be
  redirected. That is the distro's own defaults, not user configuration.

## D.4 Quick sanity checks

```bash
cat /sys/class/tty/tty0/active                 # which VT is on screen
grep "using VT number" /tmp/xfd-:1/Xorg.log    # which VT the server took
ls -l /proc/<xorg-pid>/fd | grep tty           # proof it holds /dev/ttyN
sudo chvt 2                                    # switch; should not freeze anything
```

If `chvt` hangs or the screen keeps showing the old content, the server is not a
`VT_PROCESS` owner — check that `-sharevts` is not in the command line.

---

# Appendix — lessons from a real Tesla T4 container (driver 580, same mechanics)

These bit us on a containerised headless UE5 setup and apply to any vintage of the blob:

1. **`ldconfig` before Xorg.** Without `/usr/lib64-nvidia` in `ld.so.conf`, the GLX *server* module fails to load; Xorg falls back to `DRISWRAST` and reports success. Symptom downstream: `vulkaninfo` sees the T4, `glxinfo` says llvmpipe, and Vulkan apps die on `vkGetPhysicalDeviceSurfacePresentModesKHR`. Root cause is the loader path, not the driver.
2. **Vulkan ICD `library_path` must resolve.** A JSON pointing at `/usr/lib64-nvidia/libGLX_nvidia.so.0` fails with `libnvidia-glsi.so: cannot open shared object file` unless that directory is on the loader path. After the load of the ICD succeeds, `vulkaninfo --summary` reports the real `apiVersion`.
3. **`AllowEmptyInitialConfiguration` is the headless enabler** for the nvidia DDX; without it Xorg exits with "no screens found" on a monitor-less box.
4. **Present-mode queries are the canary.** `vkGetPhysicalDeviceSurfacePresentModesKHR → VK_ERROR_UNKNOWN` almost always means "this X server cannot present GPU frames" (Xvfb, or a software-GLX Xorg), not "your GPU/driver is broken".
5. **The `-glamor` switch on Xwayland** (`-glamor egl`, `-glamor gl`, `-glamor gles`) is useful when the default desktop-GL probe fails on a legacy driver.
6. **Container device nodes:** `/dev/nvidia0`, `/dev/nvidiactl`, `/dev/nvidia-uvm`, `/dev/dri/*` and (for input) `/dev/uinput` must all exist; missing `/dev/uinput` breaks remote-desktop input, missing `/dev/dri` breaks GBM/DRI3 paths.

---

## References

* Arch Wiki, *Wayland* — driver/compositor buffer-API matrix, Xwayland notes for NVIDIA < 470: <https://wiki.archlinux.org/title/Wayland>
* Arch Wiki, *VirtualGL* — `VGL_DISPLAY`, GLX redirection model: <https://wiki.archlinux.org/title/VirtualGL>
* VirtualGL changelog — EGL back end without a 3D X server: <https://github.com/VirtualGL/virtualgl/blob/main/ChangeLog.md>
* Phoronix, *Xwayland Nukes The NVIDIA EGLStream Backend* (removal in 24.1): <https://www.phoronix.com/news/XWayland-Drops-EGLStream>
* Phoronix, *XWayland 21.1.2 Released With NVIDIA Hardware Acceleration Support*: <https://www.phoronix.com/news/XWayland-21.1.3-Released>
* KDE/KWin environment variables wiki — `KWIN_DRM_USE_EGL_STREAMS`, `KWIN_DRM_FORCE_EGL_STREAMS`: <https://invent.kde.org/plasma/kwin/-/wikis/environment-variables>
* KWin EGLStream DRM backend commit (requirements: `modeset=1`, eglexternalplatform): <https://github.com/KDE/kwin/commit/c898f96df3e3a2d418ca511fdb6610cf087ca464>
* GNOME Wiki, *NVIDIA Graphics with the GNOME Wayland session*: <https://wiki.gnome.org/Initiatives/Wayland/NVIDIA>
* X.Org 21.1 release announcement (Glamor for Xvfb): <https://www.mail-archive.com/xorg-announce@lists.x.org/msg01320.html>
* Debian Wiki, *Wayland* — EGLStreams vs GBM by compositor: <https://wiki.debian.org/Wayland>
