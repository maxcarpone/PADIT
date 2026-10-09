# -*- coding: utf-8 -*-
"""PADIT M07 - Huey 1.10.5 compatibility regression tests."""

from __future__ import print_function

import os
import shutil
import tempfile

import pkg_resources
from huey import crontab
from huey.api import Huey, create_task
from huey.bin import huey_consumer
from huey.contrib.sqlitedb import SqliteHuey, SqliteStorage


def main():
    version = pkg_resources.get_distribution('huey').version
    assert version == '1.10.5', version

    assert callable(create_task)
    assert callable(huey_consumer.consumer_main)

    testdir = tempfile.mkdtemp(prefix='padit-m07-')
    dbpath = os.path.join(testdir, 'tasks.sqlite')

    try:
        huey = SqliteHuey('padit-m07', filename=dbpath)

        # Reproduce the exact decorator combination in waptserver/tasks.py.
        @huey.task(include_task=True, name='resign_crl')
        @huey.periodic_task(crontab(minute='0', hour='*/1'))
        def resign_crl():
            return 'PADIT CRL test'

        keys = sorted(huey.registry._registry)
        assert keys == ['queue_task_resign_crl', 'resign_crl'], keys
        assert len(huey.registry.get_periodic_tasks()) == 1
        print('Legacy decorators: PASS')

        # Separate task for SQLite enqueue/dequeue/execution.
        @huey.task(name='padit_m07_test_task')
        def test_task(value):
            return value + 1

        result = test_task(41)
        assert huey.pending_count() == 1

        task = huey.dequeue()
        assert task is not None

        huey.execute(task)
        assert result.get(blocking=False) == 42
        assert huey.pending_count() == 0
        print('SQLite execution: PASS')

        # Preserve the behavior of a missing/empty queue.
        assert huey.dequeue() is None

        print('PADIT SERVER DEPENDENCIES M07: PASS')
    finally:
        shutil.rmtree(testdir)


if __name__ == '__main__':
    main()
