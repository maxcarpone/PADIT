from __future__ import print_function

import os
import shutil
import sys
import tempfile
import zipfile

import requests
from requests.adapters import HTTPAdapter
from requests.utils import extract_zipped_paths, get_netrc_auth

assert requests.__version__ == '2.27.1'
print('[PASS] requests 2.27.1 loaded')

# CVE-2023-32681: proxy credentials must not reach HTTPS origin.
session = requests.Session()
session.trust_env = False
proxies = {
    'http': 'http://test:pass@localhost:8080',
    'https': 'http://test:pass@localhost:8090',
}

for url, expected in (
    ('http://example.com', True),
    ('https://example.com', False),
):
    prepared = requests.Request('GET', url).prepare()
    session.rebuild_proxies(prepared, proxies)
    assert ('Proxy-Authorization' in prepared.headers) == expected

print('[PASS] CVE-2023-32681')

# CVE-2024-35195: TLS verification must use a separate connection pool.
adapter = HTTPAdapter()
prepared = requests.Request('GET', 'https://example.com').prepare()
assert adapter._get_connection(prepared, False) is not adapter._get_connection(
    prepared, True
)
print('[PASS] CVE-2024-35195')

# CVE-2024-47081: netrc lookup must use hostname, not host:port.
work = tempfile.mkdtemp(prefix='padit-requests-security-')
previous_netrc = os.environ.get('NETRC')

try:
    netrc_file = os.path.join(work, 'netrc')
    with open(netrc_file, 'w') as handle:
        handle.write('machine example.com login padit password secret\n')

    os.environ['NETRC'] = netrc_file
    assert get_netrc_auth('https://example.com:8443/test') == (
        'padit', 'secret'
    )
    print('[PASS] CVE-2024-47081')
finally:
    if previous_netrc is None:
        os.environ.pop('NETRC', None)
    else:
        os.environ['NETRC'] = previous_netrc
    shutil.rmtree(work)

# CVE-2026-25645: repeated extraction must not reuse temporary paths.
work = tempfile.mkdtemp(prefix='padit-requests-archive-')
paths = []

try:
    archive = os.path.join(work, 'payload.zip')
    with zipfile.ZipFile(archive, 'w') as zipped:
        zipped.writestr('payload.txt', 'PADIT-CVE-2026-25645')

    member = os.path.join(archive, 'payload.txt')
    paths = [extract_zipped_paths(member) for _ in range(3)]

    assert len(set(paths)) == 3

    for path in paths:
        assert os.path.isfile(path)
        with open(path, 'rb') as handle:
            assert handle.read() == b'PADIT-CVE-2026-25645'

    print('[PASS] CVE-2026-25645')
finally:
    shutil.rmtree(work)
    for path in paths:
        if os.path.isfile(path):
            os.remove(path)

print('[PASS] requests security regression suite: 4/4')
