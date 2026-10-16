from __future__ import print_function

import os
import sys


from werkzeug.security import safe_join

base = os.path.join(os.environ.get('TEMP', r'C:\Windows\Temp'), 'padit-safe-join')

blocked = [
    'CON', 'NUL', 'AUX', 'PRN',
    'COM1', 'COM9', 'LPT1', 'LPT9',
    'CON.txt', 'NUL.log',
    'folder/COM1.txt', 'folder/LPT1',
    '../outside.txt',
    'folder/../../outside.txt',
    'C:/Windows/system.ini',
]

for name in blocked:
    result = safe_join(base, name)
    if result is not None:
        raise AssertionError(
            'Unsafe Windows path accepted: %r => %r' % (name, result)
        )

allowed = [
    'package.wapt',
    'folder/file.txt',
    'normal-name.txt',
]

for name in allowed:
    result = safe_join(base, name)
    if result is None:
        raise AssertionError('Safe Windows path rejected: %r' % name)

print('[PASS] Windows unsafe paths rejected: %d/%d' % (
    len(blocked), len(blocked)
))
print('[PASS] Windows normal paths accepted: %d/%d' % (
    len(allowed), len(allowed)
))
print('[PASS] W12-G / Windows safe_join regression')
