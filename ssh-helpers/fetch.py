#!/usr/bin/env python3
"""Download a remote file from the box over SFTP.

Usage: BORE_PORT=... SSH_PASSWORD=... python3 fetch.py <remote_path> <local_path>
"""
import os
import sys
import paramiko


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: fetch.py <remote_path> <local_path>")
    host = os.environ.get("BORE_HOST", "bore.pub")
    port = os.environ.get("BORE_PORT")
    user = os.environ.get("SSH_USER", "colab")
    pw = os.environ.get("SSH_PASSWORD")
    if not port or not pw:
        raise SystemExit("Set BORE_PORT and SSH_PASSWORD in the environment.")

    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(
        host,
        port=int(port),
        username=user,
        password=pw,
        timeout=20,
        allow_agent=False,
        look_for_keys=False,
    )
    s = c.open_sftp()
    s.get(sys.argv[1], sys.argv[2])
    s.close()
    c.close()
    print("fetched", sys.argv[1], "->", sys.argv[2])


if __name__ == "__main__":
    main()
