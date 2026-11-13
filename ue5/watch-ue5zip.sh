#!/bin/bash
# watch-ue5zip.sh — as colab: wait for a UE Linux zip to finish downloading, then install.
# Detects ANY name matching Linux_Unreal_Engine*.zip in ~/Downloads.
LOG=/tmp/ue5_watch2.log
log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }
log "watcher v2 started"
done_flag=0
while [ "$done_flag" -eq 0 ]; do
  Z=$(ls -S /home/colab/Downloads/Linux_Unreal_Engine*.zip 2>/dev/null | head -1)
  if [ -n "${Z:-}" ]; then
    sz=$(stat -c %s "$Z" 2>/dev/null || echo 0)
    if [ "$sz" -gt 20000000000 ]; then
      # stable across 3 samples AND readable central directory => complete
      a=$sz; sleep 30
      b=$(stat -c %s "$Z" 2>/dev/null || echo 0); sleep 30
      c=$(stat -c %s "$Z" 2>/dev/null || echo 0)
      if [ "$a" = "$b" ] && [ "$b" = "$c" ]; then
        if unzip -l "$Z" >/dev/null 2>&1; then
          log "zip complete: $Z ($((sz/1048576)) MiB) -> installing"
          bash /home/colab/install-ue5-full.sh "$Z" >>"$LOG" 2>&1
          log "installer rc=$?"
          done_flag=1
        else
          log "$(basename "$Z") size stable but archive unreadable - waiting"
        fi
      else
        log "$(basename "$Z") still growing: $((sz/1048576)) MiB"
      fi
    fi
  fi
  sleep 30
done
