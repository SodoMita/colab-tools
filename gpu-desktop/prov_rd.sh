#!/bin/bash
# prov_rd.sh - lean GPU desktop + RustDesk for a fresh CUDA box (root).
# Backs up any X config it replaces; writes nothing else destructive.
set -x
export DEBIAN_FRONTEND=noninteractive
KVER=$(grep -oP 'Module for x86_64\s+\K[0-9.]+' /proc/driver/nvidia/version)
echo "== nvidia kmod $KVER  $(date -u)"

########## 1. NVIDIA loader path + vendor files (BEFORE any X server) ##########
echo "/usr/lib64-nvidia" > /etc/ld.so.conf.d/10-nvidia.conf
ldconfig 2>/dev/null
mkdir -p /usr/lib/x86_64-linux-gnu/nvidia/xorg
for f in /usr/lib64-nvidia/xorg/modules/*.so*; do [ -e "$f" ] && ln -sf "$f" /usr/lib/x86_64-linux-gnu/nvidia/xorg/; done
ln -sf /usr/lib64-nvidia/libGLX_nvidia.so.0 /usr/lib/x86_64-linux-gnu/libGLX_nvidia.so.0
ln -sf /usr/lib64-nvidia/libEGL_nvidia.so.0 /usr/lib/x86_64-linux-gnu/libEGL_nvidia.so.0
mkdir -p /usr/share/glvnd/egl_vendor.d
printf '{"file_format_version":"1.0.0","ICD":{"library_path":"libEGL_nvidia.so.0"}}\n' \
  > /usr/share/glvnd/egl_vendor.d/10_nvidia.json
mkdir -p /etc/vulkan/icd.d /usr/share/vulkan/icd.d
printf '{"file_format_version":"1.0.0","ICD":{"library_path":"/usr/lib64-nvidia/libGLX_nvidia.so.0"}}\n' \
  | tee /etc/vulkan/icd.d/nvidia_icd.json > /usr/share/vulkan/icd.d/nvidia_icd.json
echo "== STEP1 nvidia wiring done"

########## 2. packages ##########
apt-get update -y
apt-get install -y --no-install-recommends \
  xserver-xorg-core xserver-xorg xinit x11-xserver-utils xauth \
  xserver-xorg-input-libinput xserver-xorg-input-all \
  "xserver-xorg-video-nvidia-580=${KVER}-0ubuntu1" "libnvidia-cfg1-580=${KVER}-0ubuntu1" \
  xfce4 xfce4-terminal dbus-x11 x11vnc x11-utils xterm wmctrl \
  mesa-utils fonts-dejavu fonts-liberation \
  pulseaudio pulseaudio-utils pavucontrol \
  imagemagick xdotool x11-apps unzip zip curl wget ca-certificates file
echo "APT_RC=$?"

########## 3. headless X config - never clobber an existing one ##########
TS=$(date +%Y%m%d-%H%M%S)
if [ -e /etc/X11/xorg-gpu.conf ]; then
  cp -a /etc/X11/xorg-gpu.conf "/etc/X11/xorg-gpu.conf.bak-$TS"
  echo "== backed up existing /etc/X11/xorg-gpu.conf -> .bak-$TS"
fi
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
mkdir -p /usr/lib/xorg/modules/extensions
ln -sf "/usr/lib64-nvidia/xorg/modules/extensions/libglxserver_nvidia.so.${KVER}" \
       /usr/lib/xorg/modules/extensions/libglxserver_nvidia.so
ldconfig
mknod /dev/uinput c 10 223 2>/dev/null; chmod 666 /dev/uinput 2>/dev/null
chown -R colab:colab /home/colab
echo "== STEP3 xorg conf done"

########## 4. RustDesk ##########
RD_URL=$(curl -sL https://api.github.com/repos/rustdesk/rustdesk/releases/latest \
  | grep -oE 'https://[^"]*rustdesk-[0-9.]+-x86_64\.deb' | head -1)
[ -z "$RD_URL" ] && RD_URL="https://github.com/rustdesk/rustdesk/releases/download/1.5.0/rustdesk-1.5.0-x86_64.deb"
echo "== rustdesk deb: $RD_URL"
curl -fsSL "$RD_URL" -o /tmp/rustdesk.deb && apt-get install -y /tmp/rustdesk.deb
echo "RUSTDESK_RC=$?  $(which rustdesk)"

apt-get clean
echo "PROV_RD_DONE $(date -u)  free=$(df -h / | tail -1 | awk '{print $4}')"
