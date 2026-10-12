# coding: utf-8
import pytest
import ujson


@pytest.mark.parametrize("data", [
    "\xc2A",             # Invalid 2-byte continuation
    "\xe2\x82A",         # Invalid 3-byte continuation
    "\xf0\x90\x80A",     # Invalid 4-byte continuation
    "\xf4\x90\x80\x80", # Above U+10FFFF
    "\xf5\x80\x80\x80", # Invalid leading code point
    "\xc2",              # Truncated 2-byte sequence
    "\xe2\x82",          # Truncated 3-byte sequence
    "\xf0\x90\x80",      # Truncated 4-byte sequence
])
def test_reject_invalid_utf8(data):
    with pytest.raises((ValueError, OverflowError)):
        ujson.dumps(data)


@pytest.mark.parametrize("data", [
    "\xc2\xa2",          # Cent sign
    "\xe2\x82\xac",     # Euro sign
    "\xf0\x9f\x98\x80", # Grinning face
])
def test_accept_valid_utf8(data):
    result = ujson.dumps(data)
    assert result

def test_dump_write_failure_refcount():
    import sys

    class FailingWriter(object):
        def write(self, data):
            raise IOError("simulated write failure")

    writer = FailingWriter()
    payload = [1, 2, 3]

    before = sys.getrefcount(writer)

    for _ in range(1000):
        with pytest.raises(IOError):
            ujson.dump(payload, writer)

    after = sys.getrefcount(writer)
    assert after == before
