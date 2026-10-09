# -*- coding: utf-8 -*-
"""PADIT M10 - Peewee 3.14.10 server compatibility tests."""

from __future__ import print_function

import os
import shutil
import tempfile

import peewee
from huey.contrib.sqlitedb import SqliteHuey


def test_transactions():
    db = peewee.SqliteDatabase(':memory:')

    class Base(peewee.Model):
        class Meta:
            database = db

    class Host(Base):
        uuid = peewee.CharField(unique=True)
        status = peewee.CharField()

    with db:
        db.create_tables([Host])

        with db.atomic():
            Host.create(uuid='host-001', status='OK')

        try:
            with db.atomic():
                Host.create(uuid='host-002', status='TEMP')
                raise ValueError('rollback test')
        except ValueError:
            pass

        assert Host.select().count() == 1

        Host.insert(
            uuid='host-001',
            status='DUPLICATE'
        ).on_conflict('IGNORE').execute()

        assert Host.select().count() == 1
        assert Host.get(Host.uuid == 'host-001').status == 'OK'

    print('Peewee transactions/rollback: PASS')
    print('Peewee ON CONFLICT IGNORE: PASS')


def test_huey():
    root = tempfile.mkdtemp(prefix='padit-m10-')
    dbpath = os.path.join(root, 'huey.sqlite')

    try:
        queue = SqliteHuey('padit-m10', filename=dbpath)

        @queue.task(name='padit_m10_test')
        def test_task(value):
            return value * 2

        result = test_task(21)
        assert queue.pending_count() == 1

        task = queue.dequeue()
        assert task is not None

        queue.execute(task)

        assert result.get(blocking=False) == 42
        assert queue.pending_count() == 0

        print('Huey SQLite integration: PASS')
    finally:
        shutil.rmtree(root)


def test_padit_model():
    from waptserver import model
    assert model is not None
    print('PADIT server model import: PASS')


def main():
    assert peewee.__version__ == '3.14.10', peewee.__version__

    test_transactions()
    test_huey()
    test_padit_model()

    print('PADIT SERVER DEPENDENCIES M10: PASS')


if __name__ == '__main__':
    main()
