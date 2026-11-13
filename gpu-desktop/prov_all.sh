#!/bin/bash
# prov_all.sh - ROOT, fresh-box -> GPU desktop + RustDesk + UE5 toolchain prerequisites.
# Order matters: ldconfig for /usr/lib64-nvidia MUST happen before Xorg starts,
# otherwise the NVIDIA GLX server module fails and Vulkan cannot present.
set -x
export DEBIAN_FRONTEND=noninteractive
KVER=$(grep -oP 'Module for x86_64\s+\K[0-9.]+' /proc/driver/nvidia/version)
echo "== nvidia kmod $KVER   $(date -u)"

########## 1. reclaiM disk from the ML base image (unused here) ##########
cd /usr/local/lib/python3.13/dist-packages 2>/dev/null && rm -rf \
  nvidia torch torchvision torchaudio tensorflow tensorflow_text \
  libcugraph libcudf libcuvs libcuml triton pyspark jax_plugins jaxlib cuda \
  keras* cupy* cudf* cuml* cugraph* nvidia_*
rm -rf /usr/local/cuda-13.0 /usr/local/cuda-13 /usr/local/cuda /usr/local/lib/julia /usr/local/julia*
apt-get -y purge 'r-cran-*' r-recommended r-base-core >/dev/null 2>&1
rm -rf /usr/lib/R /usr/local/lib/R
echo "== STEP1 reclaim: free=$(df -h / | tail -1 | awk '{print $4}')"

########## 2. NVIDIA linker path FIRST (before any X server) ##########
echo "/usr/lib64-nvidia" > /etc/ld.so.conf.d/10-nvidia.conf
ldconfig 2>/dev/null
mkdir -p /usr/lib/x86_64-linux-gnu/nvidia/xorg
for f in /usr/lib64-nvidia/xorg/modules/*.so*; do [ -e "$f" ] && ln -sf "$f" /usr/lib/x86_64-linux-gnu/nvidia/xorg/; done
ln -sf /usr/lib64-nvidia/libGLX_nvidia.so.0 /usr/lib/x86_64-linux-gnu/libGLX_nvidia.so.0
ln -sf /usr/lib64-nvidia/libEGL_nvidia.so.0 /usr/lib/x86_64-linux-gnu/libEGL_nvidia.so.0
mkdir -p /usr/share/glvnd/egl_vendor.d
printf '{"file_format_version":"1.0.0","ICD":{"library_path":"libEGL_nvidia.so.0"}}\n' > /usr/share/glvnd/egl_vendor.d/10_nvidia.json
mkdir -p /etc/vulkan/icd.d /usr/share/vulkan/icd.d
printf '{"file_format_version":"1.0.0","ICD":{"library_path":"/usr/lib64-nvidia/libGLX_nvidia.so.0","api_version":"1.4.312"}}\n' \
  | tee /etc/vulkan/icd.d/nvidia_icd.json > /usr/share/vulkan/icd.d/nvidia_icd.json
echo "== STEP2 nvidia wiring done"

########## 3. apt: desktop + input + build deps ##########
apt-get update -y
apt-get install -y --no-install-recommends \
  xserver-xorg-core xserver-xorg xinit x11-xserver-utils xauth \
  xserver-xorg-input-libinput xserver-xorg-input-all \
  "xserver-xorg-video-nvidia-580=${KVER}-0ubuntu1" "libnvidia-cfg1-580=${KVER}-0ubuntu1" \
  xfce4 xfce4-terminal xfce4-goodies dbus-x11 x11vnc x11-utils mesa-utils vulkan-tools libvulkan1 \
  imagemagick xdotool xterm wmctrl x11-apps \
  fonts-dejavu fonts-liberation fonts-noto-core \
  pulseaudio pulseaudio-utils pavucontrol \
  unzip zip curl wget ca-certificates gnupg lsb-release file net-tools htop nano less tree git \
  libgl1 libglx-mesa0 libegl1 libgles2 libxcursor1 libxinerama1 libxrandr2 \
  build-essential pkg-config libc6-dev \
  clang lld libc++-dev libc++abi-dev libomp-dev \
  libx11-dev libxrandr-dev libxi-dev libxkbcommon-dev libglu1-mesa-dev \
  libasound2-dev libpulse-dev libudev-dev libdbus-1-dev libssl-dev zlib1g-dev \
  uuid-dev libbz2-dev libicu-dev libsdl2-dev python3 python3-pip
echo "APT_RC=$?"

########## 4. Xorg config for the headless T4 ##########
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
mkdir -p /usr/lib/xorg/modules/extensions
ln -sf "/usr/lib64-nvidia/xorg/modules/extensions/libglxserver_nvidia.so.${KVER}" \
       /usr/lib/xorg/modules/extensions/libglxserver_nvidia.so
ldconfig
mknod /dev/uinput c 10 223 2>/dev/null; chmod 666 /dev/uinput 2>/dev/null
chown -R colab:colab /home/colab
echo "== STEP4 xorg conf done"

########## 5. RustDesk ##########
RD_URL=$(curl -sL https://api.github.com/repos/rustdesk/rustdesk/releases/latest \
  | grep -oE 'https://[^"]*rustdesk-[0-9.]+-x86_64\.deb' | head -1)
[ -z "$RD_URL" ] && RD_URL="https://github.com/rustdesk/rustdesk/releases/download/1.5.0/rustdesk-1.5.0-x86_64.deb"
curl -fsSL "$RD_URL" -o /tmp/rustdesk.deb && apt-get install -y /tmp/rustdesk.deb
echo "RUSTDESK_RC=$?"

########## 6. Firefox ##########
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg -o /etc/apt/keyrings/packages.mozilla.org.asc
echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
  > /etc/apt/sources.list.d/mozilla.list
printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' > /etc/apt/preferences.d/mozilla
apt-get update -y && apt-get install -y firefox
echo "FIREFOX_RC=$?"

########## 7. dotnet SDK (UBT runtime) ##########
curl -fsSL https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb -o /tmp/pmp.deb \
  && dpkg -i /tmp/pmp.deb && apt-get update -y && apt-get install -y dotnet-sdk-10.0
/usr/bin/dotnet --version
echo "DOTNET_RC=$?"

apt-get clean; rm -rf /var/lib/apt/lists/* /root/.cache
echo "PROV_ALL_DONE $(date -u)  free=$(df -h / | tail -1 | awk '{print $4}')"
