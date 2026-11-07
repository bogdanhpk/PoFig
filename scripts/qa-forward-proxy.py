"""Temporary loopback-only forwarding proxy for manual Figma integration QA.

Records aggregate destination counts only. It does not read encrypted traffic.
Run with a path to a JSON statistics file; stop with Ctrl-C after QA.
"""
import collections
import json
import selectors
import socket
import socketserver
import sys
import threading
from pathlib import Path

stats_path = Path(sys.argv[1])
lock = threading.Lock()
counts = collections.Counter()
state = {}


def record(host, connected):
    with lock:
        counts[host + (" (connected)" if connected else " (failed)")] += 1
        state["destinations"] = dict(counts)
        temporary = stats_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(state, indent=2))
        temporary.replace(stats_path)


class Proxy(socketserver.BaseRequestHandler):
    def handle(self):
        client = self.request
        client.settimeout(20)
        header = b""
        try:
            while not header.endswith(b"\r\n\r\n") and len(header) < 32768:
                data = client.recv(1)
                if not data:
                    return
                header += data
            method, target, _ = header.split(b"\r\n", 1)[0].decode().split(" ")
            if method != "CONNECT":
                client.sendall(b"HTTP/1.1 405 Method Not Allowed\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
                return
            host, port = target.rsplit(":", 1)
            host = host.strip("[]")
            try:
                remote = socket.create_connection((host, int(port)), timeout=15)
            except OSError:
                record(host, False)
                client.sendall(b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
                return
            record(host, True)
            with remote, selectors.DefaultSelector() as selector:
                client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                client.settimeout(None)
                remote.settimeout(None)
                selector.register(client, selectors.EVENT_READ, remote)
                selector.register(remote, selectors.EVENT_READ, client)
                while selector.get_map():
                    for key, _ in selector.select(timeout=30):
                        data = key.fileobj.recv(65536)
                        if data:
                            key.data.sendall(data)
                        else:
                            selector.unregister(key.fileobj)
                            try:
                                key.data.shutdown(socket.SHUT_WR)
                            except OSError:
                                pass
        except (OSError, ValueError, UnicodeError):
            return


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True


with Server(("127.0.0.1", 0), Proxy) as server:
    state["port"] = server.server_address[1]
    stats_path.parent.mkdir(parents=True, exist_ok=True)
    stats_path.write_text(json.dumps(state))
    print(json.dumps(state), flush=True)
    server.serve_forever()
