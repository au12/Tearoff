#!/usr/bin/env python3
"""A pretend network Zebra: listens on 127.0.0.1:9100 and saves each job to OUT/job-N.zpl.
Answers ~HS and ~HI like a GX420d so status/identity code can be exercised too."""
import os
import socket
import sys
import threading

OUT = sys.argv[1] if len(sys.argv) > 1 else "cups-out"
os.makedirs(OUT, exist_ok=True)
STATUS = b"\x02030,0,0,1218,000,0,0,0,000,0,0,0\x03\r\n\x02000,0,0,0,0,2,6,0,00000000,1,000\x03\r\n\x021234,0\x03\r\n"
IDENT = b"\x02GX420d-200dpi,V61.17.17Z,8,8192KB\x03\r\n"
count = 0
lock = threading.Lock()


def handle(conn):
    global count
    data = b""
    conn.settimeout(3)
    try:
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                break
            data += chunk
            if data.strip() == b"~HS":
                conn.sendall(STATUS)
            elif data.strip() == b"~HI":
                conn.sendall(IDENT)
    except socket.timeout:
        pass
    finally:
        conn.close()
    if data.strip() in (b"~HS", b"~HI", b""):
        return
    with lock:
        count += 1
        n = count
    with open(os.path.join(OUT, f"job-{n}.zpl"), "wb") as f:
        f.write(data)
    print(f"fake zebra: job {n}, {len(data)} bytes", flush=True)


def main():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 9100))
    s.listen(8)
    print("fake zebra listening on 127.0.0.1:9100", flush=True)
    while True:
        conn, _ = s.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
