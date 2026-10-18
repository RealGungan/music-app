"""HTTP body drain + listen backlog (keep-alive socket desync guard).

`_dispatch` drains the body centrally via `Handler._read_body(cap=...)`:
an unread body makes BaseHTTPRequestHandler parse the leftover JSON as
the next request line. A declared Content-Length over the cap reads
NOTHING, so a hostile client cannot make the server buffer megabytes.

Run: python3 -m unittest nasmusic.test_httpd_body_drain -v
"""
import unittest


class _FakeRfile:
    """Records every read size it is asked for."""

    def __init__(self, payload=b""):
        self.payload = payload
        self.reads = []

    def read(self, n):
        self.reads.append(n)
        data, self.payload = self.payload[:n], self.payload[n:]
        return data


def _handler(length, payload=b""):
    from . import httpd as _h
    h = _h.Handler.__new__(_h.Handler)
    h.headers = {"Content-Length": str(length)}
    h.rfile = _FakeRfile(payload)
    h._body_raw = None
    h._body_cap = 0
    return h


class BodyDrainTest(unittest.TestCase):
    def test_request_queue_size(self):
        from . import httpd as _h
        self.assertGreaterEqual(_h.NASMusicServer.request_queue_size, 128)

    def test_cap_enforced(self):
        from . import httpd as _h
        cap = _h.MAX_JSON_BODY

        # exact declared length -> read exactly that much, once
        h = _handler(100, b"x" * 100)
        self.assertEqual(h._read_body(), b"x" * 100)
        self.assertEqual(h.rfile.reads, [100])
        # idempotent: a second call must not re-read the socket
        self.assertEqual(h._read_body(), b"x" * 100)
        self.assertEqual(h.rfile.reads, [100])

        # over the cap -> zero bytes read
        big = _handler(cap + 1, b"y" * 10)
        self.assertEqual(big._read_body(), b"")
        self.assertEqual(big.rfile.reads, [])

        # the cover-upload site raises the cap: reads what the default skipped
        big._read_body(5 * 1024 * 1024)
        self.assertEqual(big.rfile.reads, [cap + 1])


if __name__ == "__main__":
    unittest.main()