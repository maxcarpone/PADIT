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


def _identity_parameter(value, ptype):
    """Decode text identity fields using WaptDB.get_param semantics."""
    if value is None:
        return ''
    if ptype in ('json', 'bool'):
        try:
            value = json.loads(value)
        except ValueError:
            raise RuntimeError('Invalid JSON in historical identity parameter')
    elif ptype == 'bytes':
        # WAPT on Python 2 converts SQLite TEXT to bytes for this type.
        value = bytes(value)
    elif ptype in ('int', 'float', 'datetime'):
        raise RuntimeError('Historical identity parameter must contain text')
    if value is None:
        return ''
    if not isinstance(value, basestring):
        raise RuntimeError('Historical identity parameter must contain text')
    return value.decode('utf-8') if isinstance(value, str) else value


def _historical_database(database_path, preparation_row_id, preparation_package, check_integrity=False):
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
            ('column_text', [pointer, ctypes.c_int], pointer),
            ('column_bytes', [pointer, ctypes.c_int], ctypes.c_int),
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
                row = []
                for index in range(columns):
                    text = sqlite.sqlite3_column_text(statement, index)
                    row.append(ctypes.string_at(text, sqlite.sqlite3_column_bytes(statement, index))
                               .decode('utf-8') if text else None)
                rows.append(tuple(row))
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
            if check_integrity and query('PRAGMA integrity_check', 1) != [(u'ok',)]:
                raise RuntimeError('Installed SQLite database failed its integrity check')
            params = {}
            for name in ('uuid', 'hostname'):
                rows = query("SELECT value, ptype FROM wapt_params WHERE name='%s' "
                             "ORDER BY create_date DESC LIMIT 1" % name, 2)
                if rows:
                    params[name] = _identity_parameter(*rows[0])
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
                                preparation_task_id=None, check_integrity=False):
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
    if check_integrity:
        params = _historical_database(database_path, preparation_row_id, preparation_package, True)
    else:
        params = _historical_database(database_path, preparation_row_id, preparation_package)
    fake_hostname = config.has_option('global', 'fake_hostname')
    hostname = (config.get('global', 'fake_hostname').decode('utf-8') if fake_hostname
                else setuphelpers.get_hostname())
    registered_uuid = params.get('uuid', '')
    registered_hostname = params.get('hostname', '')
    forced = config.get('global', 'uuid').decode('utf-8') if config.has_option('global', 'uuid') else ''
    if forced:
        uuid, mode = forced, 'configured'
    elif fake_hostname or (config.has_option('global', 'use_fqdn_as_uuid') and
                           config.getboolean('global', 'use_fqdn_as_uuid')):
        uuid, mode = hostname, 'fqdn'
    else:
        try:
            uuid = setuphelpers.wmi_info_basic()['System_Information']['UUID']
        except Exception:
            if not registered_uuid or registered_hostname != hostname:
                raise RuntimeError('Historical UUID fallback is unavailable')
            uuid, mode = registered_uuid, 'stored'
        else:
            mode = 'hardware'
    if (not hostname or not uuid or not re.match(r'\A[a-zA-Z0-9_.{}-]{1,255}\Z', uuid) or
            uuid in ('.', '..') or
            (registered_uuid and registered_uuid != uuid)):
        raise RuntimeError('Current and recorded WAPT identity do not agree')
    return json.dumps(dict(schema_version=1, config_path=config_path,
        database_path=database_path, hostname=hostname, uuid=uuid,
        registered_uuid=registered_uuid or None, identification_mode=mode,
        preparation_pid=os.getpid() if preparation_row_id is not None else None,
        preparation_task_id=preparation_task_id), ensure_ascii=True)


def verify_installed_snapshot(config_path, install_dir, working_dir, expected_uuid, expected_mode):
    """Run under the installed runtime with WAPT stopped. No Wapt object is created."""
    snapshot = json.loads(collect_historical_snapshot(
        config_path, install_dir, working_dir, check_integrity=True))
    if (snapshot['uuid'] != expected_uuid or snapshot['registered_uuid'] != expected_uuid or
            snapshot['identification_mode'] != expected_mode):
        raise RuntimeError('Installed SQLite identity does not match historical identity')
    return snapshot


def prepare_fixture_handoff(snapshot_json, package_dir, approved_manifest_sha256, native_fixture):
    """Drive only the fixture adapter. The native release CLI has no handoff command."""
    if not re.match(r'\A[a-f0-9]{64}\Z', approved_manifest_sha256):
        raise ValueError('Invalid approved fixture manifest digest')
    if not isinstance(snapshot_json, str) or not 0 < len(snapshot_json) <= 65536:
        raise ValueError('Invalid fixture snapshot')
    native_fixture(package_dir, approved_manifest_sha256, snapshot_json)


def _locked_path(path, directory=False):
    from ctypes import wintypes

    kernel = ctypes.windll.kernel32
    create = kernel.CreateFileW
    create.argtypes = (wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p,
                       wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE)
    create.restype = wintypes.HANDLE
    flags = 0x00200000 | (0x02000000 if directory else 0)
    # Directories deny rename/deletion and images deny writes and deletion.
    handle = create(unicode(path), 0x80 if directory else 0x80000000,
                    3 if directory else 1, None, 3, flags, None)
    if handle in (None, ctypes.c_void_p(-1).value):
        raise ctypes.WinError()

    class FileInfo(ctypes.Structure):
        _fields_ = [('attributes', wintypes.DWORD), ('times', wintypes.FILETIME * 3),
                    ('volume', wintypes.DWORD), ('size_high', wintypes.DWORD),
                    ('size_low', wintypes.DWORD), ('links', wintypes.DWORD),
                    ('index_high', wintypes.DWORD), ('index_low', wintypes.DWORD)]

    info = FileInfo()
    try:
        if not kernel.GetFileInformationByHandle(wintypes.HANDLE(handle), ctypes.byref(info)):
            raise ctypes.WinError()
        if (info.attributes & 0x400 or bool(info.attributes & 0x10) != directory or
                (not directory and info.links != 1)):
            raise RuntimeError('Unsafe transition file or directory')
        return handle
    except Exception:
        kernel.CloseHandle(wintypes.HANDLE(handle))
        raise


def _windows_authenticode_signer(path, handle):
    from ctypes import wintypes as w
    from uuid import UUID
    from hashlib import sha256

    class TrustFile(ctypes.Structure):
        _fields_ = [('size', w.DWORD), ('path', w.LPCWSTR), ('handle', w.HANDLE),
                    ('subject', ctypes.c_void_p)]

    class TrustData(ctypes.Structure):
        _fields_ = [('size', w.DWORD), ('callback', ctypes.c_void_p), ('sip', ctypes.c_void_p),
                    ('ui', w.DWORD), ('revocation', w.DWORD), ('choice', w.DWORD),
                    ('file', ctypes.POINTER(TrustFile)), ('action', w.DWORD),
                    ('state', w.HANDLE), ('url', w.LPCWSTR), ('flags', w.DWORD), ('context', w.DWORD)]

    class Certificate(ctypes.Structure):
        _fields_ = [('encoding', w.DWORD), ('bytes', ctypes.c_void_p), ('length', w.DWORD)]

    class ProviderCert(ctypes.Structure):
        _fields_ = [('size', w.DWORD), ('certificate', ctypes.POINTER(Certificate))]

    trust = ctypes.windll.wintrust
    verify = trust.WinVerifyTrust
    verify.argtypes = (w.HWND, ctypes.c_void_p, ctypes.POINTER(TrustData))
    verify.restype = w.LONG
    provider = trust.WTHelperProvDataFromStateData
    provider.argtypes, provider.restype = (w.HANDLE,), ctypes.c_void_p
    signer = trust.WTHelperGetProvSignerFromChain
    signer.argtypes, signer.restype = (ctypes.c_void_p, w.DWORD, w.BOOL, w.DWORD), ctypes.c_void_p
    cert = trust.WTHelperGetProvCertFromChain
    cert.argtypes, cert.restype = (ctypes.c_void_p, w.DWORD), ctypes.POINTER(ProviderCert)
    action = ctypes.create_string_buffer(UUID('00AAC56B-CD44-11D0-8CC2-00C04FC295EE').bytes_le)
    image = TrustFile(ctypes.sizeof(TrustFile), unicode(path), handle, None)
    data = TrustData(ctypes.sizeof(TrustData), None, None, 2, 1, 1, ctypes.pointer(image),
                     1, None, None, 0x80 | 0x1000 | 0x2000, 0)
    try:
        if verify(w.HWND(-1), action, ctypes.byref(data)) != 0:
            raise RuntimeError('Authenticode verification failed')
        chain = provider(data.state)
        selected = signer(chain, 0, False, 0) if chain else None
        candidate = cert(selected, 0) if selected else None
        if not candidate or not candidate.contents.certificate:
            raise RuntimeError('Authenticode signer certificate missing')
        leaf = candidate.contents.certificate.contents
        return sha256(ctypes.string_at(leaf.bytes, leaf.length)).hexdigest()
    finally:
        if data.state:
            data.action = 2
            verify(w.HWND(-1), action, ctypes.byref(data))


def _authenticate_transition_package(wapt, entry, package_dir):
    from zipfile import is_zipfile

    if (not entry.localpath or not os.path.isfile(entry.localpath) or
            not is_zipfile(entry.localpath) or entry._default_md != 'sha256' or
            os.path.normcase(os.path.abspath(entry.sourcespath or '')) != os.path.normcase(package_dir)):
        raise RuntimeError('Transition requires an authenticated WAPT archive')
    if not entry.check_package_signature(wapt.cabundle):
        raise RuntimeError('Transition package signer did not authenticate its contents')


def _approval_for_locked_package(wapt, entry, package_dir, signer_for, images, read):
    """Use the historical WAPT chain and the signed contents, never an executable's claimed pin."""
    import hashlib

    _authenticate_transition_package(wapt, entry, package_dir)

    manifest = read('transition.json', 65536)
    policy_bytes = read('signer-policy.json', 4096)
    policy = json.loads(policy_bytes)
    roles = {'engine_sha256': 'patchs/wapttransition.exe', 'installer_sha256': 'waptagent.exe'}
    if (not isinstance(policy, dict) or set(policy) != set(roles) or
            any(not isinstance(pin, basestring) or not re.match(r'\A[0-9a-f]{64}\Z', pin)
                for pin in policy.values())):
        raise RuntimeError('Invalid transition signer policy')
    metadata = json.loads(manifest)
    if (metadata.get('schema_version') != 2 or metadata.get('deployable') is not False or
            metadata['components_sha256'].get('signer-policy.json') != hashlib.sha256(policy_bytes).hexdigest()):
        raise RuntimeError('Transition manifest does not authenticate the signer policy')
    for role, name in sorted(roles.items()):
        path, handle = images[name]
        digest = hashlib.sha256()
        with open(path, 'rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), ''):
                digest.update(block)
        if metadata['components_sha256'].get(name) != digest.hexdigest():
            raise RuntimeError('Transition image differs from the approved manifest')
        if signer_for(path, handle) != policy[role]:
            raise RuntimeError('Unauthorized Authenticode signer for %s' % role)
    return hashlib.sha256(manifest).hexdigest()


def _check_protected_payload(path):
    import win32security

    # Match the owners and allow-list used by the native protected storage.
    info = win32security.GetNamedSecurityInfo(
        path, win32security.SE_FILE_OBJECT,
        win32security.OWNER_SECURITY_INFORMATION | win32security.DACL_SECURITY_INFORMATION)
    trusted = set(('S-1-5-18', 'S-1-5-32-544'))
    owner = win32security.ConvertSidToStringSid(info.GetSecurityDescriptorOwner())
    acl = info.GetSecurityDescriptorDacl()
    if owner not in trusted or acl is None or acl.GetAceCount() != 2:
        raise RuntimeError('Unsafe first-launch staging permissions')
    allowed = set()
    for index in range(acl.GetAceCount()):
        header, mask, sid = acl.GetAce(index)
        if header[0] != 0 or mask != 0x1f01ff:
            raise RuntimeError('Unsafe first-launch staging access entry')
        allowed.add(win32security.ConvertSidToStringSid(sid))
    if allowed != trusted:
        raise RuntimeError('Unsafe first-launch staging access entries')


def with_verified_transition_engine(wapt, entry, package_dir, protected_payload_dir, use_engine):
    """Gate future first use. The callback must start the approved image before returning."""
    from ctypes import wintypes

    package_dir = os.path.abspath(package_dir)
    protected_payload_dir = os.path.abspath(protected_payload_dir)
    if os.path.normcase(package_dir) == os.path.normcase(protected_payload_dir):
        raise RuntimeError('The first native launch requires a protected staged copy')
    if not entry.localpath or not os.path.isfile(entry.localpath):
        raise RuntimeError('Transition requires an authenticated WAPT archive')
    if entry._default_md != 'sha256':
        raise RuntimeError('Transition requires a SHA256-signed WAPT manifest')

    def ancestors(path):
        chain = []
        while path != os.path.dirname(path):
            chain.append(path)
            path = os.path.dirname(path)
        return reversed(chain)
    handles = []
    paths = {}
    try:
        directories = set()
        for root in (os.path.dirname(os.path.abspath(entry.localpath)), package_dir, protected_payload_dir):
            for directory in ancestors(root):
                if directory not in directories:
                    handles.append(_locked_path(directory, directory=True))
                    directories.add(directory)
        handles.append(_locked_path(os.path.abspath(entry.localpath)))
        handles.append(_locked_path(os.path.join(package_dir, 'WAPT'), directory=True))
        for name in (entry.get_manifest_filename('sha256'), entry.get_signature_filename('sha256')):
            handles.append(_locked_path(os.path.join(package_dir, *name.split('/'))))
        handles.append(_locked_path(os.path.join(protected_payload_dir, 'patchs'), directory=True))
        for name in ('transition.json', 'signer-policy.json'):
            path = os.path.join(package_dir, name)
            handle = _locked_path(path)
            handles.append(handle)
            paths[name] = (path, handle)
        for name in ('waptagent.exe', 'patchs/wapttransition.exe'):
            path = os.path.join(protected_payload_dir, *name.split('/'))
            handle = _locked_path(path)
            handles.append(handle)
            paths[name] = (path, handle)

        def read(name, maximum):
            with open(paths[name][0], 'rb') as stream:
                data = stream.read(maximum + 1)
            if not 0 < len(data) <= maximum:
                raise RuntimeError('Invalid transition document size')
            return data

        for path in (protected_payload_dir, os.path.join(protected_payload_dir, 'patchs'),
                     paths['waptagent.exe'][0], paths['patchs/wapttransition.exe'][0]):
            _check_protected_payload(path)
        for name, maximum in (('transition.json', 65536), ('signer-policy.json', 4096)):
            staged_path = os.path.join(protected_payload_dir, name)
            handles.append(_locked_path(staged_path))
            _check_protected_payload(staged_path)
            with open(staged_path, 'rb') as staged:
                if staged.read(maximum + 1) != read(name, maximum):
                    raise RuntimeError('Staged approval documents differ from the authenticated package')
        digest = _approval_for_locked_package(wapt, entry, package_dir, _windows_authenticode_signer, paths, read)
        return use_engine(paths['patchs/wapttransition.exe'][0], digest)
    finally:
        for handle in reversed(handles):
            ctypes.windll.kernel32.CloseHandle(wintypes.HANDLE(handle))


def record_verified_transition_payload(wapt, entry, package_dir, protected_payload_dir):
    """Record staged approval without activating the relay or migration."""
    import subprocess

    def record(image, digest):
        return subprocess.check_call([image, '--record-authenticated-payload', digest],
                                     cwd=protected_payload_dir, shell=False)

    return with_verified_transition_engine(wapt, entry, package_dir, protected_payload_dir, record)


def install_fixture(wapt, entry, package_dir, fixture, config_path, install_dir, working_dir):
    """Exercise the package hook with an explicit fixture adapter only."""
    from hashlib import sha256

    package_dir = os.path.abspath(package_dir)
    snapshot = collect_historical_snapshot(config_path, install_dir, working_dir)
    _authenticate_transition_package(wapt, entry, package_dir)
    with open(os.path.join(package_dir, 'transition.json'), 'rb') as manifest:
        contents = manifest.read(65537)
    if not 0 < len(contents) <= 65536:
        raise RuntimeError('Invalid transition manifest size')
    payload = fixture.stage(package_dir, sha256(contents).hexdigest())

    def record(image, approved_digest):
        fixture.record(image, snapshot, approved_digest)

    with_verified_transition_engine(wapt, entry, package_dir, payload, record)
    # Recording precedes scheduling so the latter can be retried without package files.
    return fixture.program()


def install():
    raise RuntimeError('PADIT transition package: not deployable')
