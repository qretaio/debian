#!/usr/bin/env python3
# libkrun exposes host socket -> guest AF_VSOCK port 2222. This bridge
# accepts vsock connections and forwards them to sshd on the GUEST's
# 127.0.0.1:2222. The guest TCP port is fine; only the HOST is kept free of
# TCP listeners (TSI inet hijack is off for the dev box).
import socket
import threading

VSOCK_PORT = 2222
SSHD = ("127.0.0.1", 2222)


def pump(a, b):
    try:
        while True:
            data = a.recv(65536)
            if not data:
                break
            b.sendall(data)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            s.close()


def handle(v):
    try:
        t = socket.create_connection(SSHD, timeout=10)
    except OSError:
        v.close()
        return
    threading.Thread(target=pump, args=(v, t), daemon=True).start()
    pump(t, v)


def main():
    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    s.bind((socket.VMADDR_CID_ANY, VSOCK_PORT))
    s.listen(16)
    while True:
        v, _ = s.accept()
        threading.Thread(target=handle, args=(v,), daemon=True).start()


if __name__ == "__main__":
    main()
