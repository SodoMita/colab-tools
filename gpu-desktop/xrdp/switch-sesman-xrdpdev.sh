#!/bin/bash
# steps/53: phase-2 video fix, ROOT part.
# 1) swap sesman [Xorg] param to the stock xrdp/xorg.conf (xrdpdev => frame transport)
# 2) restart sesman (safe: libvnc/3389 user session does not use sesman)
# 3) kill ONLY our dead-end leftovers: DISPLAY=:14 procs + Xorg :14 + local xfreerdp3 + glxgears
# NEVER touches :20, xfce, x11vnc, listeners 70734/73238/94796 or the user's 3389 session.
echo "=== baseline ==="
pgrep -f "[X]org :20" >/dev/null && echo ":20 Xorg ALIVE" || echo ":20 GONE!!!"
pgrep -x x11vnc >/dev/null && echo "x11vnc ALIVE" || echo "x11vnc GONE!!!"
ss -tn 2>/dev/null | grep -c ":3389" | xargs echo "conns on 3389 (user session!):"
echo "nproc=$(nproc)"

echo; echo "=== 1) sesman [Xorg] param -> xrdp/xorg.conf ==="
grep -m1 "param=xrdp/" /etc/xrdp/sesman.ini
cp /etc/xrdp/sesman.ini /etc/xrdp/sesman.ini.bak3.$(date +%s)
sed -i '/^\[Xorg\]/,/^\[/ s|^\([[:space:]]*\)param=xrdp/xorg_nvidia.conf|\1param=xrdp/xorg.conf|' /etc/xrdp/sesman.ini
grep -m1 "param=xrdp/" /etc/xrdp/sesman.ini

echo; echo "=== 2) restart sesman ==="
pkill -x xrdp-sesman; sleep 2
setsid nohup /usr/sbin/xrdp-sesman </dev/null >/dev/null 2>&1 &
sleep 2
pgrep -ax xrdp-sesman

echo; echo "=== 3) kill OUR leftovers only (:14 + local client + glxgears) ==="
pkill -x xfreerdp3 2>/dev/null; echo "xfreerdp3 killed rc=$?"
pkill -x glxgears 2>/dev/null; echo "glxgears killed rc=$?"
for p in $(ps -eo pid=); do
  if tr '\0' '\n' < /proc/$p/environ 2>/dev/null | grep -q '^DISPLAY=:14'; then
    kill $p 2>/dev/null; echo "killed $p ($(cat /proc/$p/comm 2>/dev/null))"
  fi
done
pkill -f "[X]org :14"
sleep 3
pgrep -f "[X]org :14" >/dev/null && echo "Xorg :14 STILL UP" || echo "Xorg :14 gone"

echo; echo "=== verify nothing user-facing was harmed ==="
pgrep -f "[X]org :20" >/dev/null && echo ":20 OK" || echo ":20 GONE!!!"
pgrep -x x11vnc >/dev/null && echo "x11vnc OK" || echo "x11vnc GONE!!!"
pgrep -f "[U]nrealEditor" >/dev/null && echo "user's UnrealEditor still running OK" || echo "UnrealEditor gone?!"
ps -eo pid,args | grep -E "[x]rdp -n|[x]rdp$" | head -5
echo "=== done ==="
