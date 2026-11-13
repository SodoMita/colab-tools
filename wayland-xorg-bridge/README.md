# xfbridge — a headless GPU Xorg mirrored into a native Wayland surface

> ## ⚠ Read this before running anything
>
> **Correction (this tool got it wrong once):** an earlier version of
> `20-xorg-headless.sh` passed `-sharevts`. That flag is a trap: it makes Xorg skip
> its `VT_PROCESS` setup and its `xf86VTRequest` handler, so nothing answers the
> kernel when you press `Ctrl+Alt+F<n>`. The server keeps DRM master *and* its input
> grab, your compositor can never page-flip again, and the only way out is a reset.
>
> **What is safe now.** A second X server on your GPU is fine — it just has to own
> **its own VT**, which is how multiple X servers always coexisted:
>
> ```bash
> sudo chvt 2                                       # optional: go look at it
> SUDO=1 ./scripts/20-xorg-headless.sh plan         # prints the exact argv
> SUDO=1 ./scripts/20-xorg-headless.sh start --switch
> # Ctrl+Alt+F1 -> compositor back, X drops DRM master; Ctrl+Alt+F2 -> X
> ./scripts/20-xorg-headless.sh stop                # returns you to the compositor
> ```
>
> The script now: chooses a free VT (never the active one), refuses `SHAREVTS=1`,
> passes `vtN` explicitly, verifies `using VT number N` in the log, and shows a plan
> before starting.
>
> **Zero-risk alternative:** `scripts/15-xvfb-soft.sh` — Xvfb never opens DRM or a
> VT and needs no root; GL apps still reach the GPU through `vglrun -d egl0`.
>
> **Nothing is written into `/etc` by default.** An earlier version installed a
> snippet into `/etc/X11/xorg.conf.d/`, which (a) could overwrite a file you
> already had and (b) is merged into *every* X server on the machine, including
> the one your desktop uses. Now:
>
> * the per-display config lives in `/tmp/xfd-:N/xorg.conf`, and the server runs
>   with `-config <that> -configdir /tmp/xfd-:N/conf.d-isolated`, so
>   `/etc/X11/xorg.conf.d` is **not read** (verified with a canary module: 3 loads
>   without `-configdir`, 0 with it);
> * anything that must go to a system path goes through `managed_write`, which
>   backs the old file up first and records it in a manifest;
> * `scripts/05-system-config.sh list|diff|backup|restore` shows and undoes all of
>   it — restore is verified to return your file byte-identical.
>
> **Cannot be done:** telling the NVIDIA DDX not to open a VT at all. It does not
> set `HW_SKIP_CONSOLE`; only `dummy`/`Xvfb`/`Xwayland` do. `vtN` avoids
> `/dev/tty0`, not the VT. Full matrix in
> `../docs/xvfb-xwayland-nvidia-hwaccel.md`, Part D.

## 1. Why this exists

On a GTX 660 Ti (GK104, driver **470.256.02**, the last Kepler branch) the normal
routes are closed:

| Route | Status on Kepler |
|---|---|
| Xwayland with GBM | needs driver ≥ **495** — not available |
| Xwayland with EGLStream glamor | needs Xwayland 21.1.x–23.1.x **and** a compositor with `wl_eglstream`; removed from Xwayland 24.1, dropped by Mutter 51 |
| wlroots compositors (sway/Hyprland) | never supported EGLStreams; the `wlroots-eglstreams` fork is unmaintained |
| Plain Xssession | fine, but that's not what you asked for |

Result: under Wayland your GL apps either run on `llvmpipe` (slow) or don't
start. The remaining honest answer is: **let X own the GPU, and copy its picture
into a Wayland window.** The copy is cheap if you only copy what changed.

Detailed background: `../docs/xvfb-xwayland-nvidia-hwaccel.md`.

---

## 2. What the program does

* **XDamage** on the root window → knows which rectangles changed.
* **MIT-SHM** (`shm_get_image`) → one round trip per frame pulls the damaged
  bounding box out of the X server; falls back to `get_image` if SHM is missing.
* **Per-buffer damage lists** → three `wl_shm` buffers, each remembers what
  changed since *it* was last updated, so a buffer that was skipped for 20
  frames still receives all 20 frames' worth of damage when reused. No stale
  pixels can reach the compositor.
* **Cursor** → the X cursor is a hardware overlay and is *not* in the
  framebuffer, so it is fetched with XFixes and alpha-blended in; the
  compositor's own cursor is hidden (`wl_pointer.set_cursor(NULL)`).
* **Input** → `wl_pointer`/`wl_keyboard` events are replayed into X with XTEST.
  Wayland keycodes are evdev keycodes and Xorg's evdev driver uses evdev+8, so
  `keycode = wl_key + 8` (adjust with `--keymap-offset`). Modifiers need no
  translation: injecting shift/ctrl key presses makes X track its own state.
* **Frame pacing** → `wl_surface.frame` callbacks; if the compositor is behind,
  frames are skipped rather than queued.

What it deliberately does **not** do: scale, share the clipboard, forward touch
or IME, or export dmabufs (see limitations).

---

## 3. Performance — measured, not guessed

Measured on the dev sandbox (2 shared vCPUs, Xvfb as the X server, headless
Weston as the compositor — i.e. a *pessimistic* software compositor), 1920×1080:

| Workload | Traffic through the bridge | Notes |
|---|---|---|
| Static desktop, clock ticking | **1.7 MB/s** | damage tracking doing its job (~175× less than a full frame) |
| Continuous full-screen redraw | **299 MB/s**, 36 fps | worst case, every pixel every frame |
| 1024×768, clock ticking | 0.7 MB/s | |

The full-redraw ceiling here is CPU-bound: 8.3 MB/frame twice (X server→shm, then
memcpy into the shm buffer) plus the software compositor's upload, on two shared
vCPUs. On a real machine with a GPU-accelerated compositor (Mutter/KWin on
EGLStreams), the compositor's part is a GPU texture upload, and the remaining
cost is the two CPU copies: roughly `2 × W × H × 4 × fps` bytes/s.

Budget rule of thumb: **1080p60 full-screen ≈ 1 GB/s of memcpy**; that is
comfortable on a normal desktop and tight on a 2-vCPU container. Anything
damage-driven (normal desktop use, an editor, a 3D viewport with modest
updates) is two orders of magnitude cheaper.

Knobs if you need more:

* smaller `GEOMETRY` (1440×900 or 1600×900 instead of 1920×1080) — cost scales
  linearly with pixels;
* `--fps 30` for a desktop mirror;
* don't use `--no-damage` (that is exactly the 300 MB/s case, for debugging only).

---

## 4. Install

```bash
cd wayland-xorg-bridge
./scripts/00-build.sh                  # dev packages + make -> ./xfbridge

sudo bash scripts/10-provision-xorg-legacy.sh    # once per machine / container
```

The provisioner detects the loaded kernel module version, installs the
version-matched `xserver-xorg-video-nvidia-<branch>` DDX, fixes the loader path
(the `libglxserver_nvidia` trap), links the GLX *server* module, writes a
headless `/etc/X11/xorg-gpu.conf` with the right `BusID`, enables
`nvidia-drm.modeset=1`, and creates the Vulkan ICD if missing.

Then, **as your normal user, inside the Wayland session**:

```bash
./scripts/90-doctor.sh           # tells you exactly what is still wrong, if anything
./scripts/20-xorg-headless.sh start
```

---

## 4a. Arch Linux

Arch needs almost none of the provisioning: `nvidia-utils` already ships the DDX
(`/usr/lib/xorg/modules/drivers/nvidia_drv.so`), the GLX server module
(`/usr/lib/xorg/modules/extensions/libglxserver_nvidia.so`), the Vulkan ICD and
the glvnd vendor file, and the libs live in `/usr/lib` which is on the loader
path. So step 10 mostly just prints "already present" — which is the point of it
being idempotent.

```bash
# 1. build deps + build
sudo pacman -S --needed base-devel pkgconf wayland wayland-protocols libxcb
make -j"$(nproc)"

# 2. which driver do you actually have?
cat /sys/module/nvidia/version               # -> 470.256.02 on a 660 Ti
pacman -Q | grep -i nvidia                   # expect nvidia-470xx-{dkms,utils} or nvidia-open-dkms

# 3. X bits
sudo pacman -S --needed xorg-server xorg-xauth xorg-xdpyinfo xorg-xrandr \
                        xorg-xsetroot mesa-utils
sudo bash scripts/10-provision-xorg-legacy.sh   # writes /etc/X11/xorg.conf.d/20-nvidia-headless.conf
                                                # + /etc/modprobe.d/nvidia-drm-modeset.conf (was already on)

# 4. use it
./scripts/90-doctor.sh
./scripts/30-xapp.sh glxgears
```

Arch notes:

* **Kepler/Maxwell (660 Ti included) is EOL in the mainline `nvidia` package.**
  You need the AUR `nvidia-470xx-dkms` + `nvidia-470xx-utils`. The scripts detect
  the 470 branch and say so.
* Headless Xorg works without `/dev/dri`; the `nvidia` DDX talks to
  `/dev/nvidia*` directly. `nvidia_drm`/`modeset=1` matters only for a *Wayland
  compositor running on the GPU* — the mirror does not need it.
* If you use DKMS, keep `linux-headers` installed and re-run `mkinitcpio -P` after
  driver updates when you changed `/etc/modprobe.d`.
* Headless config location follows Arch convention:
  `/etc/X11/xorg.conf.d/20-nvidia-headless.conf`.
* On a hybrid laptop, set `BusID` explicitly:
  `sudo XORG_BUSID=PCI:1:0:0 bash scripts/10-provision-xorg-legacy.sh`.
* `xorg-server` on Arch runs as root by default, so nothing about logind/seat
  management gets in the way of a second, headless X server.

## 5. Usage

**Zero-risk mode** (nothing can be hijacked — Xvfb, no DRM, no VT, no root):

```bash
./scripts/15-xvfb-soft.sh start                     # Xvfb :2
SAFE=1 ./scripts/30-xapp.sh glxgears                # GL through vglrun -d egl0
./scripts/15-xvfb-soft.sh status                    # llvmpipe bare vs NVIDIA via vglrun
```

Check what any step would touch, before running it:

```bash
./scripts/05-system-config.sh list      # what has already been changed, and where the backups are
./scripts/05-system-config.sh backup    # snapshot /etc/X11 *before* you experiment
sudo ./scripts/05-system-config.sh restore
```

**Full GPU, second server on its own VT** (correct coexistence, switching works):

```bash
SUDO=1 ./scripts/20-xorg-headless.sh plan           # review the argv first
SUDO=1 ./scripts/20-xorg-headless.sh start --switch  # vt2, switches to it
./scripts/30-xapp.sh blender -b ~/scene.blend        # DISPLAY=:1, full speed
./scripts/20-xorg-headless.sh stop                   # back to the compositor
```

`Ctrl+Alt+F1` / `Ctrl+Alt+F2` switch between the compositor and the X server;
whoever's VT is active owns DRM master. Nothing is copied or mirrored.

Whole desktop (XFCE) in a window — all X clients accelerated:

```bash
./scripts/40-desktop.sh start
FULLSCREEN=1 GEOMETRY=1920x1080 ./scripts/40-desktop.sh start
./scripts/40-desktop.sh stop
```

The bridge directly, for scripting:

```bash
export XAUTHORITY=/tmp/xfd-:1/Xauthority
./xfbridge --x-display :1 --fps 60 --title "X :1"      # window
./xfbridge --x-display :1 --fullscreen                 # fullscreen
./xfbridge --x-display :1 --no-input                   # view only
./xfbridge --x-display :1 --frames 20 --dump-frame /tmp/f.ppm -v   # self-test
```

Several screens at once (e.g. a game on one X screen, a desktop on another):

```bash
XFDISPLAY=:1 GEOMETRY=1280x720 ./scripts/20-xorg-headless.sh start
XFDISPLAY=:2 GEOMETRY=1920x1080 ./scripts/20-xorg-headless.sh start
./xfbridge --x-display :1 --title game &
./xfbridge --x-display :2 --title desktop &
```

Environment variables: `SUDO=1` (run the server as root), `SHAREVTS=0` (allow VT
switching), `XFDISPLAY` (default `:1`), `GEOMETRY`, `XFDIR`
(default `/tmp/xfd-<display>`), `BRIDGE_FPS`, `FULLSCREEN`, `NO_INPUT`,
`KEEP_BRIDGE`, `BRIDGE_TITLE`, `DESKTOP`.

---

## 6. Limitations (read before you rely on it)

1. **No scaling.** The Wayland surface is exactly the X screen size in pixels. If
   the window is smaller, the compositor crops. Want a different size? Change
   `GEOMETRY` (and the `Modes`/`Virtual` line in `xorg-gpu.conf`).
2. **Not zero-copy.** `wl_shm` means one memcpy per frame. On Kepler there is no
   GBM, so EGL dmabuf export is not available; a `wl_eglstream_controller` path
   would be the GPU option, and it needs a compositor that still implements that
   protocol (Mutter ≤ 50, older KWin). Not implemented here — shm is the only
   portable route.
3. **One surface per X screen**, not per X window. Use several X screens if you
   want several Wayland windows.
4. **Clipboard is not shared** between the Wayland session and the X server.
   Workaround: `wl-clipboard` + a tiny sync daemon, or run the apps that need
   copy/paste inside the same side.
5. **Input is injected, not negotiated.** Keyboard works via evdev+8; unusual
   layouts, IME, dead keys, touch and tablets are not forwarded. Pointer
   position is absolute inside the surface.
6. **No vsync relation** to the app: the app renders at its own pace, the bridge
   samples it at `--fps`. For video playback you may see tearing/judder at
   mismatched rates; the bridge is not a video path.
7. **Cursor**: shape/position are polled per frame, so very fast pointer motion
   can lag the drawn cursor by one frame. Tooltips and cursor animation work.
8. **Wayland compositing cost remains.** If your compositor is itself
   software-rendered (`llvmpipe`), the final blit is still done on the CPU — but
   it is now a single opaque copy instead of rendering the whole app in software.

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "NVIDIA kernel module not loaded" but `nvidia-smi` works | fixed: versions are now read from `/sys/module/nvidia/version` first, then `nvidia-smi`, then `/proc/driver/nvidia/version` with a branch-tolerant regex (470 prints `x86_64 Kernel Module  470.256.02`, 495+ prints `Open Kernel Module for x86_64  …`). If it still fails: `cat /sys/module/nvidia/version` |
| Window is black | `xfbridge -v` → `X screen WxH`; if `shm=0`, SHM is blocked (check `/dev/shm`, container IPC). Self-test with `--frames 5 --dump-frame`. |
| `cannot connect to a Wayland compositor` | `WAYLAND_DISPLAY` unset — run from inside the session, or export `WAYLAND_DISPLAY=wayland-0`. |
| `X error ... on request` spam after resize | X screen changed size; restart the bridge (buffer size is fixed at start). |
| Cursor invisible in the window | compositor hides the cursor while a surface sets its own; the bridge hides it explicitly. If your compositor draws its own decor/cursor overlay it may override — that only affects the pointer inside the bridge window. |
| Screen froze after starting the X server / VT switching dead | the X server took DRM master from the compositor. From SSH: `scripts/99-panic.sh --kill`. Prevent: use `15-xvfb-soft.sh`; the real-Xorg script now refuses when a monitor is attached to the NVIDIA card. |
| `parse_vt_settings: Cannot open /dev/tty0 (Permission denied)` | The nvidia DDX needs the console: `xf86OpenConsole()` → `linux_parse_vt_settings()` does `open("/dev/tty0")` unless a `vtN` arg is given, and only drivers answering `HW_SKIP_CONSOLE` (dummy/Xwayland) skip the console. Also, the setuid wrapper **drops root** when every `/dev/dri/cardN` supports KMS — true with nvidia-drm — so even the wrapper ends up unprivileged. Fix: `printf 'allowed_users = anybody\nneeds_root_rights = yes\n' \| sudo tee /etc/X11/Xwrapper.config`, or `SUDO=1 scripts/20-xorg-headless.sh start`. `-sharevts` (passed by default) keeps it from switching VT or setting `KD_GRAPHICS`, so your Wayland session keeps drawing. |
| `Xorg.wrap: Only console users are allowed to run the X server` | same wrapper config: add `allowed_users = anybody` (keep `needs_root_rights = yes`). |
| `start` prints "did not come up" and the log is empty/absent | the server never really started. On Arch `/usr/bin/Xorg` is the setuid wrapper `Xorg.wrap`, which refuses users who are not on the console seat with `Only console users are allowed to run the X server` **on stderr only** (so no logfile is created). Fix: `XORG_BIN=/usr/lib/Xorg scripts/20-xorg-headless.sh start`, or `echo 'allowed_users = anybody' \| sudo tee /etc/X11/Xwrapper.config`. The script now detects this and prints the exact remedy; `start --foreground` shows live output. |
| Typing produces wrong characters | `--keymap-offset` — try `0` or `8`; check `xmodmap -pke | head` on the X side. |
| Everything slow, high CPU in the app | the app is not on the GPU: run `90-doctor.sh`, look at section 4 (`GL renderer`). If it says llvmpipe, the provisioning step did not take effect. |
| Frames stall when the window is hidden | expected: `wl_surface.frame` callbacks stop, the bridge skips frames instead of queueing. |
| `Mutter: client tried to set cursor on invalid surface` | harmless on some versions; pointer still works. |

---

## 8. Files

| Path | What |
|---|---|
| `src/xfbridge.c` | the bridge (~900 lines, no dependencies beyond libwayland + libxcb) |
| `Makefile` | generates `xdg-shell` bindings with `wayland-scanner`, builds `./xfbridge` |
| `scripts/00-build.sh` | installs dev packages (apt/dnf/pacman) and builds |
| `scripts/lib-nvidia.sh` | shared detection: driver version/branch (all format variants), distro, DDX/GLX/ICD locations, package names per distro |
| `scripts/10-provision-xorg-legacy.sh` | root: DDX, loader path, GLX server module, headless `xorg.conf`, Vulkan ICD, `modeset=1` — skips whatever the distro already packaged |
| `scripts/20-xorg-headless.sh` | start/stop/status of the headless Xorg (`start\|stop\|restart\|status`, `--foreground`), with failure diagnosis (wrapper refusal, missing DDX, no screens, loader path, stale locks) |
| `scripts/30-xapp.sh` | one command: Xorg + bridge + your app, cleans up after |
| `scripts/40-desktop.sh` | a whole XFCE desktop in one Wayland window |
| `scripts/05-system-config.sh` | list / diff / backup / **restore** everything this toolkit changed in `/etc` |
| `scripts/15-xvfb-soft.sh` | **safe** headless X: Xvfb, no DRM/VT/root, optional VirtualGL |
| `scripts/99-panic.sh` | recover from a hijacked/frozen display: report, `--kill`, `--chvt N` |
| `scripts/90-doctor.sh` | read-only diagnosis of driver/loader/GL/Wayland; `--test` runs a 5-frame self-test |
| `test-bridge-frame*.png` | output of the self-test on this sandbox |

---

## 9. Test status

Validated end-to-end in the dev sandbox (Xvfb as the X server, headless Weston as
the compositor):

* capture is pixel-exact, colours correct (`XRGB8888` ↔ BGRX), full screen and
  damage-only updates;
* cursor hotspot lands exactly on the reported pointer position;
* 40 frames committed, clean exit, no leaks reported by `valgrind`-free runs;
* damage tracking measured at 1.7 MB/s vs 299 MB/s for full redraws at 1080p;
* `30-xapp.sh` starts the bridge, runs the app, and tears the bridge down.
* `20-xorg-headless.sh` brought up a real headless Xorg at 1920x1080 (dummy DDX as
  the stand-in) and reported `state: UP` + screen size; `stop` cleaned it up.
* Privilege handling verified: refuses cleanly with an explanation when neither the
  console nor the wrapper is available; `SUDO=1` starts a root-owned server with
  `-sharevts -novtswitch`; the Xorg log then contains **no** `VT_SETMODE` /
  `KDSETMODE KD_GRAPHICS`, i.e. the Wayland VT is untouched. `wrapper_grants_root()`
  unit-tested against a fake setuid wrapper (no config → no, config+setuid → yes,
  setuid cleared → no).
* Behaviour derived from xorg-server 21.1.16 source (`lnx_init.c`,
  `xorg-wrapper.c`), not from folklore.
* **Hijack guard** unit-tested with a fake `/sys/class/drm` tree: refuses with a
  monitor `connected` on the NVIDIA card, passes when that connector is
  `disconnected`.
* **Safe path** verified end-to-end: Xvfb :2 → bridge → headless Weston, frame
  dumped and correct, no root and no DRM involved.
* `99-panic.sh --kill` verified to stop only servers with a pid file under
  `/tmp/xfd-*` / `/tmp/xvfb-*` — it matches bridges by exact process name, never
  `pgrep -f` (an earlier version killed a shell that merely mentioned the name).
* **Config isolation** verified: a canary `Section "Module" Load "poisoncanary"`
  placed in `/etc/X11/xorg.conf.d/` is loaded 3x by a server started without
  `-configdir` and 0x with it; the launcher now asserts
  `Using config directory: "/tmp/xfd-:N/conf.d-isolated"` in the log.
  (Xorg treats a config dir with no `.conf` inside as nonexistent, hence the
  marker file.)
* **Backup/restore** verified: `managed_write` rejects no-op writes, backs up the
  previous file, records `modified`/`created`, and `restore` returned the original
  user config byte-identical (same md5) and deleted the file we had created.
* `20-xorg-headless.sh stop` verified against a **root-owned** server (42 ms,
  clean); liveness is now read from `/proc`, because `kill -0` returns EPERM for
  other users' processes and looked like "already exited".
* Failure diagnosis verified against two reproduced failures: a missing/incorrect
  DDX (`Failed to load module` → points at `nvidia_drv.so`) and the Arch
  `Xorg.wrap` console-user refusal with an empty log → prints the Xwrapper fix.

**Not yet validated on real Kepler hardware** — the box that was going to test
it is currently unreachable (dead SSH tunnel). The NVIDIA-specific parts
(`AllowEmptyInitialConfiguration`, GLX server module linking, EGLStreams
compositor) are standard, documented DDX behaviour, but treat the first run on
the 660 Ti as a test: `sudo bash scripts/10-provision-xorg-legacy.sh` then
`./scripts/90-doctor.sh` will tell you immediately whether GL is hardware or
llvmpipe.
