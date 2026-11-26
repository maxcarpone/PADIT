# -*- coding: utf-8 -*-
import imp
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import types
import unittest

collector = imp.load_source('padit_transition_setup', os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    'templates', 'padit_transition_setup.py'))


class HistoricalSnapshotTest(unittest.TestCase):

    def setUp(self):
        self.root = tempfile.mkdtemp().decode('mbcs')
        self.addCleanup(shutil.rmtree, self.root)
        self.ini = os.path.join(self.root, u'config \u6f22.ini')
        self.db = os.path.join(self.root, u'db \u6f22.sqlite')
        self.sql('CREATE TABLE wapt_params(name,value,create_date)')
        self.sql('CREATE TABLE wapt_localstatus(id INTEGER PRIMARY KEY,package,process_id,install_status)')
        self.sql("INSERT INTO wapt_params VALUES ('uuid','fixture-id','2026')")
        self.sql("INSERT INTO wapt_params VALUES ('hostname','fixture.example.test','2026')")
        self.hardware = 'fixture-id'
        old = sys.modules.get('setuphelpers')
        self.addCleanup(self.restore_helpers, old)
        helpers = types.ModuleType('setuphelpers')
        helpers.get_hostname = lambda: 'fixture.example.test'
        helpers.wmi_info_basic = self.firmware
        sys.modules['setuphelpers'] = helpers

    def restore_helpers(self, old):
        if old is None:
            del sys.modules['setuphelpers']
        else:
            sys.modules['setuphelpers'] = old

    def firmware(self):
        if self.hardware is None:
            raise OSError('Fixture firmware unavailable')
        return {'System_Information': {'UUID': self.hardware}}

    def sql(self, statement, args=()):
        db = sqlite3.connect(self.db)
        try:
            rows = db.execute(statement, args).fetchall()
            db.commit()
            return rows
        finally:
            db.close()

    def collect(self, config='', **kwargs):
        with open(self.ini, 'wb') as stream:
            stream.write((u'[global]\ndbpath = db \u6f22.sqlite\n' + config).encode('utf-8'))
        return json.loads(collector.collect_historical_snapshot(
            self.ini, self.root, self.root, **kwargs))

    def test_identity_priority_and_non_destructive_read(self):
        with open(self.db, 'rb') as stream:
            before = stream.read()
        self.assertEqual(self.collect('uuid = fixture-id\nuse_fqdn_as_uuid = 1')['identification_mode'],
                         'configured')
        self.assertEqual(self.collect()['identification_mode'], 'hardware')
        self.hardware = None
        self.assertEqual(self.collect()['identification_mode'], 'stored')
        with open(self.db, 'rb') as stream:
            self.assertEqual(stream.read(), before)
        self.assertFalse(os.path.exists(self.db + '-journal'))
        self.sql("UPDATE wapt_params SET value='fixture.example.test' WHERE name='uuid'")
        self.assertEqual(self.collect('use_fqdn_as_uuid = yes')['identification_mode'], 'fqdn')

    def test_identity_disagreement_and_unsafe_fallback(self):
        self.assertRaises(RuntimeError, self.collect, 'uuid = different')
        self.hardware = 'different'
        self.assertRaises(RuntimeError, self.collect)
        self.hardware = None
        self.sql("UPDATE wapt_params SET value='different.example.test' WHERE name='hostname'")
        self.assertRaises(RuntimeError, self.collect)

    def test_preparation_exemption_checks_exact_row_package_and_pid(self):
        self.sql("INSERT INTO wapt_localstatus VALUES (17,'fixture-padit-transition',?,'RUNNING')",
                 (os.getpid(),))
        self.assertRaises(RuntimeError, self.collect)
        args = dict(preparation_row_id=17, preparation_package='fixture-padit-transition',
                    preparation_task_id=8)
        self.assertEqual(self.collect(**args)['preparation_task_id'], 8)
        self.assertEqual(self.collect(**args)['preparation_pid'], os.getpid())
        self.sql("INSERT INTO wapt_localstatus VALUES (18,'other',?,'INIT')", (os.getpid(),))
        self.assertRaises(RuntimeError, self.collect, **args)
        self.sql('DELETE FROM wapt_localstatus WHERE id=18')
        self.sql('UPDATE wapt_localstatus SET process_id=1')
        self.assertRaises(RuntimeError, self.collect, **args)

    def test_wal_and_missing_database_are_refused(self):
        self.assertEqual(self.sql('PRAGMA journal_mode=WAL')[0][0], 'wal')
        self.assertRaises(RuntimeError, self.collect)
        self.assertFalse(os.path.exists(self.db + '-wal'))
        self.assertFalse(os.path.exists(self.db + '-shm'))
        os.remove(self.db)
        self.assertRaises(IOError, self.collect)
        self.assertFalse(os.path.exists(self.db))

    def test_exclusive_writer_blocks_collector(self):
        db = sqlite3.connect(self.db)
        try:
            db.execute('BEGIN EXCLUSIVE')
            self.assertRaises(RuntimeError, self.collect)
        finally:
            db.close()

    def test_install_remains_disabled(self):
        self.assertRaises(RuntimeError, collector.install)


if __name__ == '__main__':
    unittest.main()
