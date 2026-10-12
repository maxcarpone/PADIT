import io
import gzip
import zlib
import urllib3

from urllib3.response import HTTPResponse, MultiDecoder
from urllib3.exceptions import ProtocolError, DecodeError

assert urllib3.__version__ == '1.26.20'
print('[PASS] urllib3 1.26.20')

# CVE-2026-97689: reject oversized HTTP chunk-size lines.
class FakeHTTP(object):
    def __init__(self, data):
        self.fp = io.BytesIO(data)
        self.closed = False

    def close(self):
        self.closed = True

    def isclosed(self):
        return self.closed

    def _safe_read(self, count):
        return self.fp.read(count)

def chunk_response(data):
    response = HTTPResponse(
        body=FakeHTTP(data),
        headers={},
        preload_content=False
    )
    response._fp = FakeHTTP(data)
    response.chunked = True
    return response

response = chunk_response(b'1' * 70000 + b'\r\n')
try:
    response._update_chunk_length()
except ProtocolError:
    print('[PASS] CVE-2026-97689: oversized chunk-size rejected')
else:
    raise AssertionError('Oversized chunk-size accepted')

# A normal HTTP chunk-size remains valid.
response = chunk_response(b'4\r\n')
response._update_chunk_length()
assert response.chunk_left == 4
print('[PASS] Normal chunk-size accepted')

# CVE-2025-66418: reject more than five chained encodings.
try:
    MultiDecoder('gzip,gzip,gzip,gzip,gzip,gzip')
except DecodeError:
    print('[PASS] CVE-2025-66418: six encodings rejected')
else:
    raise AssertionError('Six content encodings accepted')

MultiDecoder('gzip,gzip,gzip,gzip,gzip')
print('[PASS] Five encodings accepted')

# CVE-2025-66471: bound streamed gzip decompression.
data = b'PADIT-urllib3-stream-test-' * 10000

buffer = io.BytesIO()
gz = gzip.GzipFile(fileobj=buffer, mode='wb')
gz.write(data)
gz.close()
compressed = buffer.getvalue()

response = HTTPResponse(
    body=io.BytesIO(compressed),
    headers={'Content-Encoding': 'gzip'},
    preload_content=False,
    decode_content=True
)

blocks = list(response.stream(amt=4096, decode_content=True))
assert blocks, 'No streamed output'
assert all(0 < len(block) <= 4096 for block in blocks), (
    'Streaming output exceeded requested amount'
)
assert b''.join(blocks) == data, 'Decoded content mismatch'
print('[PASS] CVE-2025-66471: gzip streaming bounded and complete')

print('[PASS] urllib3 security regression tests')
