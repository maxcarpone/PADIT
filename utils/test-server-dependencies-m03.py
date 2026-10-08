#!/usr/bin/env python2
# -*- coding: utf-8 -*-
from __future__ import print_function

import os
import sys
from datetime import datetime

import pytz
import future
import wakeonlan
from future.utils import PY2
from builtins import str as future_str

print("=== PADIT SERVER DEPENDENCIES M03 ===")

assert sys.version_info[:2] == (2, 7)
assert pytz.__version__ == "2026.5"
assert future.__version__ == "1.0.0"
assert PY2

# Timezone and daylight saving time
paris = pytz.timezone("Europe/Paris")
winter = paris.localize(datetime(2026, 1, 15, 12, 0))
summer = paris.localize(datetime(2026, 7, 15, 12, 0))

assert winter.utcoffset().total_seconds() == 3600
assert summer.utcoffset().total_seconds() == 7200
print("PYTZ: PASS")

# Python 2 compatibility
assert future_str(u"PADIT") == u"PADIT"
print("FUTURE: PASS")

# Validate server-compatible WOL API
assert callable(wakeonlan.send_magic_packet)
assert len(wakeonlan.create_magic_packet(
    "00:11:22:33:44:55")) == 102

captures = []

class FakeSocket(object):
    def __init__(self, *args, **kwargs):
        self.destination = None
        self.packets = []

    def setsockopt(self, *args):
        pass

    def connect(self, destination):
        self.destination = destination

    def send(self, packet):
        self.packets.append(packet)
        return len(packet)

    def close(self):
        captures.append((self.destination, self.packets))

original_socket = wakeonlan.socket.socket

try:
    wakeonlan.socket.socket = FakeSocket

    wakeonlan.send_magic_packet(
        "00:11:22:33:44:55",
        "AA:BB:CC:DD:EE:FF",
        port=9
    )

    wakeonlan.send_magic_packet(
        "00:11:22:33:44:55",
        ip_address="192.0.2.255",
        port=7
    )
finally:
    wakeonlan.socket.socket = original_socket

assert len(captures) == 2
assert captures[0][0] == ("255.255.255.255", 9)
assert len(captures[0][1]) == 2
assert captures[1][0] == ("192.0.2.255", 7)
assert len(captures[1][1]) == 1

for destination, packets in captures:
    assert all(len(packet) == 102 for packet in packets)

print("WAKEONLAN: PASS (UDP simulated)")
print("PADIT SERVER DEPENDENCIES M03: PASS")
