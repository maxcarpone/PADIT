#!/usr/bin/env python2
# -*- coding: utf-8 -*-

"""Regression tests for WaptDB connection cleanup."""

import ast
import logging
import os
import traceback
import threading
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODEL = os.path.join(ROOT, 'waptserver', 'model.py')


class FakeConnection(object):

    def __init__(self, db):
        self.db = db

    def close(self):
        self.db.discard_calls += 1


class FakeDB(object):

    def __init__(self):
        self.open = False
        self.transaction = False
        self.close_calls = 0
        self.rollback_calls = 0
        self.discard_calls = 0
        self._lock = threading.RLock()
        self._state = self
        self._in_use = {}
        self.conn = FakeConnection(self)
        self.conn_key = id

    def connection(self):
        return self.conn

    def reset(self):
        self.open = False
        self.transaction = False

    def in_transaction(self):
        return self.transaction

    def rollback(self):
        self.rollback_calls += 1

    def is_closed(self):
        return not self.open

    def connect(self):
        self.open = True
        self._in_use[id(self.conn)] = self.conn

    def close(self):
        self.close_calls += 1
        self._in_use.pop(id(self.conn), None)
        self.reset()

    def manual_close(self):
        self.discard_calls += 1
        self.open = False


class TestWaptDBCleanup(unittest.TestCase):

    def setUp(self):
        self.db = FakeDB()
        self.logger = logging.getLogger('test_waptdb')
        self.logger.setLevel(logging.CRITICAL + 1)

        tree = ast.parse(open(MODEL).read(), MODEL)

        names = (
            'wapt_db_connect',
            'wapt_db_close',
            'WaptDB',
        )

        nodes = [
            node for node in tree.body
            if getattr(node, 'name', None) in names
        ]

        self.db._in_use = {}

        namespace = {
            'wapt_db': self.db,
            'logger': self.logger,
            'traceback': traceback,
            'ensure_unicode': self.ensure_unicode,
        }

        exec compile(ast.Module(body=nodes), MODEL, 'exec') in namespace
        self.WaptDB = namespace['WaptDB']

    def tearDown(self):
        self.assertEqual(len(self.db._in_use), 0)

    @staticmethod
    def ensure_unicode(value):
        if isinstance(value, unicode):
            return value
        return str(value).decode('utf-8', 'replace')

    def test_logger_failure(self):
        def broken_logger(*args, **kwargs):
            raise RuntimeError('Logging failure')

        original_debug = self.logger.debug

        try:
            with self.WaptDB():
                self.logger.debug = broken_logger
        finally:
            self.logger.debug = original_debug

        self.assertFalse(self.db.open)

    def test_rollback_failure(self):
        def broken_rollback():
            raise RuntimeError('Rollback failure')

        self.db.rollback = broken_rollback

        with self.assertRaises(ValueError):
            with self.WaptDB():
                self.db.transaction = True
                raise ValueError('Original error')

        self.assertFalse(self.db.open)
        self.assertEqual(self.db.discard_calls, 1)
        self.assertEqual(self.db.close_calls, 0)

    def test_close_failure(self):
        def broken_close():
            raise RuntimeError('Close failure')

        self.db.close = broken_close

        with self.assertRaises(ValueError):
            with self.WaptDB():
                raise ValueError('Original error')

        self.assertFalse(self.db.open)
        self.assertEqual(self.db.discard_calls, 1)

    def test_normal_exit(self):
        with self.WaptDB():
            self.assertTrue(self.db.open)

        self.assertFalse(self.db.open)
        self.assertEqual(self.db.close_calls, 1)

    def test_ascii_exception(self):
        with self.assertRaises(ValueError):
            with self.WaptDB():
                raise ValueError('Database error')

        self.assertFalse(self.db.open)

    def test_unicode_exception(self):
        with self.assertRaises(ValueError):
            with self.WaptDB():
                raise ValueError('Erreur : s\xc3\xa9quence Unicode')

        self.assertFalse(self.db.open)

    def test_nested_contexts(self):
        with self.WaptDB():
            with self.WaptDB():
                self.assertTrue(self.db.open)

            self.assertTrue(self.db.open)
            self.assertEqual(self.db.close_calls, 0)

        self.assertFalse(self.db.open)
        self.assertEqual(self.db.close_calls, 1)

    def test_original_exception_preserved(self):
        original = ValueError('Erreur : s\xc3\xa9quence Unicode')

        try:
            with self.WaptDB():
                raise original
        except ValueError as caught:
            self.assertIs(caught, original)
        else:
            self.fail('Original exception was swallowed')

    def test_repeated_unicode_errors(self):
        for index in range(100):
            with self.assertRaises(ValueError):
                with self.WaptDB():
                    raise ValueError('Erreur : s\xc3\xa9quence Unicode')

        self.assertFalse(self.db.open)
        self.assertEqual(self.db.close_calls, 100)


if __name__ == '__main__':
    logging.basicConfig(level=logging.CRITICAL + 1)
    unittest.main(verbosity=2)
