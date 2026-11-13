#!/bin/bash
# audio-setup.sh — give the headless Colab desktop working sound.
# No /dev/snd exists, so we run a system-wide PulseAudio with a null sink
# ("Dummy Output"). Both root (the RustDesk peer) and colab (the desktop apps)
# reach the same daemon through an anonymous local socket, so no group /
# session restart is needed. Writes only NEW files; never edits packaged ones.
set -u

SPA=/etc/pulse/system-colab.pa
SOCK=/run/pulse/native

echo "== 1. directories"
mkdir -p /run/pulse /var/lib/pulse
chown -R pulse:pulse /run/pulse /var/lib/pulse 2>/dev/null
chmod 755 /run/pulse

echo "== 2. daemon config (new file, packaged system.pa untouched)"
cat > "$SPA" <<'EOF'
# Colab headless audio: null sink + anonymous local access.
load-module module-native-protocol-unix auth-anonymous=1 socket=/run/pulse/native
load-module module-null-sink sink_name=DummyOutput sink_properties=device.description="Dummy_Output"
load-module module-always-sink
set-default-sink DummyOutput
set-default-source DummyOutput.monitor
EOF
cat "$SPA"

echo "== 2b. ALSA -> PulseAudio routing (only if /etc/asound.conf is absent)"
if [ ! -e /etc/asound.conf ]; then
  cat > /etc/asound.conf <<'AEOF'
pcm.!default {
    type pulse
}
ctl.!default {
    type pulse
}
AEOF
  echo "wrote new /etc/asound.conf"
else
  echo "/etc/asound.conf already exists (left untouched)"
fi

echo "== 3. (re)start system daemon"
pkill -x pulseaudio 2>/dev/null
sleep 1
pulseaudio --system --daemonize=yes --disallow-exit --exit-idle-time=-1 -n -F "$SPA" 2>&1 | tail -3
sleep 3
pgrep -ax pulseaudio | head -2

echo "== 4. verify (root)"
pactl info 2>&1 | grep -E 'Server Name|Default Sink|Default Source'
pactl list short sinks

echo "== 5. verify (colab, no env tweaks)"
su - colab -c "pactl info 2>&1 | grep -E 'Server Name|Default Sink'" 2>&1 | tail -3

echo "== 6. test tone + capture proof"
python3 - <<'PY'
import wave, math, struct
r=44100; dur=2
with wave.open('/tmp/testtone.wav','w') as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(r)
    w.writeframes(b''.join(struct.pack('<hh', int(12000*math.sin(2*math.pi*440*i/r)), int(12000*math.sin(2*math.pi*440*i/r))) for i in range(r*dur)))
print('wrote /tmp/testtone.wav')
PY
( timeout 6 parec --device=DummyOutput.monitor --format=s16le --rate=44100 --channels=2 > /tmp/cap.raw & ) ; sleep 1
su - colab -c "timeout 20 paplay /tmp/testtone.wav" 2>&1 | tail -2; echo "paplay rc=$?"
sleep 6
echo "captured bytes: $(stat -c%s /tmp/cap.raw 2>/dev/null)"
python3 -c "
d=open('/tmp/cap.raw','rb').read()
print('peak amplitude:', max((int.from_bytes(d[i:i+2],'little',signed=True) for i in range(0,len(d)-1,64)), default=0))"
