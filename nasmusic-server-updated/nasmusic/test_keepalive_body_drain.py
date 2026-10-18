"""Keep-alive body drain (2026-10-18: every 429 paired 1-for-1 with
`400 Bad request version ('completed","av":"1.0.316"}')`).

_dispatch rejected _client_log with 429 (and 401 for anything gated) BEFORE
reading the body, so the unread JSON stayed in the socket and
BaseHTTPRequestHandler parsed it as the next request line. _dispatch now
resets _body_raw/_body_cap and drains centrally, before any early return.

Drives a real Handler over a socket.socketpair(): request 1 = POST /staging/
api/client-log with a JSON body, no token -> 401; request 2 = GET
/staging/healthz (200 {"ok": true} *before* the gate) on the SAME handler.
Run: python3 -m unittest nasmusic.test_keepalive_body_drain -v
"""
import socket
import types
import unittest


# tail matches the production error: Bad request version ('"1.0.316"}')
BODY = (b'{"kind":"timeout","message":"GET /staging/api/innas: '
        b'TimeoutException","av":"1.0.316"}')


def _wire(req):
    head = ("%s HTTP/1.1\r\nHost: nas\r\nConnection: keep-alive\r\n"
            % req[0]).encode()
    if len(req) > 1:
        head += (b"Content-Type: application/json\r\nContent-Length: %d\r\n"
                 % len(req[1]))
    return head + b"\r\n" + (req[1] if len(req) > 1 else b"")


class KeepAliveBodyDrainTest(unittest.TestCase):
    def test_rejected_body_does_not_desync_next_request(self):
        from . import httpd as _h
        hsock, csock = socket.socketpair()
        csock.settimeout(10)                       # never hang the suite
        try:
            csock.sendall(_wire(("POST /staging/api/client-log", BODY))
                          + _wire(("GET /staging/healthz",)))
            h = _h.Handler.__new__(_h.Handler)     # no __init__: no server loop
            h.request = hsock
            h.client_address = ("127.0.0.1", 0)
            h.server = types.SimpleNamespace()      # neither route touches state
            h.setup()
            h.handle_one_request()                  # 401, body must be drained
            h.handle_one_request()                  # must parse as a real request
            # The handler writes into the CLIENT socket's recv queue, so the
            # response is read from csock, not hsock. Half-close the handler
            # end so the drain below sees EOF; close() would RST (Linux
            # discards queued data) and hide the response entirely.
            hsock.shutdown(socket.SHUT_WR)
            resp = b""
            while True:
                chunk = csock.recv(65536)
                if not chunk:
                    break
                resp += chunk
        finally:
            hsock.close()
            csock.close()
        self.assertIn(b"HTTP/1.1 401", resp)
        self.assertNotIn(b"Bad request version", resp)
        self.assertIn(b"HTTP/1.1 200 OK", resp)
        self.assertIn(b'{"ok": true}', resp)


if __name__ == "__main__":
    unittest.main()