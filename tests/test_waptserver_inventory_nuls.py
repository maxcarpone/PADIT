#!/usr/bin/env python2
# -*- coding: utf-8 -*-

"""Regression tests for inventory NUL sanitization."""

import ast
import logging
import os
import copy
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODEL = os.path.join(ROOT, 'waptserver', 'model.py')

with open(MODEL) as f:
    tree = ast.parse(f.read(), MODEL)

nodes = [
    node for node in tree.body
    if getattr(node, 'name', None) in (
        'sanitize_inventory_nuls', 'set_host_field',
        'update_host_data')
]

assert len(nodes) == 3

logger = logging.getLogger('test_inventory_nuls')
logger.addHandler(logging.NullHandler())

exec compile(ast.Module(body=nodes), MODEL, 'exec')


class TestInventoryNuls(unittest.TestCase):

    def test_clean_data(self):
        data = {'name': 'PADIT', 'version': 183}
        self.assertEqual(sanitize_inventory_nuls(data), (data, 0))

    def test_byte_string(self):
        cleaned, count = sanitize_inventory_nuls('abc\x00def')
        self.assertEqual(cleaned, 'abc def')
        self.assertIs(type(cleaned), str)
        self.assertEqual(count, 1)

    def test_unicode_string(self):
        cleaned, count = sanitize_inventory_nuls(u'\xe9t\xe9\x00')
        self.assertEqual(cleaned, u'\xe9t\xe9 ')
        self.assertIs(type(cleaned), unicode)
        self.assertEqual(count, 1)

    def test_multiple_nuls(self):
        self.assertEqual(
            sanitize_inventory_nuls('\x00abc\x00\x00'),
            (' abc  ', 3))

    def test_literal_escape_preserved(self):
        data = r'abc\u0000def'
        self.assertEqual(sanitize_inventory_nuls(data), (data, 0))

    def test_nested_structures(self):
        data = {
            'status': {
                'values': ['a\x00b', u'c\x00d', (1, 'e\x00f')]
            }
        }

        expected = {
            'status': {
                'values': ['a b', u'c d', (1, 'e f')]
            }
        }

        self.assertEqual(
            sanitize_inventory_nuls(data), (expected, 3))

    def test_original_data_preserved(self):
        data = {'nested': ['abc\x00def']}
        original = copy.deepcopy(data)

        sanitize_inventory_nuls(data)

        self.assertEqual(data, original)

    def test_invalid_key(self):
        with self.assertRaises(ValueError):
            sanitize_inventory_nuls({'abc\x00def': 1})

    def test_nested_invalid_key(self):
        with self.assertRaises(ValueError):
            sanitize_inventory_nuls(
                {'nested': [{u'abc\x00def': 1}]})

    def test_key_collision_rejected(self):
        with self.assertRaises(ValueError):
            sanitize_inventory_nuls(
                {'abc\x00def': 1, 'abc def': 2})

    def test_non_text_values(self):
        data = [None, True, False, 42, 3.14]
        self.assertEqual(sanitize_inventory_nuls(data), (data, 0))

    def test_idempotence(self):
        cleaned, count = sanitize_inventory_nuls('abc\x00def')
        self.assertEqual(count, 1)
        self.assertEqual(
            sanitize_inventory_nuls(cleaned), (cleaned, 0))

    def test_strict_clean_data(self):
        data = {'fingerprints': ['abcdef123456']}
        self.assertEqual(
            sanitize_inventory_nuls(data, strict=True),
            (data, 0))

    def test_strict_invalid_value(self):
        with self.assertRaises(ValueError):
            sanitize_inventory_nuls('abc\x00def', strict=True)

    def test_strict_nested_invalid_value(self):
        with self.assertRaises(ValueError):
            sanitize_inventory_nuls(
                {'fingerprints': [u'abc\x00def']},
                strict=True)

    def test_strict_literal_escape(self):
        data = r'abc\u0000def'
        self.assertEqual(
            sanitize_inventory_nuls(data, strict=True),
            (data, 0))

    def test_empty_values(self):
        for data in ('', u'', {}, [], (), None):
            self.assertEqual(
                sanitize_inventory_nuls(data), (data, 0))


class FakeHost(object):
    uuid = 'test-host'


class TestHostFieldSanitization(unittest.TestCase):

    def setUp(self):
        self.host = FakeHost()

    def test_wapt_status_normalized(self):
        data = {
            'wapt-get-version': u'1.8.3\x00',
            'authorized_certificates_sha256': ['abcdef'],
            'pending_reboot_reasons': ['abc\x00def'],
        }

        set_host_field(self.host, 'wapt_status', data)

        self.assertEqual(
            self.host.wapt_status['wapt-get-version'],
            u'1.8.3 ')
        self.assertEqual(
            self.host.wapt_status['pending_reboot_reasons'],
            ['abc def'])
        self.assertEqual(
            self.host.wapt_status['authorized_certificates_sha256'],
            ['abcdef'])

    def test_fingerprint_rejected(self):
        data = {
            'authorized_certificates_sha256': ['abc\x00def']
        }

        with self.assertRaises(ValueError):
            set_host_field(self.host, 'wapt_status', data)

        self.assertFalse(hasattr(self.host, 'wapt_status'))

    def test_repository_url_rejected(self):
        data = {
            'repositories': [
                {'repo_url': 'https://example.invalid/\x00'}
            ]
        }

        with self.assertRaises(ValueError):
            set_host_field(self.host, 'wapt_status', data)

    def test_wapt_status_original_preserved(self):
        data = {'wapt-get-version': '1.8.3\x00'}
        original = copy.deepcopy(data)

        set_host_field(self.host, 'wapt_status', data)

        self.assertEqual(data, original)

    def test_wapt_status_literal_preserved(self):
        data = {'wapt-version-full': r'abc\u0000def'}

        set_host_field(self.host, 'wapt_status', data)

        self.assertEqual(self.host.wapt_status, data)

    def test_wmi_normalized(self):
        data = {'Manufacturer': u'Fabricant\x00'}

        set_host_field(self.host, 'wmi', data)

        self.assertEqual(
            self.host.wmi, {'Manufacturer': u'Fabricant '})

    def test_dmi_normalized(self):
        data = {'BIOS': {'Vendor': 'Vendor\x00'}}

        set_host_field(self.host, 'dmi', data)

        self.assertEqual(
            self.host.dmi, {'BIOS': {'Vendor': 'Vendor '}})

    def test_dmi_uuid_rejected(self):
        with self.assertRaises(ValueError):
            set_host_field(self.host, 'dmi', {
                'System_Information': {
                    'UUID': 'abc\x00def'
                }
            })

    def test_dmi_serial_rejected(self):
        with self.assertRaises(ValueError):
            set_host_field(self.host, 'dmi', {
                'System_Information': {
                    'Serial_Number': 'abc\x00def'
                }
            })

    def test_wmi_nested_identifier_rejected(self):
        with self.assertRaises(ValueError):
            set_host_field(self.host, 'wmi', {
                'Win32_DiskDrive': [
                    {'SerialNumber': 'valid'},
                    {'SerialNumber': 'abc\x00def'}
                ]
            })

    def test_wmi_mixed_hardware_data(self):
        data = {
            'Win32_DiskDrive': [
                {
                    'SerialNumber': 'ABC123',
                    'Manufacturer': 'Vendor\x00'
                }
            ]
        }

        set_host_field(self.host, 'wmi', data)

        disk = self.host.wmi['Win32_DiskDrive'][0]

        self.assertEqual(disk['SerialNumber'], 'ABC123')
        self.assertEqual(disk['Manufacturer'], 'Vendor ')

    def test_status_hash_rejected(self):
        with self.assertRaises(ValueError):
            set_host_field(
                self.host, 'status_hashes',
                {'wapt_status': 'abc\x00def'})

    def test_host_info_descriptions_normalized(self):
        data = {
            'description': u'Poste de travail\x00',
            'system_manufacturer': 'Manufacturer\x00',
            'computer_fqdn': 'host.example.invalid',
        }

        original = copy.deepcopy(data)

        set_host_field(self.host, 'host_info', data)

        self.assertEqual(
            self.host.host_info['description'],
            u'Poste de travail ')

        self.assertEqual(
            self.host.host_info['system_manufacturer'],
            'Manufacturer ')

        self.assertEqual(
            self.host.host_info['computer_fqdn'],
            'host.example.invalid')

        self.assertEqual(data, original)

    def test_host_info_identifiers_rejected(self):
        for key in (
                'computer_fqdn',
                'computer_name',
                'computer_ad_dn',
                'computer_ad_groups',
                'connected_ips',
                'mac'):

            with self.assertRaises(ValueError):
                set_host_field(
                    self.host, 'host_info',
                    {key: 'abc\x00def'})

            self.assertFalse(hasattr(self.host, 'host_info'))

    def test_clean_host_info(self):
        data = {'computer_fqdn': 'host.example.invalid'}

        set_host_field(self.host, 'host_info', data)

        self.assertEqual(self.host.host_info, data)

    def test_logger_failure(self):
        original = logger.warning

        def broken_logger(*args, **kwargs):
            raise RuntimeError('Logging failure')

        try:
            logger.warning = broken_logger

            set_host_field(
                self.host, 'wapt_status',
                {'wapt-get-version': '1.8.3\x00'})

            self.assertEqual(
                self.host.wapt_status['wapt-get-version'],
                '1.8.3 ')
        finally:
            logger.warning = original


class ForbiddenDatabase(object):

    def atomic(self):
        raise AssertionError(
            'Database accessed before metadata validation')


class TestInventoryMetadata(unittest.TestCase):

    def setUp(self):
        global wapt_db
        wapt_db = ForbiddenDatabase()

    def test_invalid_uuid_rejected_before_sql(self):
        with self.assertRaises(ValueError):
            update_host_data({
                'uuid': 'abc\x00def'
            })

    def test_invalid_hash_rejected_before_sql(self):
        with self.assertRaises(ValueError):
            update_host_data({
                'uuid': 'test-host',
                'status_hashes': {
                    'wapt_status': 'abc\x00def'
                }
            })

    def test_invalid_hash_key_rejected_before_sql(self):
        with self.assertRaises(ValueError):
            update_host_data({
                'uuid': 'test-host',
                'status_hashes': {
                    'wapt\x00status': 'abcdef'
                }
            })

    def test_valid_metadata_reaches_database(self):
        data = {
            'uuid': 'test-host',
            'status_hashes': {
                'wapt_status': 'abcdef'
            }
        }

        original = copy.deepcopy(data)

        with self.assertRaises(AssertionError) as caught:
            update_host_data(data)

        self.assertIn(
            'Database accessed',
            str(caught.exception))

        self.assertEqual(data, original)


if __name__ == '__main__':
    unittest.main(verbosity=2)
