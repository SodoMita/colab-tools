#!/usr/bin/env python3
"""Run a command as SSH_USER on a Colab/remote box behind an SSH tunnel (e.g. bore.pub).

Required env:
  BORE_PORT     remote SSH port
  SSH_PASSWORD  SSH password for SSH_USER

Optional env:
  BORE_HOST     default: bore.pub
  SSH_USER      default: colab
"""
import base64
import os
import socket
import sys
import time
import paramiko


def _cfg():
    host = os.environ.get("BORE_HOST", "bore.pub")
    port = os.environ.get("BORE_PORT")
    user = os.environ.get("SSH_USER", "colab")
    pw = os.environ.get("SSH_PASSWORD")
    if not port or not pw:
        raise SystemExit("Set BORE_PORT and SSH_PASSWORD in the environment.")
    return host, int(port), user, pw


def get_client():
    host, port, user, pw = _cfg()
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(
        host,
        port=port,
        username=user,
        password=pw,
        timeout=20,
        banner_timeout=30,
        auth_timeout=30,
        allow_agent=False,
        look_for_keys=False,
    )
    return c


def run(cmd, timeout=120, quiet=False):
    c = get_client()
    tr = c.get_transport()
    tr.set_keepalive(15)
    chan = tr.open_session()
    chan.settimeout(timeout)
    chan.get_pty()
    if "\n" in cmd.strip():
        tag = os.urandom(3).hex()
        script_path = f"/tmp/_rs_{tag}.sh"
        payload = base64.b64encode(cmd.encode()).decode()
        cmd = (
            f"printf %s {payload} | base64 -d > {script_path}; bash {script_path}; "
            f"rc=$?; rm -f {script_path}; exit $rc"
        )
    chan.exec_command(cmd)
    out = b""
    try:
        while True:
            if chan.recv_ready():
                data = chan.recv(65536)
                if not data:
                    break
                out += data
                if not quiet:
                    sys.stdout.buffer.write(data)
                    sys.stdout.flush()
            elif chan.exit_status_ready() and not chan.recv_ready():
                break
            else:
                time.sleep(0.05)
        while chan.recv_ready():
            data = chan.recv(65536)
            if not data:
                break
            out += data
            if not quiet:
                sys.stdout.buffer.write(data)
    except socket.timeout:
        out += b"\n[REMOTE TIMEOUT]\n"
    rc = chan.recv_exit_status() if chan.exit_status_ready() else None
    c.close()
    return rc, out.decode(errors="replace")


if __name__ == "__main__":
    cmd = sys.argv[1] if (len(sys.argv) > 1 and sys.argv[1] != "-") else sys.stdin.read()
    rc, _ = run(cmd)
    print(f"\n[rc={rc}]")
