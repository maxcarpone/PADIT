# -*- coding: utf-8 -*-
"""CVE-2026-48804 regression test, Python 2.7 compatible."""
import socketio

s = socketio.Server(async_handlers=False)

try:
    s._handle_eio_message(
        '999',
        '52-["my message","a",'
        '{"_placeholder":true,"num":1},'
        '{"_placeholder":true,"num":0}]'
    )
except ValueError:
    pass
else:
    raise AssertionError("Unknown binary client was accepted")

assert '999' not in s._binary_packet
print("[PASS] Unauthenticated binary packet rejected")

s = socketio.Server(async_handlers=False)
s.manager.connect('123', '/')
s.environ['123'] = {}

s._handle_eio_message(
    '123',
    '52-["my message","a",'
    '{"_placeholder":true,"num":1},'
    '{"_placeholder":true,"num":0}]'
)

s._handle_eio_message('123', b'foo')
assert '123' in s._binary_packet

s._handle_eio_disconnect('123')
assert '123' not in s._binary_packet

print("[PASS] Incomplete binary packet cleared on disconnect")
print("CVE-2026-48804 REGRESSION TEST: 2/2 PASS")
