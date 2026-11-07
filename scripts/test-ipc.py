"""Exercise the packaged helper and its private stdin/stdout IPC contract."""
import json
import socket
import subprocess
import sys
import threading
import unittest
from pathlib import Path

HELPER = Path(sys.argv.pop(1) if len(sys.argv) > 1 else "target/release/pofig-proxy").resolve()


def start(**changes):
    request = dict(command="serve", protocol="http", host="127.0.0.1", port=18080, username="", password="")
    request.update(changes)
    child = subprocess.Popen([str(HELPER)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    child.stdin.write((json.dumps(request) + "\n").encode())
    child.stdin.flush()
    return child


class IPC(unittest.TestCase):
    def test_parent_pipe_closure_stops_helper_and_listener(self):
        child = start()
        try:
            event = json.loads(child.stdout.readline())
            self.assertEqual(event["event"], "ready")
            self.assertEqual(event["host"], "127.0.0.1")
            port = event["port"]
            child.stdin.close()
            self.assertEqual(child.wait(timeout=5), 0)
            with self.assertRaises(OSError):
                socket.create_connection(("127.0.0.1", port), timeout=0.2)
        finally:
            if child.poll() is None:
                child.kill()
            child.wait()
            child.stdout.close()
            child.stderr.close()

    def test_invalid_input_does_not_echo_credentials(self):
        child = start(command="unrecognized", username="user", password="must-never-appear-in-output")
        output, errors = child.communicate(timeout=5)
        self.assertEqual(child.returncode, 1)
        self.assertEqual(json.loads(output)["event"], "error")
        self.assertNotIn(b"must-never-appear-in-output", output + errors)

    def test_check_exits_on_auth_error_and_redacts_upstream_response(self):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        port = listener.getsockname()[1]

        def reject():
            with listener:
                connection, _ = listener.accept()
                with connection:
                    header = b""
                    while not header.endswith(b"\r\n\r\n"):
                        header += connection.recv(1)
                    connection.sendall(b"HTTP/1.1 407 Proxy Authentication Required\r\nX-Secret: upstream-secret\r\n\r\n")

        server = threading.Thread(target=reject, daemon=True)
        server.start()
        child = start(command="check", port=port, username="user", password="password")
        output, errors = child.communicate(timeout=5)
        event = json.loads(output)
        self.assertEqual(child.returncode, 1)
        self.assertEqual(event["code"], "auth")
        self.assertNotIn(b"upstream-secret", output + errors)
        self.assertNotIn(b"password", output + errors)
        server.join(timeout=2)
        self.assertFalse(server.is_alive())

    def test_oversized_record_is_rejected(self):
        child = start(host="a" * 20000)
        output, _ = child.communicate(timeout=5)
        self.assertEqual(child.returncode, 1)
        self.assertEqual(json.loads(output)["code"], "input")


if __name__ == "__main__":
    unittest.main()
