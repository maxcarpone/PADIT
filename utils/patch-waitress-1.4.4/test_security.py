# -*- coding: utf-8 -*-
"""PADIT W20: waitress 1.4.4 security regression tests.

CVE-2022-24761: strict Content-Length and chunked parsing.
CVE-2024-49769: socket lifecycle and premature disconnect.
Compatible with Python 2.7 and Python 3.
"""

import socket

from waitress.adjustments import Adjustments
from waitress.buffers import OverflowableBuffer
from waitress.parser import HTTPRequestParser
from waitress.receiver import ChunkedReceiver
from waitress import wasyncore
from waitress.channel import HTTPChannel


def check(name, actual, expected):
    if actual != expected:
        raise AssertionError(
            "%s: actual=%r expected=%r" % (name, actual, expected)
        )
    print("[PASS] " + name)


def test_http():
    cases = (
        ("123", True),
        ("000123", True),
        ("+123", False),
        ("-1", False),
        ("0x10", False),
        ("", False),
    )

    for value, expected in cases:
        parser = HTTPRequestParser(Adjustments())
        data = (
            "POST / HTTP/1.1\r\n"
            "Host: localhost\r\n"
            "Content-Length: %s\r\n\r\n"
        ) % value
        parser.received(data.encode("ascii"))
        check("Content-Length %r" % value, parser.error is None, expected)

    chunks = (
        ("valid-hex", b"1\r\nA\r\n0\r\n\r\n", True),
        ("valid-extension", b"1;foo=bar\r\nA\r\n0\r\n\r\n", True),
        ("valid-quoted", b'1;foo="hello world"\r\nA\r\n0\r\n\r\n', True),
        ("valid-multiple", b"1;foo=bar;baz=qux\r\nA\r\n0\r\n\r\n", True),
        ("plus-size", b"+1\r\nA\r\n0\r\n\r\n", False),
        ("leading-space", b" 1\r\nA\r\n0\r\n\r\n", False),
        ("invalid-extension", b"1;foo=bar baz\r\nA\r\n0\r\n\r\n", False),
        ("empty-extension", b"1;\r\nA\r\n0\r\n\r\n", False),
        ("non-hex-size", b"G\r\nA\r\n0\r\n\r\n", False),
        ("trailing-space", b"1 \r\nA\r\n0\r\n\r\n", False),
        ("escaped-quote", b'1;foo="a\\"b"\r\nA\r\n0\r\n\r\n', True),
        ("escaped-backslash", b'1;foo="a\\\\b"\r\nA\r\n0\r\n\r\n', True),
        ("empty-quoted", b'1;foo=""\r\nA\r\n0\r\n\r\n', True),
        ("empty-token", b"1;foo=\r\nA\r\n0\r\n\r\n", False),
        ("unterminated-quote", b'1;foo="abc\r\nA\r\n0\r\n\r\n', False),
        ("invalid-control", b'1;foo="a\x01b"\r\nA\r\n0\r\n\r\n', False),
        ("obs-text", b'1;foo="a\x80b"\r\nA\r\n0\r\n\r\n', True),
        ("escaped-obs-text", b'1;foo="a\\\x80b"\r\nA\r\n0\r\n\r\n', True),
        ("invalid-DEL", b'1;foo="a\x7fb"\r\nA\r\n0\r\n\r\n', False),
    )

    for name, payload, expected in chunks:
        receiver = ChunkedReceiver(OverflowableBuffer(1048576))
        receiver.received(payload)
        accepted = receiver.error is None and receiver.completed
        check(name, accepted, expected)



def make_socket_pair():
    """Return connected sockets on Unix and Windows Python 2.7."""
    if hasattr(socket, "socketpair"):
        return socket.socketpair()

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)

    client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        client.connect(listener.getsockname())
        server, address = listener.accept()
        return server, client
    except Exception:
        client.close()
        raise
    finally:
        listener.close()


class SocketProxy(object):
    def __init__(self, sock):
        self.sock = sock
        self.calls = 0

    def setblocking(self, value):
        return self.sock.setblocking(value)

    def fileno(self):
        return self.sock.fileno()

    def getpeername(self):
        self.calls += 1
        raise socket.error(9, "Unexpected getpeername call")

    def close(self):
        return self.sock.close()


class FakeServer(object):
    def __init__(self):
        self.active_channels = {}


def test_socket():
    left, right = make_socket_pair()
    channels = {}
    try:
        channel = HTTPChannel(
            FakeServer(), left, ("127.0.0.1", 12345),
            Adjustments(), map=channels
        )
        check("HTTPChannel connected", channel.connected, True)

        right.close()
        channel.will_close = True
        channel.handle_write()
        check("HTTPChannel socket released", channel.socket is None, True)

        channel.handle_write()
        check("HTTPChannel repeated write", channel.socket is None, True)
    finally:
        left.close()
        right.close()

    left, right = make_socket_pair()
    channels = {}
    try:
        dispatcher = wasyncore.dispatcher(left, map=channels)
        dispatcher.close()
        check("dispatcher socket released", dispatcher.socket is None, True)
        check("dispatcher unregistered", not channels, True)
        dispatcher.close()
        check("dispatcher repeated close", dispatcher.socket is None, True)
    finally:
        left.close()
        right.close()


def test_connection_regressions():
    # Exercise the TCP fallback also used on Windows Python 2.7.
    original_socketpair = getattr(socket, "socketpair", None)
    if original_socketpair is not None:
        del socket.socketpair

    try:
        left, right = make_socket_pair()
        try:
            check("TCP fallback connected", left.getpeername()[1] > 0, True)
        finally:
            left.close()
            right.close()
    finally:
        if original_socketpair is not None:
            socket.socketpair = original_socketpair

    # The corrected dispatcher must not call getpeername().
    left, right = make_socket_pair()
    channels = {}
    try:
        proxy = SocketProxy(left)
        dispatcher = wasyncore.dispatcher(proxy, map=channels)
        check("dispatcher getpeername calls", proxy.calls, 0)
        dispatcher.close()
        check("dispatcher proxy socket released", dispatcher.socket is None, True)
    finally:
        left.close()
        right.close()



if __name__ == "__main__":
    test_http()
    test_socket()
    test_connection_regressions()
    print("[PASS] PADIT W20 waitress security regression suite")
