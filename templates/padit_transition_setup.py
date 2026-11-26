# -*- coding: utf-8 -*-
"""Preparation helpers for a future PADIT transition package activation."""

import ctypes
import json
import os
import re
from contextlib import contextmanager


@contextmanager
def _rollback_database_guard(database_path):
    """Keep SQLite rollback-journal mode stable while a read connection is open."""
    from ctypes import wintypes
    import msvcrt

    class Overlapped(ctypes.Structure):
        _fields_ = [('internal', ctypes.c_size_t), ('internal_high', ctypes.c_size_t),
                    ('offset', wintypes.DWORD), ('offset_high', wintypes.DWORD),
                    ('event', wintypes.HANDLE)]

    lock = ctypes.windll.kernel32.LockFileEx
    lock.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.DWORD,
                     wintypes.DWORD, wintypes.DWORD, ctypes.POINTER(Overlapped)]
    lock.restype = wintypes.BOOL
    with open(database_path, 'rb') as stream:
        # A shared Windows lock on SQLite's shared-lock range prevents an
        # exclusive mode change before SQLite takes its normal read locks.
        position = Overlapped()
        position.offset = 0x40000002  # SQLite SHARED_FIRST
        if not lock(msvcrt.get_osfhandle(stream.fileno()), 1, 0, 510, 0, ctypes.byref(position)):
            raise RuntimeError('Historical database is busy')
        header = stream.read(20)
        if len(header) != 20 or header[:16] != 'SQLite format 3\x00' or header[18:20] != '\x01\x01':
            raise RuntimeError('Historical SQLite requires rollback-journal mode')
        yield


def _historical_database(database_path, preparation_row_id, preparation_package):
    """Query a single SQLite read transaction using the historical Python DLL."""
    import _sqlite3

    module_path = _sqlite3.__file__
    if isinstance(module_path, str):
        module_path = module_path.decode('mbcs')
    library = os.path.join(os.path.dirname(os.path.abspath(module_path)), u'sqlite3.dll')
    if not os.path.isfile(library):
        raise RuntimeError('Historical Python SQLite library unavailable')
    # Reuse the module already loaded by Python and require its expected path.
    kernel = ctypes.windll.kernel32
    module_name = kernel.GetModuleFileNameW
    module_name.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_uint]
    module_name.restype = ctypes.c_uint
    module_handle = kernel.GetModuleHandleW
    module_handle.argtypes = [ctypes.c_wchar_p]
    module_handle.restype = ctypes.c_void_p
    handle = module_handle(u'sqlite3.dll')
    actual = ctypes.create_unicode_buffer(32768)
    size = module_name(handle, actual, len(actual)) if handle else 0
    if not 0 < size < len(actual) or os.path.normcase(actual.value) != os.path.normcase(library):
        raise RuntimeError('Cannot identify the SQLite library loaded by historical Python')
    sqlite = ctypes.CDLL(library, handle=handle)
    pointer = ctypes.c_void_p
    for name, args, result in (
            ('open_v2', [ctypes.c_char_p, ctypes.POINTER(pointer), ctypes.c_int, ctypes.c_char_p], ctypes.c_int),
            ('prepare_v2', [pointer, ctypes.c_char_p, ctypes.c_int, ctypes.POINTER(pointer), pointer], ctypes.c_int),
            ('step', [pointer], ctypes.c_int),
            ('column_text', [pointer, ctypes.c_int], ctypes.c_char_p),
            ('bind_int64', [pointer, ctypes.c_int, ctypes.c_longlong], ctypes.c_int),
            ('finalize', [pointer], ctypes.c_int),
            ('close', [pointer], ctypes.c_int)):
        function = getattr(sqlite, 'sqlite3_' + name)
        function.argtypes = args
        function.restype = result

    def query(sql, columns=0, row_id=None):
        statement = pointer()
        try:
            if sqlite.sqlite3_prepare_v2(db, sql, -1, ctypes.byref(statement), None) != 0:
                raise RuntimeError('Historical SQLite query could not be prepared')
            if row_id is not None and sqlite.sqlite3_bind_int64(statement, 1, row_id) != 0:
                raise RuntimeError('Historical installation identifier could not be bound')
            rows = []
            while True:
                status = sqlite.sqlite3_step(statement)
                if status == 101:  # SQLITE_DONE
                    return rows
                if status != 100:  # SQLITE_ROW
                    raise RuntimeError('Historical SQLite read failed or database is busy')
                rows.append(tuple((sqlite.sqlite3_column_text(statement, index) or '').decode('utf-8')
                                  for index in range(columns)))
        finally:
            if statement:
                sqlite.sqlite3_finalize(statement)

    with _rollback_database_guard(database_path):
        db = pointer()
        try:
            # SQLITE_OPEN_READONLY. A missing database is never created.
            if sqlite.sqlite3_open_v2(database_path.encode('utf-8'), ctypes.byref(db), 1, None) != 0:
                raise RuntimeError('Cannot open historical SQLite read-only')
            query('BEGIN')
            params = dict(query(
                "SELECT name, value FROM wapt_params WHERE name IN ('uuid', 'hostname') "
                "ORDER BY create_date ASC", 2))
            if preparation_row_id is not None:
                own = query("SELECT package, process_id FROM wapt_localstatus WHERE id = ? "
                            "AND install_status IN ('INIT','DOWNLOAD','RUNNING')", 2, preparation_row_id)
                if own != [(preparation_package, unicode(os.getpid()))]:
                    raise RuntimeError('WAPT preparation installation record does not match this process')
            active = ("SELECT 1 FROM wapt_localstatus WHERE install_status IN "
                      "('INIT','DOWNLOAD','RUNNING')")
            if preparation_row_id is not None:
                active += ' AND id <> ?'
            if query(active + ' LIMIT 1', 1, preparation_row_id):
                raise RuntimeError('Another WAPT installation is active')
            return params
        finally:
            if db:
                sqlite.sqlite3_close(db)


def collect_historical_snapshot(config_path, install_dir, working_dir,
                                preparation_row_id=None, preparation_package=None,
                                preparation_task_id=None):
    """Return JSON bytes for native staging. Only the future orchestrator may call this."""
    from ConfigParser import RawConfigParser
    import setuphelpers

    if preparation_row_id is not None and (
            type(preparation_row_id) not in (int, long) or
            not 0 < preparation_row_id <= 0x7fffffffffffffff or not preparation_package):
        raise ValueError('Invalid WAPT preparation installation identifier')
    if preparation_task_id is not None and (
            preparation_row_id is None or type(preparation_task_id) not in (int, long) or
            not 0 < preparation_task_id <= 0x7fffffff):
        raise ValueError('Invalid WAPT preparation task identifier')
    config = RawConfigParser()
    with open(config_path, 'rb') as stream:
        config.readfp(stream)
    if not config.has_section('global'):
        raise RuntimeError('Historical WAPT configuration has no global section')
    if config.has_option('global', 'dbpath'):
        database_path = config.get('global', 'dbpath').decode('utf-8')
        database_path = os.path.abspath(os.path.join(working_dir, database_path))
    else:
        database_path = os.path.join(install_dir, u'db', u'waptdb.sqlite')
    params = _historical_database(database_path, preparation_row_id, preparation_package)
    hostname = setuphelpers.get_hostname().lower()
    registered_uuid = params.get('uuid', '')
    registered_hostname = params.get('hostname', '')
    forced = config.get('global', 'uuid').decode('utf-8') if config.has_option('global', 'uuid') else ''
    if forced:
        uuid, mode = forced, 'configured'
    elif config.has_option('global', 'use_fqdn_as_uuid') and config.getboolean('global', 'use_fqdn_as_uuid'):
        uuid, mode = hostname, 'fqdn'
    else:
        try:
            uuid = setuphelpers.wmi_info_basic()['System_Information']['UUID']
        except Exception:
            if not registered_uuid or registered_hostname.lower() != hostname:
                raise RuntimeError('Historical UUID fallback is unavailable')
            uuid, mode = registered_uuid, 'stored'
        else:
            mode = 'hardware'
    if (not hostname or not uuid or not re.match(r'\A[a-zA-Z0-9_.{}-]{1,255}\Z', uuid) or
            uuid in ('.', '..') or
            (registered_uuid and registered_uuid != uuid) or
            (registered_hostname and registered_hostname.lower() != hostname)):
        raise RuntimeError('Current and recorded WAPT identity do not agree')
    return json.dumps(dict(schema_version=1, config_path=config_path,
        database_path=database_path, hostname=hostname, uuid=uuid,
        registered_uuid=registered_uuid or None, identification_mode=mode,
        preparation_pid=os.getpid() if preparation_row_id is not None else None,
        preparation_task_id=preparation_task_id), ensure_ascii=True)


def install():
    raise RuntimeError('PADIT transition package: not deployable')
