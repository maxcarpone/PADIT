# -*- coding: utf-8 -*-
"""PADIT M06 - pefile compatibility regression tests."""

from __future__ import print_function

import os
import tempfile

import pefile
import pkg_resources

from waptserver import utils as server_utils


class Dummy(object):
    pass


def make_file_info(nested, file_version, product_version):
    table = Dummy()
    table.entries = {
        'FileVersion': file_version,
        'ProductVersion': product_version,
    }

    entry = Dummy()
    entry.StringTable = [table]

    if nested:
        return [[entry]]
    return [entry]


def check_version(nested, file_version, product_version, expected):
    original_pe = server_utils.pefile.PE

    class FakePE(object):
        def __init__(self, filename):
            self.FileInfo = make_file_info(
                nested, file_version, product_version
            )
            self.closed = False

        def close(self):
            self.closed = True

    handle, filename = tempfile.mkstemp(suffix='.exe')
    os.close(handle)

    server_utils.pefile.PE = FakePE

    try:
        present, version = server_utils.get_wapt_exe_version(filename)
        assert present is True
        assert version == expected, (version, expected)
    finally:
        server_utils.pefile.PE = original_pe
        os.unlink(filename)


def main():
    version = pkg_resources.get_distribution('pefile').version
    assert version == '2019.4.18', version

    assert callable(pefile.PE)
    assert issubclass(pefile.PEFormatError, Exception)

    # Historical pefile structure.
    check_version(False, '1.8.3.7531', '1.8.3',
                  '1.8.3.7531')

    # New pefile structure.
    check_version(True, '1.8.3.7531', '1.8.3',
                  '1.8.3.7531')

    # ProductVersion fallback.
    check_version(True, '', '1.8.3', '1.8.3')

    # Missing executable.
    present, version = server_utils.get_wapt_exe_version(
        '/tmp/padit-m06-nonexistent-executable.exe'
    )
    assert present is False
    assert version is None

    print('PADIT SERVER DEPENDENCIES M06: PASS')


if __name__ == '__main__':
    main()
