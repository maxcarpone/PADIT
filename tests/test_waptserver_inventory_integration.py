#!/usr/bin/env python2
# -*- coding: utf-8 -*-

"""Inventory regression tests using a dedicated PostgreSQL instance."""

import os
import sys
import copy
import cPickle
import hashlib
import logging
import threading
import time
import unittest
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from playhouse.pool import PooledPostgresqlExtDatabase
from waptserver import model, transition
from waptcrypto import SSLPrivateKey, sha256_for_data

SOCKET_DIR = os.environ.get('PADIT_TEST_PG', '')

if not (
    SOCKET_DIR.startswith('/tmp/padit-pgtest.')
    and os.path.exists(
        os.path.join(SOCKET_DIR, '.s.PGSQL.55432'))
    and os.path.isfile(
        os.path.join(SOCKET_DIR, 'data', 'PG_VERSION'))
):
    raise RuntimeError('Dedicated PostgreSQL test instance required')


class TestInventoryIntegration(unittest.TestCase):

    def setUp(self):
        self.db = PooledPostgresqlExtDatabase(
            'postgres',
            host=SOCKET_DIR,
            port=55432,
            user='postgres',
            max_connections=5,
            timeout=3,
            autoconnect=False
        )

        model.wapt_db.initialize(self.db)

        self.server_conf = {
            'remote_repo_diff': False,
            'known_certificates_folder': os.path.join(
                SOCKET_DIR, 'test-certificates')
        }

        self.uuid = str(uuid.uuid4())

        with model.WaptDB():
            self.assertEqual(
                self.db.execute_sql(
                    'SHOW data_directory').fetchone()[0],
                os.path.join(SOCKET_DIR, 'data'))

            self.db.create_tables([
                model.Hosts,
                model.HostPackagesStatus,
                model.HostSoftwares,
                model.HostGroups,
            ], safe=True)

        self.addCleanup(self.db.close_all)
        self.addCleanup(self.remove_test_host)

    def remove_test_host(self):
        with model.WaptDB():
            model.Hosts.delete().where(
                model.Hosts.uuid == self.uuid).execute()

        self.assert_pool_clean()

    def assert_pool_clean(self):
        self.assertTrue(self.db.is_closed())
        self.assertEqual(len(self.db._in_use), 0)

    @staticmethod
    def inventory_hash(data):
        return hashlib.sha1(cPickle.dumps(data)).hexdigest()

    def get_host(self):
        return model.Hosts.get(
            model.Hosts.uuid == self.uuid)

    def insert_host(self):
        status = {
            'wapt-get-version': u'1.8.3\x00',
            'pending_reboot_reasons': [u'abc\x00def'],
            'authorized_certificates_sha256': [],
            'wapt-version-full': r'abc\u0000def',
        }

        original_hash = self.inventory_hash(status)

        data = {
            'uuid': self.uuid,
            'host_info': {
                'computer_fqdn': 'padit-test.example.invalid',
                'computer_name': 'PADIT-TEST',
                'description': u'Poste de test\x00',
            },
            'wapt_status': status,
            'status_hashes': {
                'wapt_status': original_hash
            },
        }

        original = copy.deepcopy(data)

        result = model.update_host_data(data, self.server_conf)

        self.assertEqual(data, original)
        self.assertEqual(result['uuid'], self.uuid)
        self.assertEqual(
            result['status_hashes']['wapt_status'],
            original_hash)

        return original_hash

    def test_protected_transition_and_repeat_confirmation(self):
        key = SSLPrivateKey().create()
        cert = key.build_sign_certificate(cn=unicode(self.uuid), is_ca=False)
        other_key = SSLPrivateKey().create()
        other = other_key.build_sign_certificate(cn=unicode(self.uuid), is_ca=False)
        trace = transition.enrollment_trace(dict(transition_id=str(uuid.uuid4()),
            source_server='https://source.invalid', source_version='1.8.3.7766',
            target_version='1.8.3.7766', issued_at=int(time.time())))

        def write(cert, key, enroll=None):
            data = dict(uuid=self.uuid, host_certificate=cert.as_pem())
            raw = model.jsondump(data)
            return model.update_host_data(data, self.server_conf, enrollment=enroll,
                signed_request=(raw, key.sign_content(sha256_for_data(raw))))

        with model.WaptDB():
            self.assertEqual(write(cert, key, trace)['transition_id'], trace['transition_id'])
            self.assertEqual(self.get_host().padit_transition['state'], 'provisional')
            self.assertEqual(write(cert, key, trace)['transition_id'], trace['transition_id'])
            self.assertRaises(Exception, write, other, other_key, trace)
            self.assertRaises(Exception, write, other, other_key)
            self.assertEqual(self.get_host().host_certificate, cert.as_pem())

            def acknowledge(nonce):
                data = dict(uuid=self.uuid, transition_id=trace['transition_id'],
                    host_info={'computer_fqdn': 'fixture.invalid', transition.NONCE_FIELD: nonce},
                    wapt_status={'wapt-get-version': '1.8.3.7766', transition.NONCE_FIELD: nonce})
                raw = model.jsondump(data)
                return model.update_host_data(data, self.server_conf, confirmation_nonce=nonce,
                    signed_request=(raw, key.sign_content(sha256_for_data(raw))))['transition_confirmation']

            first = acknowledge('a'*32)
            second = acknowledge('b'*32)
            self.assertEqual(first['confirmed_at'], second['confirmed_at'])
            before = self.get_host()
            model.HostGroups.create(host=self.uuid, group_name='fixture-assignment')
            write(other, other_key)
            after = self.get_host()
            self.assertEqual(after.host_certificate, other.as_pem())
            self.assertEqual(after.created_on, before.created_on)
            self.assertEqual(after.padit_transition, before.padit_transition)
            self.assertTrue(model.HostGroups.select().where(
                (model.HostGroups.host == self.uuid) &
                (model.HostGroups.group_name == 'fixture-assignment')).exists())
            self.assertNotEqual(first['inventory_sha256'], second['inventory_sha256'])
            model.update_host_data(dict(uuid=self.uuid, padit_transition={'state': 'forged'},
                __dict__={'padit_transition': None},
                host_info={'computer_fqdn': 'fixture.invalid'}), self.server_conf)
            self.assertEqual(self.get_host().padit_transition['confirmed_at'], first['confirmed_at'])

    def test_concurrent_transition_enrollments(self):
        trace = transition.enrollment_trace(dict(transition_id=str(uuid.uuid4()),
            source_server='https://source.invalid', source_version='1.8.2.7393',
            target_version='1.8.3.7766', issued_at=int(time.time())))
        start = threading.Event()
        outcome = []

        def enroll(key, pem):
            data = dict(uuid=self.uuid, host_certificate=pem)
            raw = model.jsondump(data)
            signed = raw, key.sign_content(sha256_for_data(raw))
            start.wait()
            with model.WaptDB():
                try:
                    model.update_host_data(data, self.server_conf, enrollment=trace, signed_request=signed)
                except Exception as error:
                    outcome.append(error)
                else:
                    outcome.append(None)

        threads = []
        for _ in range(2):
            key = SSLPrivateKey().create()
            cert = key.build_sign_certificate(cn=unicode(self.uuid), is_ca=False)
            worker = threading.Thread(target=enroll, args=(key, cert.as_pem()))
            worker.daemon = True
            threads.append(worker)
            worker.start()
        start.set()
        for worker in threads:
            worker.join(10)
        self.assertEqual(len(outcome), 2)
        self.assertEqual(outcome.count(None), 1)
        self.assertIsInstance(next(result for result in outcome if result is not None), Exception)
        with model.WaptDB():
            self.assertEqual(self.get_host().padit_transition['state'], 'provisional')

    def test_inventory_insert(self):
        with model.WaptDB():
            original_hash = self.insert_host()
            stored = self.get_host()

            self.assertEqual(
                stored.wapt_status['wapt-get-version'],
                u'1.8.3 ')

            self.assertEqual(
                stored.wapt_status['pending_reboot_reasons'],
                [u'abc def'])

            self.assertEqual(
                stored.wapt_status['wapt-version-full'],
                r'abc\u0000def')

            self.assertEqual(
                stored.description, u'Poste de test ')

            self.assertEqual(
                stored.computer_fqdn,
                'padit-test.example.invalid')

            self.assertEqual(
                stored.status_hashes['wapt_status'],
                original_hash)

        self.assert_pool_clean()

    def test_inventory_update(self):
        with model.WaptDB():
            previous_hash = self.insert_host()
            previous = self.get_host()

            status = {
                'wapt-get-version': u'1.8.3.7705\x00',
                'pending_reboot_reasons': [u'Update\x00pending'],
                'authorized_certificates_sha256': [],
            }

            new_hash = self.inventory_hash(status)

            self.assertNotEqual(previous_hash, new_hash)

            result = model.update_host_data({
                'uuid': self.uuid,
                'wapt_status': status,
                'status_hashes': {
                    'wapt_status': new_hash
                },
            }, self.server_conf)

            stored = self.get_host()

            self.assertEqual(
                stored.wapt_status['wapt-get-version'],
                u'1.8.3.7705 ')

            self.assertEqual(
                stored.status_hashes['wapt_status'], new_hash)

            self.assertEqual(
                result['status_hashes']['wapt_status'], new_hash)

            self.assertEqual(
                stored.description, previous.description)

            self.assertEqual(
                stored.computer_fqdn, previous.computer_fqdn)

        self.assert_pool_clean()

    def test_invalid_inventory_rollback(self):
        with model.WaptDB():
            original_hash = self.insert_host()
            baseline = copy.deepcopy(self.get_host().__data__)

        invalid_status = {
            'wapt-get-version': 'INVALID',
            'authorized_certificates_sha256': ['abc\x00def'],
        }

        invalid_hash = self.inventory_hash(invalid_status)

        with self.assertRaises(ValueError) as caught:
            with model.WaptDB():
                model.update_host_data({
                    'uuid': self.uuid,
                    'host_info': {
                        'description': 'INVALID DESCRIPTION'
                    },
                    'wapt_status': invalid_status,
                    'status_hashes': {
                        'wapt_status': invalid_hash
                    },
                }, self.server_conf)

        self.assertIn('NUL character', str(caught.exception))
        self.assert_pool_clean()

        with model.WaptDB():
            stored = self.get_host()

            self.assertEqual(stored.__data__, baseline)

            self.assertEqual(
                stored.status_hashes['wapt_status'],
                original_hash)

            self.assertNotEqual(
                stored.status_hashes['wapt_status'],
                invalid_hash)

            self.assertEqual(
                self.db.execute_sql(
                    'SELECT 42').fetchone()[0], 42)

        self.assert_pool_clean()


    def community_inventory(self):
        packages = [{
            'package': 'padit-test-package',
            'package_uuid': 'test-package-001',
            'version': '1.0-1',
            'description': u'Description\x00du paquet',
            'install_output': 'Installation\x00OK',
            'last_audit_output': u'Audit\x00OK',
            'install_status': 'OK',
            'depends': ['valid-dependency'],
            'conflicts': [],
        }]

        softwares = [{
            'name': u'Logiciel\x00de test',
            'version': '1.0',
            'publisher': 'Editeur\x00test',
            'key': 'valid-software-key',
        }]

        return {
            'uuid': self.uuid,
            'last_update_status': {},
            'installed_packages': packages,
            'installed_softwares': softwares,
            'status_hashes': {
                'installed_packages': self.inventory_hash(packages),
                'installed_softwares': self.inventory_hash(softwares),
            },
        }

    def package_rows(self):
        return list(model.HostPackagesStatus.select().where(
            model.HostPackagesStatus.host == self.uuid).dicts())

    def software_rows(self):
        return list(model.HostSoftwares.select().where(
            model.HostSoftwares.host == self.uuid).dicts())

    def test_community_inventory_normalization(self):
        data = self.community_inventory()
        original = copy.deepcopy(data)

        with model.WaptDB():
            result = model.update_host_data(data, self.server_conf)

            packages = self.package_rows()
            softwares = self.software_rows()

            self.assertEqual(len(packages), 1)
            self.assertEqual(len(softwares), 1)

            package = packages[0]
            software = softwares[0]

            self.assertEqual(
                package['description'], u'Description du paquet')
            self.assertEqual(
                package['install_output'], 'Installation OK')
            self.assertEqual(
                package['last_audit_output'], u'Audit OK')

            self.assertEqual(
                software['name'], u'Logiciel de test')
            self.assertEqual(
                software['publisher'], 'Editeur test')

            self.assertEqual(
                package['package'], 'padit-test-package')
            self.assertEqual(
                package['package_uuid'], 'test-package-001')
            self.assertEqual(package['version'], '1.0-1')
            self.assertEqual(
                package['depends'], ['valid-dependency'])
            self.assertEqual(
                software['key'], 'valid-software-key')

            self.assertEqual(data, original)

            stored = self.get_host()

            for key, value in data['status_hashes'].iteritems():
                self.assertEqual(
                    result['status_hashes'][key], value)
                self.assertEqual(
                    stored.status_hashes[key], value)

        self.assert_pool_clean()

    def test_community_inventory_rollback(self):
        data = self.community_inventory()

        with model.WaptDB():
            model.update_host_data(data, self.server_conf)

            baseline_packages = self.package_rows()
            baseline_softwares = self.software_rows()

            self.assertEqual(len(baseline_packages), 1)
            self.assertEqual(len(baseline_softwares), 1)

        self.assert_pool_clean()

        invalid_packages = copy.deepcopy(
            data['installed_packages'])
        invalid_packages[0]['depends'] = [
            'invalid\x00dependency']

        invalid_softwares = copy.deepcopy(
            data['installed_softwares'])
        invalid_softwares[0]['key'] = 'invalid\x00key'

        for field, invalid_data in (
                ('installed_packages', invalid_packages),
                ('installed_softwares', invalid_softwares)):

            rejected_hash = self.inventory_hash(invalid_data)
            original_hash = data['status_hashes'][field]

            invalid = {
                'uuid': self.uuid,
                'last_update_status': {},
                field: invalid_data,
                'status_hashes': {
                    field: rejected_hash
                },
            }

            original = copy.deepcopy(invalid)

            with model.WaptDB():
                result = model.update_host_data(
                    invalid, self.server_conf)

                self.assertEqual(
                    self.package_rows(), baseline_packages)
                self.assertEqual(
                    self.software_rows(), baseline_softwares)

                stored = self.get_host()

                self.assertEqual(
                    stored.status_hashes[field], original_hash)
                self.assertEqual(
                    result['status_hashes'][field], original_hash)
                self.assertNotEqual(
                    stored.status_hashes[field], rejected_hash)

                self.assertEqual(invalid, original)

            self.assert_pool_clean()

        with model.WaptDB():
            self.assertEqual(
                self.db.execute_sql(
                    'SELECT 42').fetchone()[0], 42)

        self.assert_pool_clean()


    def test_late_sql_failure_hash_not_acknowledged(self):
        data = self.community_inventory()

        with model.WaptDB():
            model.update_host_data(data, self.server_conf)
            baseline = self.package_rows()

        self.assert_pool_clean()

        original_hash = data['status_hashes']['installed_packages']

        packages = copy.deepcopy(data['installed_packages'])
        packages[0]['description'] = 'Updated package description'

        new_hash = self.inventory_hash(packages)

        self.assertNotEqual(original_hash, new_hash)

        original_updater = model.update_installed_packages
        reached = []

        def failing_updater(uuid, data, hashes):
            original_updater(uuid, data, hashes)

            self.assertEqual(
                hashes['installed_packages'], new_hash)

            reached.append(True)

            # Force a real PostgreSQL error after hash assignment.
            model.wapt_db.execute_sql('SELECT 1 / 0')

        model.update_installed_packages = failing_updater

        try:
            with model.WaptDB():
                result = model.update_host_data({
                    'uuid': self.uuid,
                    'last_update_status': {},
                    'installed_packages': packages,
                    'status_hashes': {
                        'installed_packages': new_hash
                    },
                }, self.server_conf)

                self.assertEqual(reached, [True])
                self.assertEqual(self.package_rows(), baseline)

                stored = self.get_host()

                self.assertEqual(
                    stored.status_hashes['installed_packages'],
                    original_hash)

                self.assertEqual(
                    result['status_hashes']['installed_packages'],
                    original_hash)

                self.assertNotEqual(
                    stored.status_hashes['installed_packages'],
                    new_hash)

                self.assertEqual(
                    self.db.execute_sql(
                        'SELECT 42').fetchone()[0], 42)

        finally:
            model.update_installed_packages = original_updater

        self.assert_pool_clean()


if __name__ == '__main__':
    logging.basicConfig(level=logging.WARNING)
    unittest.main(verbosity=2)
