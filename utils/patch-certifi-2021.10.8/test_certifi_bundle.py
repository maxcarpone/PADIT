from __future__ import print_function

import hashlib
import os
import re
import ssl
import sys

import certifi

EXPECTED_SHA256 = (
    "9cc2a774b5198dcff14d9be1e66091f538975d867ce029a96bce15a55dfd730f"
)

# Exact SHA256 fingerprints of the five historical vulnerable roots.
BLOCKED_ROOTS = {
    "TrustCor RootCert CA-2":
        "0753e940378c1bd5e3836e395daea5cb839e5046f1bd0eae1951cf10fec7c965",
    "TrustCor ECA-1":
        "5a885db19c01d912c5759388938cafbbdf031ab2d48e91ee15589b42971d039c",
    "TrustCor RootCert CA-1":
        "d40e9c86cd8fe468c1776959f49ea774fa548684b6c406f3909261f4dce2575c",
    "E-Tugra":
        "b0bfd52bb0d7d9bd92bf5d4dc13da255c02c542f378365ea893911f55e55f23c",
    "GLOBALTRUST 2020":
        "9a296a5182d1d451a2e37f439b74daafa267523329f90f9a0d2007c334e23c9a",
}

path = certifi.where()

with open(path, "rb") as stream:
    data = stream.read()

assert hashlib.sha256(data).hexdigest() == EXPECTED_SHA256
print("[PASS] certifi bundle SHA256")

certificates = re.findall(
    b"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
    data,
    re.S
)

fingerprints = set(
    hashlib.sha256(ssl.PEM_cert_to_DER_cert(
        certificate.decode("ascii")
    )).hexdigest()
    for certificate in certificates
)

assert len(certificates) == 121, len(certificates)

for name, fingerprint in sorted(BLOCKED_ROOTS.items()):
    assert fingerprint not in fingerprints, name
    print("[PASS] Removed root:", name)

context = ssl.create_default_context(cafile=path)
assert context is not None
print("[PASS] OpenSSL CA bundle loading")

print("[PASS] certifi security regression suite")
