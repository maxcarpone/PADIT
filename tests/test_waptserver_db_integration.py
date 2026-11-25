#!/usr/bin/env python2
# -*- coding: utf-8 -*-

"""PostgreSQL connection cleanup regression tests.

Requires a dedicated temporary PostgreSQL instance.
Never run against a production database.
"""

import sys

USE_EVENTLET = '--eventlet' in sys.argv

if USE_EVENTLET:
    sys.argv.remove('--eventlet')
    from eventlet import monkey_patch
    monkey_patch()

import ast
import os
import logging
import traceback
import threading
import unittest

import peewee
from playhouse.pool import PooledPostgresqlExtDatabase

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from waptutils import ensure_unicode

SOCKET_DIR = os.environ.get('PADIT_TEST_PG', '')

if not (
    SOCKET_DIR.startswith('/tmp/padit-pgtest.')
    and os.path.exists(
        os.path.join(SOCKET_DIR, '.s.PGSQL.55432'))
    and os.path.isfile(
        os.path.join(SOCKET_DIR, 'data', 'PG_VERSION'))
):
    raise RuntimeError('Dedicated PostgreSQL test instance required')


class TestPostgreSQLCleanup(unittest.TestCase):

    def setUp(self):
        self.db = PooledPostgresqlExtDatabase(
            'postgres',
            host=SOCKET_DIR,
            port=55432,
            user='postgres',
            max_connections=90,
            stale_timeout=300,
            timeout=3,
            autoconnect=False,
            options='-c lc_messages=fr_FR.utf8'
        )

        model = os.path.join(ROOT, 'waptserver', 'model.py')

        with open(model) as f:
            tree = ast.parse(f.read(), model)

        names = ('wapt_db_connect', 'wapt_db_close', 'WaptDB')

        nodes = [
            node for node in tree.body
            if getattr(node, 'name', None) in names
        ]

        logger = logging.getLogger('padit_integration')
        logger.setLevel(logging.CRITICAL + 1)

        namespace = {
            'wapt_db': self.db,
            'logger': logger,
            'traceback': traceback,
            'ensure_unicode': ensure_unicode,
        }

        exec compile(ast.Module(body=nodes), model, 'exec') in namespace
        self.WaptDB = namespace['WaptDB']

    def tearDown(self):
        try:
            self.assertEqual(len(self.db._in_use), 0)
        finally:
            self.db.close_all()

    def assert_recovery(self):
        self.assertTrue(self.db.is_closed())
        self.assertEqual(len(self.db._in_use), 0)

        with self.WaptDB():
            self.assertEqual(
                self.db.execute_sql(
                    'SELECT 42').fetchone()[0], 42)

        self.assertEqual(len(self.db._in_use), 0)

    def test_repeated_jsonb_errors(self):
        for index in range(100):
            with self.assertRaises(peewee.DataError):
                with self.WaptDB():
                    self.db.execute_sql(
                        'SELECT %s::jsonb',
                        (r'{"test":"abc\u0000def"}',))

            self.assertTrue(self.db.is_closed())
            self.assertEqual(len(self.db._in_use), 0)

        self.assert_recovery()

    def test_broken_connection(self):
        original = ValueError('Original error')

        try:
            with self.WaptDB():
                conn = self.db.connection()
                conn.close()
                raise original
        except ValueError as caught:
            self.assertIs(caught, original)
        else:
            self.fail('Original exception swallowed')

        self.assertTrue(conn.closed)
        self.assertTrue(all(
            c is not conn for ts, c in self.db._connections))

        self.assert_recovery()

    def test_active_transactions(self):
        for broken in (False, True):
            with self.assertRaises(ValueError):
                with self.WaptDB():
                    conn = self.db.connection()
                    transaction = self.db.transaction()
                    transaction.__enter__()

                    self.assertTrue(self.db.in_transaction())

                    if broken:
                        conn.close()

                    raise ValueError('Original error')

            self.assertTrue(conn.closed)
            self.assertFalse(self.db.in_transaction())
            self.assert_recovery()

    def test_concurrent_connections(self):
        ready = threading.Event()
        proceed = threading.Event()
        errors = []

        def worker():
            try:
                with self.WaptDB():
                    conn = self.db.connection()
                    pid = self.db.execute_sql(
                        'SELECT pg_backend_pid()').fetchone()[0]

                    ready.set()

                    self.assertTrue(proceed.wait(15))
                    self.assertFalse(conn.closed)
                    self.assertIs(self.db.connection(), conn)
                    self.assertEqual(
                        self.db.execute_sql(
                            'SELECT pg_backend_pid()').fetchone()[0],
                        pid)
            except Exception:
                errors.append(traceback.format_exc())
            finally:
                ready.set()

        thread = threading.Thread(target=worker)
        thread.daemon = True
        thread.start()

        try:
            self.assertTrue(ready.wait(15))
            self.assertTrue(self.db.is_closed())
            self.assertEqual(len(self.db._in_use), 1)

            with self.assertRaises(ValueError):
                with self.WaptDB():
                    self.assertEqual(len(self.db._in_use), 2)
                    self.db.connection().close()
                    raise ValueError('Concurrent failure')

            self.assertEqual(len(self.db._in_use), 1)
        finally:
            proceed.set()
            thread.join(20)

        self.assertFalse(thread.is_alive())
        self.assertFalse(errors, errors)
        self.assert_recovery()


if __name__ == '__main__':
    unittest.main(verbosity=2)
