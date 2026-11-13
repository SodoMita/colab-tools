#!/usr/bin/env python3
"""Run a command as root via `su - root` over SSH.

Required env:
  BORE_PORT      remote SSH port
  SSH_PASSWORD   SSH password for SSH_USER

Optional env:
  BORE_HOST      default: bore.pub
  SSH_USER       default: colab
  ROOT_PASSWORD  default: same as SSH_PASSWORD
"""
import base64
import os
import sys
import time
import paramiko


def _cfg():
    host = os.environ.get("BORE_HOST", "bore.pub")
    port = os.environ.get("BORE_PORT")
    user = os.environ.get("SSH_USER", "colab")
    pw = os.environ.get("SSH_PASSWORD")
    root_pw = os.environ.get("ROOT_PASSWORD", pw)
    if not port or not pw:
        raise SystemExit("Set BORE_PORT and SSH_PASSWORD in the environment.")
    return host, int(port), user, pw, root_pw


def stream(chan, timeout):
    out = b""
    start = time.time()
    while True:
        if chan.recv_ready():
            d = chan.recv(65536)
            if not d:
                break
            out += d
            sys.stdout.buffer.write(d)
            sys.stdout.flush()
        elif chan.exit_status_ready() and not chan.recv_ready():
            break
        elif time.time() - start > timeout:
            out += b"\n[REMOTE TIMEOUT]\n"
            break
        else:
            time.sleep(0.05)
    return out


def run_root(cmd, timeout=600):
    host, port, user, pw, root_pw = _cfg()
    b64 = base64.b64encode(cmd.encode()).decode()
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(
        host,
        port=port,
        username=user,
        password=pw,
        timeout=20,
        allow_agent=False,
        look_for_keys=False,
    )
    tr = c.get_transport()
    chan = tr.open_session()
    chan.get_pty()
    chan.exec_command(f"su - root -c 'echo {b64} | base64 -d | bash'")
    time.sleep(1.5)
    buf = b""
    t0 = time.time()
    while b"assword" not in buf and time.time() - t0 < 15:
        if chan.recv_ready():
            buf += chan.recv(4096)
        else:
            time.sleep(0.1)
    chan.send(root_pw + "\n")
    out = stream(chan, timeout)
    c.close()
    return out.decode(errors="replace")


if __name__ == "__main__":
    cmd = sys.argv[1] if (len(sys.argv) > 1 and sys.argv[1] != "-") else sys.stdin.read()
    run_root(cmd)
