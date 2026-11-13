#!/usr/bin/env python3
"""Upload a local file to the remote box over SFTP.

Usage: BORE_PORT=... SSH_PASSWORD=... python3 upload.py <local> <remote> [octal_mode]
"""
import os
import sys
import paramiko


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: upload.py <local_path> <remote_path> [octal_mode]")
    local, remote = sys.argv[1], sys.argv[2]
    mode = int(sys.argv[3], 8) if len(sys.argv) > 3 else 0o644
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
    sftp = c.open_sftp()
    sftp.put(local, remote)
    sftp.chmod(remote, mode)
    st = sftp.stat(remote)
    print(f"uploaded {local} -> {remote} ({st.st_size} bytes, mode {oct(mode)})")
    with sftp.open(remote) as f:
        head = f.read(80)
    print("head:", head[:80])
    sftp.close()
    c.close()


if __name__ == "__main__":
    main()
