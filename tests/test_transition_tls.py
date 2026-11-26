# -*- coding: utf-8 -*-
"""Real loopback TLS tests. Pass the compiled test_transition_security.exe."""
import datetime
import os
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest

from cryptography import x509
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID


class LocalHTTPS(object):
    def __init__(self, certificate, key, response, on_tls=True):
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen(1)
        self.listener.settimeout(8)
        self.port = self.listener.getsockname()[1]
        self.response = response
        self.requests = []
        self.errors = []
        self.context = None
        if on_tls:
            self.context = ssl.SSLContext(ssl.PROTOCOL_TLSv1_2)
            self.context.load_cert_chain(certificate, key)
        self.worker = threading.Thread(target=self.serve)
        self.worker.daemon = True
        self.worker.start()

    def serve(self):
        connection = None
        try:
            connection, _ = self.listener.accept()
            connection.settimeout(7)
            if self.context is None:
                # Read ClientHello but send no TLS response.
                connection.recv(4096)
                connection.recv(4096)
                return
            connection = self.context.wrap_socket(connection, server_side=True)
            request = b''
            while b'\r\n\r\n' not in request and len(request) < 4096:
                part = connection.recv(4096)
                if not part:
                    break
                request += part
            if request:
                self.requests.append(request)
                connection.sendall(self.response)
        except (ssl.SSLError, socket.error):
            pass
        except Exception as error:
            self.errors.append(error)
        finally:
            if connection is not None:
                connection.close()
            self.listener.close()

    def finish(self):
        self.worker.join(9)
        if self.worker.is_alive() or self.errors:
            raise RuntimeError('Isolated TLS fixture did not finish cleanly')


class TransitionTLS(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.backend = default_backend()
        cls.root = tempfile.mkdtemp(prefix='padit-schannel-')
        cls.root_ca, cls.ca_key = cls.issue(u'fixture private CA', is_ca=True)
        cls.ca_bundle = cls.write('ca.pem', cls.root_ca.public_bytes(serialization.Encoding.PEM))
        cls.leaf, cls.leaf_key = cls.issue(u'localhost', cls.root_ca, cls.ca_key)
        cls.leaf_files = cls.save_pair('server', cls.leaf, cls.leaf_key)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.root)

    @classmethod
    def write(cls, name, data):
        path = os.path.join(cls.root, name)
        with open(path, 'wb') as stream:
            stream.write(data)
        return path

    @classmethod
    def save_pair(cls, name, certificate, key):
        return (cls.write(name + '.crt', certificate.public_bytes(serialization.Encoding.PEM)),
                cls.write(name + '.pem', key.private_bytes(serialization.Encoding.PEM,
                    serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption())))

    @classmethod
    def issue(cls, name, issuer=None, issuer_key=None, is_ca=False, expired=False, server=True):
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048, backend=cls.backend)
        now = datetime.datetime.utcnow()
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, name)])
        result = (x509.CertificateBuilder().subject_name(subject)
                  .issuer_name(issuer.subject if issuer is not None else subject)
                  .public_key(key.public_key()).serial_number(x509.random_serial_number())
                  .not_valid_before(now - datetime.timedelta(days=3))
                  .not_valid_after(now + datetime.timedelta(days=-1 if expired else 2))
                  .add_extension(x509.BasicConstraints(ca=is_ca, path_length=None), critical=True))
        if not is_ca:
            eku = ExtendedKeyUsageOID.SERVER_AUTH if server else ExtendedKeyUsageOID.CLIENT_AUTH
            result = (result.add_extension(x509.SubjectAlternativeName([x509.DNSName(name)]), critical=False)
                      .add_extension(x509.ExtendedKeyUsage([eku]), critical=False))
        return result.sign(issuer_key or key, hashes.SHA256(), cls.backend), key

    def probe(self, files, bundle, expected=None, response=None, path='/ping', on_tls=True):
        service = LocalHTTPS(files[0], files[1], response or
            b'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n', on_tls)
        try:
            command = [EXECUTABLE, 'https', bundle, 'https://localhost:%d%s' % (service.port, path)]
            if expected:
                command.append(expected)
            subprocess.check_call(command)
        finally:
            service.finish()
        return service.requests

    def test_private_ca_and_head_paths(self):
        for path in ('/ping', '/wapt/Packages'):
            requests = self.probe(self.leaf_files, self.ca_bundle, path=path)
            self.assertEqual(len(requests), 1)
            self.assertTrue(requests[0].startswith(('HEAD ' + path + ' HTTP/1.1\r\n').encode('ascii')))
            self.assertNotIn(b'Authorization:', requests[0])

    def test_explicit_self_signed_peer(self):
        cert, key = self.issue(u'localhost')
        files = self.save_pair('peer', cert, key)
        self.assertEqual(len(self.probe(files, files[0])), 1)

    def test_unapproved_certificate_sends_no_http(self):
        cert, key = self.issue(u'localhost')
        self.assertEqual(self.probe(self.save_pair('unknown', cert, key), self.ca_bundle,
                                   'certificate chain'), [])

    def test_wrong_dns_sends_no_http(self):
        cert, key = self.issue(u'other.example.test', self.root_ca, self.ca_key)
        self.assertEqual(self.probe(self.save_pair('name', cert, key), self.ca_bundle,
                                   'DNS name or server usage'), [])

    def test_expired_certificate_sends_no_http(self):
        cert, key = self.issue(u'localhost', self.root_ca, self.ca_key, expired=True)
        self.assertEqual(self.probe(self.save_pair('expired', cert, key), self.ca_bundle,
                                   'outside its validity period'), [])

    def test_wrong_server_usage_sends_no_http(self):
        cert, key = self.issue(u'localhost', self.root_ca, self.ca_key, server=False)
        self.assertEqual(self.probe(self.save_pair('usage', cert, key), self.ca_bundle,
                                   'server usage'), [])
        cert, key = self.issue(u'localhost', server=False)
        peer = self.save_pair('peer-usage', cert, key)
        self.assertEqual(self.probe(peer, peer[0], 'server usage'), [])

    def test_unreachable_and_timeout(self):
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
            subprocess.check_call([EXECUTABLE, 'https', self.ca_bundle,
                'https://127.0.0.1:%d/ping' % port, 'server is inaccessible'])
        finally:
            listener.close()
        start = time.time()
        self.assertEqual(self.probe(self.leaf_files, self.ca_bundle, 'deadline exceeded', on_tls=False), [])
        self.assertLess(time.time() - start, 9)

    def test_http_redirect_is_not_followed(self):
        http_listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            http_listener.bind(('127.0.0.1', 0))
            http_listener.listen(1)
            http_listener.settimeout(0.2)
            port = http_listener.getsockname()[1]
            response = ('HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:%d/ping\r\n'
                        'Content-Length: 0\r\nConnection: close\r\n\r\n' % port).encode('ascii')
            requests = self.probe(self.leaf_files, self.ca_bundle, 'status 302', response=response)
            self.assertEqual(len(requests), 1)
            self.assertRaises(socket.timeout, http_listener.accept)
        finally:
            http_listener.close()


if __name__ == '__main__':
    EXECUTABLE = os.path.abspath(sys.argv.pop(1))
    unittest.main()
