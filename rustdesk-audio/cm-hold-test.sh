#!/bin/bash
# Test whether keeping a client on the `_cm` IPC socket keeps the CM alive.
set -u
export DISPLAY=:20 XAUTHORITY=/root/.Xauthority XDG_RUNTIME_DIR=/tmp/runtime-root

pkill -f 'rustdesk --help' 2>/dev/null
pkill -f 'rustdesk --cm' 2>/dev/null
sleep 1
rm -f /tmp/RustDesk-0/ipc_cm /tmp/RustDesk-0/ipc_pa /tmp/RustDesk-0/ipc_cm.pid /tmp/RustDesk-0/ipc_pa.pid

cd /root
setsid nohup /usr/bin/rustdesk --cm </dev/null >>/tmp/gpu-desk/rd-cm.log 2>&1 &
echo "started cm; waiting for socket..."
for i in $(seq 1 20); do [ -S /tmp/RustDesk-0/ipc_cm ] && break; sleep 0.5; done
ls -l /tmp/RustDesk-0/ipc_cm /tmp/RustDesk-0/ipc_pa 2>&1 | tail -2

# hold the socket open for 45s
python3 - <<'PY' &
import socket, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.connect("/tmp/RustDesk-0/ipc_cm")
    print("holder: connected")
    time.sleep(45)
    print("holder: releasing")
except Exception as e:
    print("holder: failed", e)
finally:
    s.close()
PY
HOLDER=$!
for t in 5 15 30 45; do
  sleep $((t==5?5:(t==15?10:(t==30?15:15))))
  n=$(pgrep -c -f 'rustdesk --cm')
  echo "t=${t}s cm_procs=$n"
done
wait $HOLDER 2>/dev/null
sleep 3
echo "after release: cm_procs=$(pgrep -c -f 'rustdesk --cm')"
