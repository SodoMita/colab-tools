#!/bin/bash
# gpu-desktop-provision.sh - re-provision the NVIDIA-accelerated X desktop after a
# container/VM restart (the CUDA GPU nodes of Colab-like setups revert to a
# compute-only userspace: no Xorg "nvidia" DDX driver, no GLX server module link).
#
# RUN AS ROOT:   su - root -c 'bash /path/gpu-desktop-provision.sh'
#
# After this, run (as user colab):
#   bash /home/colab/gpu-desktop.sh start
#   sudo /usr/local/bin/gpu-desktop-keepalive.sh &   (keeps everything alive)
#
# What it does:
#   1. installs the Xorg nvidia DDX + libnvidia-cfg, version-MATCHED to the
#      running kernel module (e.g. 580.82.07), straight from the CUDA repo
#      (the GL/EGL/GLX userspace already lives in the mounted /usr/lib64-nvidia)
#   2. links the GLX *server* module (libglxserver_nvidia.so) into the X modules dir
#   3. writes /etc/X11/xorg-gpu.conf (headless T4, no /dev/dri needed)
#   4. adds the "GPU-XFCE (NVIDIA T4 hw accel)" session to /etc/xrdp/xrdp.ini and
#      makes it the DEFAULT (first) session so a plain RDP client lands on the GPU desktop

set -e
export DEBIAN_FRONTEND=noninteractive

KVER=$(grep -oP 'Module for x86_64\s+\K[0-9.]+' /proc/driver/nvidia/version)
echo "kernel module version: $KVER"

echo "== 1. packages (version-matched) =="
if ! apt-get install -y --no-install-recommends \
        "xserver-xorg-video-nvidia-580=${KVER}-0ubuntu1" \
        "libnvidia-cfg1-580=${KVER}-0ubuntu1"; then
    echo "exact version not in repo - installing latest 580.x"
    apt-get install -y --no-install-recommends xserver-xorg-video-nvidia-580 libnvidia-cfg1-580
fi
apt-get install -y --no-install-recommends mesa-utils x11vnc x11-utils xterm freerdp3-x11 || true

echo "== 2. GLX server module link =="
ln -sf "/usr/lib64-nvidia/xorg/modules/extensions/libglxserver_nvidia.so.${KVER}" \
       /usr/lib/xorg/modules/extensions/libglxserver_nvidia.so

echo "== 3. Xorg config for the headless T4 =="
TS=$(date +%Y%m%d-%H%M%S)
[ -e /etc/X11/xorg-gpu.conf ] && cp -a /etc/X11/xorg-gpu.conf "/etc/X11/xorg-gpu.conf.bak-$TS"
cat > /etc/X11/xorg-gpu.conf <<'EOF'
Section "ServerLayout"
    Identifier "Layout0"
    Screen 0 "Screen0"
EndSection

Section "ServerFlags"
    Option "AutoAddDevices" "false"
    Option "AutoEnableDevices" "false"
EndSection

Section "Device"
    Identifier "T4"
    Driver "nvidia"
    BusID "PCI:0:4:0"
    Option "AllowEmptyInitialConfiguration" "true"
EndSection

Section "Monitor"
    Identifier "Monitor0"
    HorizSync 1-1000
    VertRefresh 1-1000
EndSection

Section "Screen"
    Identifier "Screen0"
    Device "T4"
    Monitor "Monitor0"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "1920x1080" "1600x900" "1280x720" "1024x768"
        Virtual 1920 1080
    EndSubSection
EndSection
EOF

echo "== 4. xrdp session (GPU-XFCE first = default) =="
python3 - <<'PYEOF'
import re
import shutil, time
p = "/etc/xrdp/xrdp.ini"
shutil.copy2(p, f"{p}.bak.{int(time.time())}")
s = open(p).read()
block = """[gpu-xfce]
name=GPU-XFCE (NVIDIA T4 hw accel)
lib=libvnc.so
ip=127.0.0.1
port=5910
username=na
password=ask
"""
# drop old block, then insert before [Xorg] so it becomes the default session
s = re.sub(r"\n\[gpu-xfce\]\n(?:.*\n)*?(?=\n\[|\Z)", "\n", s)
anchor = "\n[Xorg]\n"
i = s.find(anchor)
s = (s[:i] + "\n" + block + s[i:]) if i > 0 else (s.rstrip("\n") + "\n\n" + block)
open(p, "w").write(s)
print("xrdp.ini updated")
PYEOF

echo "== 5. keepalive =="
if [ -f /home/colab/gpu-desktop-keepalive.sh ]; then
    install -m 755 /home/colab/gpu-desktop-keepalive.sh /usr/local/bin/gpu-desktop-keepalive.sh
fi

echo
echo "provisioning done."
echo "next (as colab):  bash /home/colab/gpu-desktop.sh start"
echo "keepalive (root): setsid nohup /usr/local/bin/gpu-desktop-keepalive.sh </dev/null >/dev/null 2>&1 &"
