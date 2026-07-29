#!/usr/bin/env python3
"""A minimal RFB 3.8 server that completes the handshake and then drops the
connection, to exercise Chicken's "connection terminated" paths without
needing a real VNC server.

    ./Tests/fake_vnc_server.py            # listen on 5999 (display 99), drop after handshake
    ./Tests/fake_vnc_server.py --hold 30  # stay connected 30s first
    ./Tests/fake_vnc_server.py --auth     # require VNC authentication (password: testpass)

Then connect Chicken to 127.0.0.1:5999. Once the desktop appears the server
closes the socket, which is what drives the terminated sheet and the reconnect
offer. Ctrl-C to stop.
"""

import argparse
import socket
import struct
import sys
import time

# Unbuffered, so progress is visible when the output is piped to a log.
try:
    sys.stdout.reconfigure(line_buffering=True)
except AttributeError:
    pass

DES_PASSWORD = b"testpass"


def serve_once(conn, args):
    # 1. ProtocolVersion, server -> client
    conn.sendall(b"RFB 003.008\n")
    client_version = conn.recv(12)
    print(f"  client version: {client_version!r}")

    # 2. Security types
    if args.auth:
        conn.sendall(bytes([1, 2]))          # 1 type: VNC authentication
        chosen = conn.recv(1)
        print(f"  chose security type {chosen[0] if chosen else '?'}")
        conn.sendall(b"\x00" * 16)           # 16-byte challenge
        conn.recv(16)                        # response; accept whatever arrives
        conn.sendall(struct.pack(">I", 0))   # SecurityResult: OK
    else:
        conn.sendall(bytes([1, 1]))          # 1 type: None
        chosen = conn.recv(1)
        print(f"  chose security type {chosen[0] if chosen else '?'}")
        conn.sendall(struct.pack(">I", 0))   # SecurityResult: OK

    # 3. ClientInit
    shared = conn.recv(1)
    print(f"  shared flag: {shared[0] if shared else '?'}")

    # 4. ServerInit: 1024x768, 32bpp true colour
    name = b"Fake VNC (drops on purpose)"
    pixel_format = struct.pack(
        ">BBBBHHHBBBxxx",
        32,     # bits per pixel
        24,     # depth
        0,      # big endian
        1,      # true colour
        255, 255, 255,   # max r,g,b
        16, 8, 0,        # shift r,g,b
    )
    conn.sendall(struct.pack(">HH", 1024, 768) + pixel_format
                 + struct.pack(">I", len(name)) + name)
    print("  handshake complete; desktop announced as 1024x768")

    if args.hold:
        print(f"  holding the connection open for {args.hold}s...")
        deadline = time.time() + args.hold
        conn.settimeout(0.5)
        while time.time() < deadline:
            try:
                if not conn.recv(4096):
                    print("  client hung up")
                    return
            except socket.timeout:
                pass
            except OSError:
                return

    print("  dropping the connection now -- expect the terminated sheet")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=5999)
    ap.add_argument("--hold", type=float, default=0,
                    help="seconds to stay connected before dropping")
    ap.add_argument("--auth", action="store_true",
                    help="require VNC authentication (any password is accepted)")
    args = ap.parse_args()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", args.port))
    srv.listen(5)
    print(f"listening on 127.0.0.1:{args.port} "
          f"(display {args.port - 5900}) -- Ctrl-C to stop")

    try:
        while True:
            conn, addr = srv.accept()
            print(f"connection from {addr}")
            try:
                serve_once(conn, args)
            except (OSError, struct.error) as exc:
                print(f"  connection error: {exc}")
            finally:
                conn.close()
    except KeyboardInterrupt:
        print("\nstopped")
    finally:
        srv.close()


if __name__ == "__main__":
    sys.exit(main())
