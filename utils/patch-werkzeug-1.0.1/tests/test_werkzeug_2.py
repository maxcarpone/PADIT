from io import BytesIO

from werkzeug.exceptions import RequestEntityTooLarge
from werkzeug.wrappers import Request


def make_request(count):
    boundary = b"PADITBOUNDARY"
    parts = []

    for i in range(count):
        parts.append(
            b"--" + boundary + b"\r\n"
            b"Content-Disposition: form-data; name=\"field%d\"\r\n"
            b"\r\n"
            b"x\r\n" % i
        )

    parts.append(b"--" + boundary + b"--\r\n")
    data = b"".join(parts)

    return Request.from_values(
        input_stream=BytesIO(data),
        content_length=len(data),
        content_type="multipart/form-data; boundary=PADITBOUNDARY",
        method="POST",
    )


req = make_request(1000)

if len(req.form) != 1000:
    raise RuntimeError(
        "CVE-2023-25577 regression: 1000 multipart parts were not accepted"
    )

req = make_request(1001)

try:
    req.form
except RequestEntityTooLarge:
    pass
else:
    raise RuntimeError(
        "CVE-2023-25577 regression: 1001 multipart parts were accepted"
    )

print("CVE-2023-25577 MULTIPART PART LIMIT TEST: PASS")