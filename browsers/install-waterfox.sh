#!/bin/bash
# install-waterfox.sh — install Waterfox from the official BrowserWorks apt repo.
# Ubuntu 24.04 (noble) -> xUbuntu_24.04. Idempotent: safe to re-run.
set -u

SUITE="${SUITE:-xUbuntu_24.04}"
REPO="https://download.opensuse.org/repositories/isv:/BrowserWorks/${SUITE}/"
KEYRING=/usr/share/keyrings/waterfox.gpg
LISTF=/etc/apt/sources.list.d/waterfox.list

echo "== 1. signing key (fingerprint CA48 C43A 22BC D3F4 7813 F9FF D89C AAE3 9D6F 4771)"
curl -fsSL --retry 3 --max-time 60 "${REPO}Release.key" | gpg --dearmor > "$KEYRING" || {
  echo "FAIL: could not fetch Release.key"; exit 1; }
chmod 644 "$KEYRING"
FPR=$(gpg --show-keys --with-colons "$KEYRING" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')
echo "key fpr: $FPR"

echo "== 2. apt source"
echo "deb [signed-by=$KEYRING] $REPO /" > "$LISTF"
echo "wrote $LISTF"

echo "== 3. apt update"
export DEBIAN_FRONTEND=noninteractive
apt-get update -o Acquire::Retries=3 2>&1 | tail -4

echo "== 4. install"
apt-get install -y --no-install-recommends waterfox 2>&1 | tail -6

echo "== 5. verify"
command -v waterfox
waterfox --version 2>&1 | head -1
dpkg-query -W -f='${Package} ${Version}\n' waterfox 2>/dev/null
ls -l /usr/bin/waterfox 2>/dev/null

echo "== 6. downloads dir for colab"
mkdir -p /home/colab/Downloads && chown -R colab:colab /home/colab/Downloads && echo ok
