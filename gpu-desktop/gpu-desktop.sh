#!/bin/bash
# gpu-desktop.sh - headless NVIDIA-accelerated X desktop (Tesla T4) + VNC bridge for xrdp
#
#   start | stop | restart | status
#
# X display :20 (Xorg + NVIDIA DDX), XFCE session, x11vnc on 127.0.0.1:5910
# xrdp session "GPU-XFCE" (in /etc/xrdp/xrdp.ini) bridges RDP -> this VNC port.
#
# Run as user "colab" (X servers / VNC run as colab). Root is only needed once,
# to provision the driver (see gpu-desktop-provision.sh).

XDISPLAY="${GPU_DISPLAY:-:20}"
VNCPORT="${GPU_VNC_PORT:-5910}"
VNCPASS_FILE="${VNC_PASS_FILE:-/home/colab/.vnc_passwd}"
RUN="/tmp/gpu-desk"
LOGS="/tmp/gpu-desk"
XORG_CONF="/etc/X11/xorg-gpu.conf"
MODULEPATH="/usr/lib/x86_64-linux-gnu/nvidia/xorg,/usr/lib/xorg/modules"
XAUTH="${XAUTHORITY:-/home/colab/.Xauthority}"

export DISPLAY="$XDISPLAY"

msg() { echo "[gpu-desktop] $*"; }

env_has() { # $1=pid $2=VAR=VAL
    [ -r "/proc/$1/environ" ] && tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null | grep -qxF "$2"
}

xorg_pid() { pgrep -x Xorg -a 2>/dev/null | awk -v d="$XDISPLAY" '$3==d {print $1}'; }

xfce_pid() {
    for p in $(pgrep -x xfce4-session 2>/dev/null); do
        env_has "$p" "DISPLAY=$XDISPLAY" && { echo "$p"; return; }
    done
}

x11vnc_pid() {
    pgrep -x x11vnc -a 2>/dev/null | grep -F -- "-display $XDISPLAY" | awk '{print $1}'
}

start() {
    mkdir -p "$RUN" "$LOGS"
    [ -f "$XORG_CONF" ] || { msg "ERROR: $XORG_CONF missing - run gpu-desktop-provision.sh as root"; return 1; }

    # --- X server ---------------------------------------------------------
    if [ -n "$(xorg_pid)" ]; then
        msg "Xorg $XDISPLAY already running (pid $(xorg_pid))"
    else
        xauth -f "$XAUTH" list 2>/dev/null | grep -q "unix${XDISPLAY}[[:space:]]" || \
            xauth -f "$XAUTH" add "$XDISPLAY" . "$(mcookie)"
        msg "starting Xorg $XDISPLAY (nvidia, headless)"
        nohup /usr/lib/xorg/Xorg "$XDISPLAY" \
            -config "$XORG_CONF" -modulepath "$MODULEPATH" \
            -auth "$XAUTH" -noreset -nolisten tcp \
            -logfile "$LOGS/Xorg${XDISPLAY}.log" > "$LOGS/xorg.out" 2>&1 &
        for i in $(seq 1 25); do
            xdpyinfo -display "$XDISPLAY" >/dev/null 2>&1 && break
            sleep 1
        done
    fi
    if ! xdpyinfo -display "$XDISPLAY" >/dev/null 2>&1; then
        msg "ERROR: X server did not come up - see $LOGS/Xorg${XDISPLAY}.log"; return 1
    fi
    msg "X screen: $(xdpyinfo -display "$XDISPLAY" | awk '/dimensions/{print $2}')"

    # --- XFCE session -----------------------------------------------------
    if [ -n "$(xfce_pid)" ]; then
        msg "XFCE session on $XDISPLAY already running (pid $(xfce_pid))"
    else
        msg "starting XFCE on $XDISPLAY"
        # setsid = new session, no controlling TTY: survives SSH/pty close (SIGHUP)
        if [ -x /home/colab/start-xfce.sh ]; then
            setsid nohup /home/colab/start-xfce.sh \
                </dev/null > "$LOGS/xfce.log" 2>&1 &
        else
            (
              export XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_TYPE=x11
              export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-colab}"
              mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
              setsid nohup dbus-launch --exit-with-session startxfce4 \
                  </dev/null > "$LOGS/xfce.log" 2>&1 &
            )
        fi
        sleep 6
    fi

    # --- VNC bridge -------------------------------------------------------
    if [ -n "$(x11vnc_pid)" ]; then
        msg "x11vnc already running (pid $(x11vnc_pid))"
    else
        if [ ! -f "$VNCPASS_FILE" ]; then
            if [ -n "${VNC_PASSWORD:-}" ]; then
                x11vnc -storepasswd "$VNC_PASSWORD" "$VNCPASS_FILE" >/dev/null 2>&1
            else
                msg "NOTE: $VNCPASS_FILE missing and VNC_PASSWORD unset; skipping x11vnc (not needed for RustDesk)"
                status; return 0
            fi
        fi
        msg "starting x11vnc on 127.0.0.1:$VNCPORT"
        x11vnc -display "$XDISPLAY" -rfbport "$VNCPORT" -localhost -forever -shared \
               -rfbauth "$VNCPASS_FILE" -quiet -o "$LOGS/x11vnc.log" -bg
        sleep 2
    fi

    status
}

stop() {
    p=$(xfce_pid); [ -n "$p" ] && { msg "stopping XFCE (pid $p)"; kill "$p" 2>/dev/null; }
    p=$(x11vnc_pid); [ -n "$p" ] && { msg "stopping x11vnc (pid $p)"; kill "$p" 2>/dev/null; }
    p=$(xorg_pid); [ -n "$p" ] && { msg "stopping Xorg $XDISPLAY (pid $p)"; kill "$p" 2>/dev/null; }
    sleep 2
    msg "stopped"
}

status() {
    echo "---- GPU desktop status ----"
    echo "display        : $XDISPLAY"
    echo "Xorg pid       : $(xorg_pid)"
    echo "XFCE pid       : $(xfce_pid)"
    echo "x11vnc pid     : $(x11vnc_pid)"
    if xdpyinfo -display "$XDISPLAY" >/dev/null 2>&1; then
        echo "screen size    : $(xdpyinfo -display "$XDISPLAY" | awk '/dimensions/{print $2}')"
        renderer=$(glxinfo -B 2>/dev/null | awk -F': ' '/OpenGL renderer/{print $2}')
        echo "GL renderer    : ${renderer:-<glxinfo missing>}"
        echo "direct render  : $(glxinfo -B 2>/dev/null | awk -F': ' '/direct rendering/{print $2}')"
    fi
    echo "VNC            : 127.0.0.1:$VNCPORT (auth file: $VNCPASS_FILE, localhost only)"
    echo "RDP            : port 3389 -> session 'GPU-XFCE (NVIDIA T4)'"
    echo "GPU processes  :"
    nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader 2>/dev/null | sed 's/^/    compute /'
    nvidia-smi 2>/dev/null | sed -n '/Processes/,$p' | grep -E "\bC\b|\bG\b" | sed 's/^/    /'
}

case "${1:-status}" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; start ;;
    status)  status ;;
    *) echo "usage: $0 {start|stop|restart|status}"; exit 1 ;;
esac
