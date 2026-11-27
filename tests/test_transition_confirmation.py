# -*- coding: utf-8 -*-
import imp
import json
import os
import sys
import tempfile
import threading
import time
import types
import unittest

confirmation = imp.load_source('padit_transition_confirmation', os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    'templates', 'padit_transition_confirmation.py'))
server = imp.load_source('padit_server_transition', os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'waptserver', 'transition.py'))


TRANSITION_ID = "12345678-1234-4321-8765-123456789abc"


class ConfirmationTest(unittest.TestCase):

    def setUp(self):
        self.inventory = {'uuid': 'fixture-id', 'host_info': {'computer_fqdn': 'fixture.test'},
                          'wapt_status': {'wapt-get-version': '1.8.3.7766'}}

    def prepare(self):
        return confirmation.prepare_inventory(self.inventory, 'fixture-id', '1.8.3.7766', TRANSITION_ID)

    def test_same_version_requires_new_inventory(self):
        first, old, old_nonce = self.prepare()
        second, current, nonce = self.prepare()
        self.assertNotEqual(first, second)
        payload = json.loads(second)
        self.assertEqual(payload['wapt_status']['wapt-get-version'], '1.8.3.7766')
        old_payload = json.loads(first)
        acknowledgement = {'success': True, 'result': {'uuid': 'fixture-id',
            'transition_confirmation': server.inventory_readback(old_payload, old_payload, old_nonce)}}
        self.assertRaises(confirmation.ConfirmationError, confirmation.verify_acknowledgement,
                          acknowledgement, 'fixture-id', current, nonce, TRANSITION_ID)
        acknowledgement['result']['transition_confirmation'] = dict(
            server.inventory_readback(payload, payload, nonce),
            transition_id=TRANSITION_ID, confirmed_at='2026-11-27T00:00:00Z')
        confirmation.verify_acknowledgement(acknowledgement, 'fixture-id', current, nonce, TRANSITION_ID)
        self.assertNotIn('padit_transition_confirmation', self.inventory['host_info'])

    def test_wrong_uuid_and_version(self):
        self.assertRaises(confirmation.ConfirmationError, confirmation.prepare_inventory,
                          self.inventory, 'other-id', '1.8.3.7766', TRANSITION_ID)
        self.assertRaises(confirmation.ConfirmationError, confirmation.prepare_inventory,
                          self.inventory, 'fixture-id', '1.8.3.7767', TRANSITION_ID)
        _, hashes, nonce = self.prepare()
        ack = {'success': True, 'result': {'uuid': 'other-id', 'status_hashes': hashes}}
        self.assertRaises(confirmation.ConfirmationError, confirmation.verify_acknowledgement,
                          ack, 'fixture-id', hashes, nonce, TRANSITION_ID)

    def test_http_success_without_new_signed_inventory_is_insufficient(self):
        _, hashes, nonce = self.prepare()
        for response in ({}, {'success': True},
                         {'success': False, 'error_code': 'ewaptmissingcertificate'},
                         {'success': True, 'result': {'uuid': 'fixture-id',
                          'status_hashes': hashes}}):
            self.assertRaises(confirmation.ConfirmationError, confirmation.verify_acknowledgement,
                              response, 'fixture-id', hashes, nonce, TRANSITION_ID)

    @unittest.skipUnless(os.environ.get('PADIT_TEST_REAL_RSA') == '1', 'Use the PADIT Python runtime')
    def test_wire_signature_matches_update_host(self):
        from waptcrypto import SSLPrivateKey, sha256_for_data

        raw, _, nonce = self.prepare()
        key = SSLPrivateKey().create()
        cert = key.build_sign_certificate(cn=u'fixture-id', is_ca=False, is_client_auth=True)
        signature = key.sign_content(sha256_for_data(raw))
        self.assertEqual(cert.verify_content(sha256_for_data(raw), signature), u'fixture-id')
        self.assertRaises(Exception, cert.verify_content, sha256_for_data(raw + ' '), signature)
        self.assertEqual(server.transition_nonce(json.loads(raw)), nonce)

    def test_readback_rejects_normalized_or_stale_database_values(self):
        raw, hashes, nonce = self.prepare()
        payload = json.loads(raw)
        stored = json.loads(raw)
        stored['wapt_status']['wapt-get-version'] = '1.8.3.9999'
        self.assertRaises(ValueError, server.inventory_readback, payload, stored, nonce)
        del stored['host_info']['padit_transition_confirmation']
        self.assertRaises(ValueError, server.inventory_readback, payload, stored, nonce)
        payload['status_hashes'] = {'host_info': 'client echo'}
        stored = json.loads(raw)
        acknowledgement = server.inventory_readback(payload, stored, nonce)
        self.assertEqual(acknowledgement['inventory_sha256'], hashes)
        self.assertIsNone(server.transition_nonce(self.inventory))

    def test_identity_policy_and_confirmation_replay(self):
        uuid = '{ABCDEF12-1234-4321-8765-123456789ABC}'

        class Cert(object):
            def __init__(self, crt_string):
                if crt_string not in ('old', 'renewed', 'foreign'):
                    raise ValueError('invalid certificate')
                self.cn = uuid
                self.key = 'old' if crt_string == 'renewed' else crt_string
                self.rsa = self

            def public_numbers(self):
                return type('Numbers', (), {'n': self.key, 'e': 65537})()

            def verify_content(self, digest, signature):
                if signature != self.key:
                    raise ValueError('invalid proof')

        class Host(object):
            def __init__(self, certificate, trace=None):
                self.uuid = uuid
                self.host_certificate = certificate
                self.padit_transition = trace

        requested = server.enrollment_trace(dict(transition_id=TRANSITION_ID,
            source_server='https://source.test', source_version='1.8.3.7766',
            target_version='1.8.3.7766', issued_at=int(time.time())))
        alias = uuid[1:-1].lower()
        self.assertEqual(server.advisory_key(alias), server.advisory_key(uuid))
        self.assertEqual(server.transition_id('{' + TRANSITION_ID.upper() + '}'), TRANSITION_ID)
        self.assertEqual(server.advisory_key('Foo.Example.'), server.advisory_key('foo.example'))
        self.assertNotEqual(server.advisory_key('Custom'), server.advisory_key('custom'))

        def enroll(rows, cert='old', signature='old'):
            return server.guard_identity(rows, alias, {'host_certificate': cert},
                requested, None, ('signed', signature), Cert)

        _, trace, repeat = enroll([])
        self.assertEqual(trace['state'], 'provisional')
        self.assertFalse(repeat)
        self.assertTrue(enroll([Host('old', trace)], 'renewed')[2])
        self.assertRaises(ValueError, enroll, [], 'old', 'foreign')
        self.assertRaises(ValueError, enroll, [Host('old')], 'foreign')
        self.assertRaises(ValueError, enroll, [Host(None)])
        self.assertRaises(ValueError, enroll, [Host('invalid')])

        data = {'host_certificate': 'foreign'}
        self.assertRaises(ValueError, server.guard_identity, [Host('old', trace)], alias,
                          data, None, None, ('signed', 'foreign'), Cert)
        self.assertEqual(server.guard_identity([Host('old')], alias,
                         data, None, None, None, Cert), (alias, None, False))
        classic_same_key = {'host_certificate': 'renewed'}
        server.guard_identity([Host('old', trace)], uuid, classic_same_key, None, None,
                              ('signed', 'old'), Cert)
        self.assertNotIn('host_certificate', classic_same_key)

        confirmed = server.confirm_trace(trace, TRANSITION_ID, '1.8.3.7766')
        self.assertEqual(confirmed['state'], 'confirmed')
        self.assertTrue(server.confirm_trace(confirmed, TRANSITION_ID, '1.8.3.7766') is confirmed)
        self.assertRaises(ValueError, server.confirm_trace, trace, TRANSITION_ID, '1.8.3.9999')
        host = Host('old', confirmed)
        server.guard_identity([host], uuid, {'host_info': {}}, None, None, None, Cert)
        self.assertEqual(host.padit_transition, confirmed)
        replacement = {'host_certificate': 'foreign'}
        self.assertEqual(server.guard_identity([host], uuid, replacement, None, None,
            ('signed', 'foreign'), Cert), (uuid, None, False))
        self.assertEqual(replacement['host_certificate'], 'foreign')
        self.assertEqual(host.padit_transition, confirmed)
        self.assertTrue(enroll([host])[2])
        self.assertRaises(ValueError, enroll, [host], 'foreign', 'foreign')

        now = trace['issued_at'] + 1
        later = dict(requested, transition_id='12345678-1234-4321-8765-123456789abd',
                     issued_at=now, expires_at=now + server.PROVISIONAL_SECONDS)
        subsequent = server.protect_enrollment(confirmed, later, now)
        self.assertEqual(subsequent['last_confirmed'], confirmed)
        self.assertRaises(ValueError, server.protect_enrollment, subsequent, requested, now)
        self.assertRaises(ValueError, server.protect_enrollment, confirmed,
                          dict(later, issued_at=trace['issued_at'] - 1), now)
        abandoned = dict(subsequent, expires_at=int(time.time()))
        expired_host = Host('old', abandoned)
        self.assertEqual(server.guard_identity([expired_host], uuid, replacement, None, None,
            ('signed', 'foreign'), Cert), (uuid, None, False))
        self.assertEqual(expired_host.padit_transition['last_confirmed'], confirmed)
        self.assertRaises(ValueError, server.protect_enrollment, abandoned, later, abandoned['expires_at'])
        self.assertRaises(ValueError, server.confirm_trace, abandoned, later['transition_id'],
                          later['target_version'], abandoned['expires_at'])
        after_expiry = dict(later, transition_id='12345678-1234-4321-8765-123456789abe',
                            issued_at=now + 1)
        self.assertEqual(server.protect_enrollment(abandoned, after_expiry,
            abandoned['expires_at'])['last_confirmed'], confirmed)

        # Simulate serialization by advisory key, then run both conflicting proofs.
        lock = threading.Lock()
        barrier = threading.Event()
        rows, outcomes = [], []

        def attempt(key):
            barrier.wait()
            with lock:
                try:
                    _, record, _ = enroll(rows, key, key)
                    rows[:] = [Host(key, record)]
                    outcomes.append('accepted')
                except ValueError:
                    outcomes.append('refused')

        workers = [threading.Thread(target=attempt, args=(key,)) for key in ('old', 'foreign')]
        for worker in workers:
            worker.start()
        barrier.set()
        for worker in workers:
            worker.join(5)
        self.assertEqual(sorted(outcomes), ['accepted', 'refused'])

    def test_transport_fixture(self):
        fixture = self
        calls = []
        mode = ['ok']
        requests = types.ModuleType('requests')
        requests.RequestException = type('RequestException', (Exception,), {})
        crypto = types.ModuleType('waptcrypto')
        crypto.SSLPrivateKey = lambda **kw: type('Key', (), {
            'sign_content': lambda self, digest: 'fixture signature'})()
        crypto.SSLCertificate = lambda **kw: type('Cert', (), {
            'cn': 'fixture-id', 'match_key': lambda self, key: True,
            'as_pem': lambda self: 'fixture certificate'})()

        class Response(object):
            def __init__(self, code, payload):
                self.status_code = code
                self.payload = payload

            def iter_content(self, chunk_size):
                if mode[0] == 'deadline':
                    raise requests.RequestException('simulated read timeout')
                return iter(json.dumps(self.payload))

            def close(self):
                pass

        class Session(object):
            def post(self, url, **kw):
                calls.append(url)
                fixture.assertFalse(self.trust_env)
                fixture.assertFalse(kw['allow_redirects'])
                fixture.assertEqual(kw['timeout'], 3)
                fixture.assertEqual(kw['verify'], ca_path)
                fixture.assertIn('X-Signature', kw['headers'])
                if mode[0] in ('tls', 'unavailable'):
                    raise requests.RequestException('simulated')
                if mode[0] == 'redirect':
                    return Response(302, {})
                data = json.loads(kw['data'])
                if url.endswith('/transition/enroll'):
                    trace = server.enrollment_trace(data['transition'])
                    fixture.assertEqual(data['host_certificate'], 'fixture certificate')
                    return Response(200, {'success': True, 'result': {
                        'uuid': 'fixture-id', 'transition_id': trace['transition_id']}})
                return Response(200, {'success': True, 'result': {
                    'uuid': 'fixture-id', 'transition_confirmation':
                    dict(server.inventory_readback(data, data, server.transition_nonce(data)),
                         transition_id=TRANSITION_ID, confirmed_at='2026-11-27T00:00:00Z')}})

            def close(self):
                pass

        requests.Session = Session
        modules = {'requests': requests, 'waptcrypto': crypto}
        old = dict((name, sys.modules.get(name)) for name in modules)
        sys.modules.update(modules)
        handle, ca_path = tempfile.mkstemp()
        os.close(handle)
        try:
            params = ('https://fixture.test', ca_path, 'key', 'cert',
                      self.inventory, 'fixture-id', '1.8.3.7766', TRANSITION_ID, 3)
            confirmation.enroll_transition_host('https://fixture.test', ca_path, 'key', 'cert',
                'fixture-id', 'fixture.test', dict(transition_id=TRANSITION_ID,
                    source_server='https://source.test', source_version='1.8.2.7393',
                    target_version='1.8.3.7766'), 3)
            self.assertEqual(len(confirmation.confirm_enrolled_host(*params)), 64)
            for mode[0] in ('tls', 'unavailable', 'redirect', 'deadline'):
                self.assertRaises(confirmation.ConfirmationError, confirmation.confirm_enrolled_host, *params)
            self.assertEqual(calls, ['https://fixture.test/transition/enroll'] +
                             ['https://fixture.test/update_host'] * 5)
        finally:
            os.unlink(ca_path)
            for name, previous in old.items():
                if previous is None:
                    del sys.modules[name]
                else:
                    sys.modules[name] = previous


if __name__ == '__main__':
    unittest.main()
