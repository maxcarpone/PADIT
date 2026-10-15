# -*- coding: utf-8 -*-
from __future__ import print_function

import datetime
import hashlib
import imp
import os
import sys

import cryptography
from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

EXPECTED_HASH = "be9836ac8835d4cef3d7deb47edaecb9344936d79534f84c95c4576f77a9d737"
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SOURCE = os.path.join(
    REPO_ROOT, "utils", "patch-cryptography", "verification.py"
)

mode = os.environ.get("PADIT_X509_TEST_MODE", "source")
assert mode in ("source", "installed"), "Unsupported test mode"
assert cryptography.__version__ == "3.3.2"

with open(SOURCE, "rb") as f:
    assert hashlib.sha256(f.read()).hexdigest() == EXPECTED_HASH

if mode == "source":
    verification = imp.load_source("padit_x509_test", SOURCE)
else:
    from cryptography.x509 import verification
    runtime = os.path.realpath(sys.prefix)
    module_path = os.path.realpath(verification.__file__)

    assert module_path.startswith(runtime + os.sep), (
        "Verification loaded outside Unix agent runtime: %s" % module_path
    )

required = (
    "CertificateVerificationContext",
    "CertificateRevocationListVerificationContext",
    "InvalidCertificate",
    "InvalidSigningCertificate",
    "InvalidCertificateRevocationList",
)

for name in required:
    assert hasattr(verification, name), name

for name in (
    "AttributeNotFound",
    "SubjectInformationAccess",
    "SignedCertificateTimestamps",
):
    assert hasattr(x509, name), name

print("[PASS] U94-F2 / API native and PADIT interfaces")

def expect_exception(expected, function):
    try:
        function()
    except expected:
        return
    raise AssertionError("Expected exception: %s" % expected)

def key():
    return rsa.generate_private_key(
        public_exponent=65537, key_size=2048
    )

def name(text):
    return x509.Name([
        x509.NameAttribute(NameOID.COMMON_NAME, text)
    ])

now = datetime.datetime.utcnow()
ca_key = key()
ca_name = name(u"PADIT Test CA")

def make_cert(subject, issuer, public_key, signing_key, is_ca,
              cert_sign=None):
    builder = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(public_key)
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(days=1))
        .not_valid_after(now + datetime.timedelta(days=1))
        .add_extension(
            x509.BasicConstraints(ca=is_ca, path_length=None),
            critical=True
        )
    )
    if cert_sign is not None:
        builder = builder.add_extension(
            x509.KeyUsage(
                digital_signature=True,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=cert_sign,
                crl_sign=cert_sign,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True
        )
    return builder.sign(signing_key, hashes.SHA256())

ca = make_cert(
    ca_name, ca_name, ca_key.public_key(), ca_key, True, True
)
leaf_key = key()
leaf = make_cert(
    name(u"PADIT Agent"), ca_name,
    leaf_key.public_key(), ca_key, False
)

ctx = verification.CertificateVerificationContext(ca)
ctx.update(leaf)
ctx.verify()
print("[PASS] U94-F2 / Valid RSA certificate")

bad_key = key()
bad_leaf = make_cert(
    name(u"PADIT Bad Signature"), ca_name,
    leaf_key.public_key(), bad_key, False
)
ctx.update(bad_leaf)
expect_exception(InvalidSignature, ctx.verify)
print("[PASS] U94-F2 / Invalid RSA signature rejected")

wrong_issuer = make_cert(
    name(u"PADIT Wrong Issuer"), name(u"Unknown CA"),
    leaf_key.public_key(), ca_key, False
)
ctx.update(wrong_issuer)
expect_exception(verification.InvalidCertificate, ctx.verify)
print("[PASS] U94-F2 / Wrong issuer rejected")

non_ca = make_cert(
    name(u"PADIT Non CA"), ca_name,
    leaf_key.public_key(), ca_key, False
)
expect_exception(
    verification.InvalidSigningCertificate,
    lambda: verification.CertificateVerificationContext(non_ca)
)

restricted_ca = make_cert(
    ca_name, ca_name, ca_key.public_key(), ca_key, True, False
)
expect_exception(
    verification.InvalidSigningCertificate,
    lambda: verification.CertificateVerificationContext(restricted_ca)
)
print("[PASS] U94-F2 / CA constraints and KeyUsage")

def make_crl(signing_key, issuer):
    return (
        x509.CertificateRevocationListBuilder()
        .issuer_name(issuer)
        .last_update(now - datetime.timedelta(hours=1))
        .next_update(now + datetime.timedelta(days=1))
        .sign(signing_key, hashes.SHA256())
    )

crl_ctx = verification.CertificateRevocationListVerificationContext(ca)
crl_ctx.update(make_crl(ca_key, ca_name))
crl_ctx.verify()
print("[PASS] U94-F2 / Valid RSA CRL")

crl_ctx.update(make_crl(bad_key, ca_name))
expect_exception(InvalidSignature, crl_ctx.verify)

crl_ctx.update(make_crl(ca_key, name(u"Unknown CA")))
expect_exception(verification.InvalidCertificate, crl_ctx.verify)

expect_exception(
    verification.InvalidCertificateRevocationList,
    lambda: crl_ctx.update(leaf)
)
print("[PASS] U94-F2 / Invalid CRL cases rejected")

print("[PASS] U94-F2 / ALL X509 REGRESSIONS")
