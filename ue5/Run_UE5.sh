#!/bin/bash
# UE5 launcher (fixed 2026-10-13): runs the editor on the GPU desktop :20.
# Changes vs original: VGL_DISPLAY=:0 removed; no vglrun wrapper.
# Unreal uses Vulkan on Linux, so VirtualGL's GLX interception is not needed --
# the editor renders directly on the NVIDIA-backed X server (:20). VirtualGL
# fallback is kept on a comment line if it is ever wanted.
export LD_LIBRARY_PATH=/usr/local/nvidia/lib:/usr/local/nvidia/lib64:/usr/lib64-nvidia:$LD_LIBRARY_PATH
export PATH=/usr/local/nvidia/bin:$PATH
export VK_ICD_FILENAMES=/etc/vulkan/icd.d/nvidia_icd.json
export DISPLAY=${DISPLAY:-:20}

UE=/home/colab/UE5/Engine/Binaries/Linux/UnrealEditor
if [ -x "$UE" ]; then
    # fallback if ever needed: VGL_DISPLAY=:20 /opt/VirtualGL/bin/vglrun "$UE"
    "$UE" "$@"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "UnrealEditor exited with code $rc."
        read -p "Press Enter to exit"
    fi
else
    echo "UnrealEditor not found in /home/colab/UE5/Engine/Binaries/Linux/."
    read -p "Press Enter to exit"
fi
