# Headless Container Audio + RustDesk 1.5.x on Linux

## Problem Summary

In a headless Linux container (such as Google Colab / Docker / non-systemd GPU instances):

1. There is **no kernel sound card** (`/dev/snd` is absent, `/lib/modules/*` is absent so `modprobe snd-dummy` is impossible).
2. `systemd` is **not PID 1**, so `loginctl` fails (`System has not been booted with systemd as init system (PID 1)... Failed to connect to bus: Host is down`).
3. Even after setting up PulseAudio with a `DummyOutput` null sink and `enable-audio = 'Y'`, **a RustDesk peer running as `root` never connects to PulseAudio** (`pactl list short clients` and `pactl list short source-outputs` show zero `rustdesk` entries, and `rustdesk_rCURRENT.log` shows zero audio errors).

---

## Exact Root Cause (Verified in RustDesk 1.5.0 Source)

On Linux, RustDesk splits audio capture across two processes over a Unix domain socket:

1. `src/server/audio_service.rs` (`audio_service::run`) checks `!platform::is_prelogin()`, then connects to `/tmp/RustDesk-<uid>/ipc_pa` via `ipc::connect(1000, "_pa")` and sends `Config(("audio-input", ...))`.
2. The `_pa` listener (`crate::ipc::start_pa` in `src/ipc.rs:1486`) opens `psimple::Simple::new(None, ...)` against the PulseAudio monitor source (`get_pa_monitor()` — first source whose name contains `monitor`) and streams `f32le` 2-channel PCM back to `audio_service`.
3. **Crucially, `--server` never calls `start_pa()`.** Only the UI / connection-manager (`rustdesk --cm`) spawns `start_pa()` (`src/flutter.rs:1587`, `src/ui/cm.rs:100`).
4. When a remote client connects, `src/server/connection.rs:6325` (`start_ipc`) tries `ipc::connect(1000, "_cm")`; if absent:
   - **When running as `root` (`uid == 0`):** it calls `crate::platform::run_as_user(["--cm"])` (`src/platform/linux.rs:1404`) → `get_active_user_id_name()` → `get_values_of_seat0()` (`libs/base/src/platform/linux.rs:158`) → `run_loginctl()`. Because `loginctl` fails without `systemd-logind`, `uid` comes back empty → `bail!("No valid uid")`. `--cm` is never spawned, `/tmp/RustDesk-0/ipc_pa` is never created, and `audio_service` silently never captures a frame.
   - *(Starting `rustdesk --cm` manually in the background does not work either: it creates `ipc_cm` and `ipc_pa`, receives `"model closed"`, and exits within ~10 s.)*
   - **When running as a non-root user (`colab`):** `start_ipc` skips `run_as_user()` and calls `crate::run_me(["--cm"])` directly (`src/server/connection.rs:6355`). Both peer and `--cm` share `/tmp/RustDesk-<uid>/`, `--cm` stays supervised for the duration of the session, and `ipc_pa` opens PulseAudio immediately.

### Client UI Note (RustDesk 1.5.0)

There is **no** `"Enable audio"` toggle in the RustDesk 1.5.0 remote session toolbar (only *Voice call* / microphone input lives on the toolbar). `"Enable audio"` (`kOptionEnableAudio = "enable-audio"`) lives exclusively in **`desktop_setting_page.dart:1200`** under **Settings → Security → Permissions → Enable audio** on the peer, plus **Mute** in the client's per-peer connection menu.

---

## Solution & Scripts

### 1. `audio-setup.sh` (run as `root`)
Starts a system-wide PulseAudio daemon (`pulseaudio --system`) using a **new** config file `/etc/pulse/system-colab.pa` (never modifies `/etc/pulse/system.pa`):
- `module-native-protocol-unix auth-anonymous=1 socket=/run/pulse/native` so any local UID (`colab`, `root`, sandboxed apps) reaches the same audio server with zero cookie/XDG friction;
- `module-null-sink sink_name=DummyOutput` + `module-always-sink`, setting `DummyOutput` as default sink and `DummyOutput.monitor` as default source;
- creates `/etc/asound.conf` (`type pulse`) **only if absent** so pure-ALSA apps also route to `DummyOutput`;
- runs an automated 2-second 440 Hz `paplay` + `parec` self-test and prints peak amplitude (~11999 / 12000).

*(Do **not** attempt PulseAudio `sink_properties` multi-property masquerading to fake a hardware card — spaces and combined `device.class` properties fail module parsing in PulseAudio 16.1, and RustDesk's Linux `start_pa()` only checks that the source name contains `monitor`, which `DummyOutput.monitor` already satisfies.)*

### 2. `peer-as-colab.sh` (run as `root`)
- Ensures system PulseAudio is up;
- Stops any root-owned `rustdesk` processes;
- Copies `/root/.config/rustdesk/RustDesk{,2}.toml` to `/home/colab/.config/rustdesk/` if present (creating `.bak-<timestamp>` backups if `colab` already had different config files), preserving the peer's **ID** and **permanent password**;
- Ensures `/dev/uinput` exists with mode `0666` so non-root `colab` can inject keyboard/mouse input;
- Launches `rustdesk --server` (wait 7 s so main IPC socket `/tmp/RustDesk-<uid>/ipc` is ready) followed by `rustdesk` GUI as `colab` on `:20`;
- Sets `enable-audio = 'Y'` and `verification-method = 'use-both-passwords'`, and applies `RD_PASSWORD` if passed in the environment.

### 3. Diagnostics
- `audio-watch.sh` — read-only 6-minute sampler logging `pactl` clients, `source-outputs`, `rustdesk --cm` PIDs, `/tmp/RustDesk-*/ipc*` sockets, and audio log lines to `/tmp/audio-watch.log`.
- `cm-hold-test.sh` — standalone reproducer showing `--cm` creating `ipc_cm` + `ipc_pa` and exiting after ~5–15 s when unsupervised.
- `start-rustdesk-root.sh` — preserved for reference on how root Xauthority + `--server`-before-`--password` works on systems *with* `systemd-logind`.
