# -*- coding: utf-8 -*-
"""Offline Windows tests for the PADIT transition package generator."""
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import tempfile
import unittest
import zipfile

from iniparse import RawConfigParser

import common
import waptdevutils
from waptcrypto import SSLPrivateKey
from waptpackage import PackageEntry


class OfflineRepository(object):
    def __init__(self):
        self.entries = []
        self.updates = 0
        self.request = None

    def update(self):
        self.updates += 1

    def packages_matching(self, request):
        self.request = request.request
        return self.entries


class OfflineConsole(object):
    sign_digests = ['sha256', 'sha1']
    progress_hook = None

    def __init__(self, base, cert_path, cert, key):
        self.wapt_base_dir = base
        self.personal_certificate_path = cert_path
        self.cert = cert
        self.key = key
        self.config = RawConfigParser()
        self.config.add_section('global')
        self.config.set('global', 'default_package_prefix', 'test-site')
        self.uploads = []
        self.projects = []

    def as_dict(self):
        return {'wapt_base_dir': self.wapt_base_dir}

    def add_pyscripter_project(self, sources):
        common.Wapt.add_pyscripter_project.im_func(self, sources)
        self.projects.append('pyscripter')

    def add_vscode_project(self, sources):
        common.Wapt.add_vscode_project.im_func(self, sources)
        self.projects.append('vscode')

    def personal_certificate(self):
        return [self.cert]

    def private_key(self, private_key_password=None):
        if private_key_password != 'key-password-test':
            raise AssertionError('Wrong signing password')
        return self.key

    def is_available(self, request):
        return []

    is_wapt_package_development_dir = common.Wapt.is_wapt_package_development_dir.im_func

    def http_upload_package(self, path, **options):
        PackageEntry(waptfile=path).unzip_package(
            target_dir=os.path.join(self.wapt_base_dir, 'verified-upload'), cabundle=self.cert)
        self.uploads.append(options)
        return {'success': True, 'result': {'ok': [{'success': True}], 'errors': []},
                'msg': '1 Packages uploaded, 0 errors'}


class TransitionPackageTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.key = SSLPrivateKey().create()
        cls.cert = cls.key.build_sign_certificate(cn='Offline transition tests', is_code_signing=True)

    def setUp(self):
        self.root = tempfile.mkdtemp(prefix='test-padit-transition-')
        self.addCleanup(shutil.rmtree, self.root)
        self.output = os.path.join(self.root, 'output')
        os.mkdir(self.output)
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        shutil.copytree(os.path.join(root, 'templates'), os.path.join(self.root, 'templates'))
        self.agent = self.write('fixture.exe', 'inert installer fixture')
        self.write('wapttransition.exe', 'inert engine fixture')
        cert_path = self.write('test.pem', self.cert.as_pem() + self.key.as_pem())
        self.repo = OfflineRepository()
        self.console = OfflineConsole(self.root, cert_path, self.cert, self.key)
        self.arguments = dict(wapt=self.console, mainrepo=self.repo, agent_path=self.agent,
                              source_server_url='http://source.example.test:8080/wapt',
                              target_server_url='https://target.example.test',
                              target_repo_url='https://repo.example.test:8443/wapt',
                              https_certificate_path=cert_path, package_certificate_path=cert_path,
                              target_directory=self.output, key_password='key-password-test')
        self.release_signature_check = waptdevutils._verify_transition_executable
        self.signature_checks = []
        self.addCleanup(setattr, waptdevutils, '_verify_transition_executable', self.release_signature_check)
        def verify_fixture(path):
            self.signature_checks.append(os.path.basename(path))
            with open(path, 'rb') as stream:
                return hashlib.sha256(stream.read()).hexdigest(), 'b' * 64 if os.path.basename(path) == 'waptagent.exe' else 'a' * 64
        waptdevutils._verify_transition_executable = verify_fixture
        original = waptdevutils.get_file_properties
        self.addCleanup(setattr, waptdevutils, 'get_file_properties', original)
        waptdevutils.get_file_properties = self.installer_properties

    def write(self, name, data):
        path = os.path.join(self.root, name)
        with open(path, 'wb') as output:
            output.write(data)
        return path

    def installer_properties(self, path):
        self.assertEqual(os.path.basename(path), 'waptagent.exe')
        with open(path, 'rb') as source:
            self.assertEqual(source.read(), 'inert installer fixture')
        return {'FileVersion': '1.8.3.7759'}

    def build(self, **options):
        arguments = dict(self.arguments, **options)
        return waptdevutils.build_transition_package(**arguments)

    def test_structure_hash_signature_and_no_secrets(self):
        result = self.build(wapt_server_user='admin-test', wapt_server_passwd='server-password-test')
        self.assertEqual(result['package'], 'test-site-padit-transition')
        self.assertEqual(result['version'], '1.8.3.7759-1')
        self.assertFalse(result['deployable'])
        self.assertEqual(self.console.uploads, [])
        self.assertEqual(self.console.projects, [])
        path = result['localpath']
        entry = PackageEntry(waptfile=path)
        self.assertEqual(entry.target_os, 'windows')
        self.assertEqual(entry.min_wapt_version, '1.8.2')
        self.assertEqual(entry.impacted_process, 'waptconsole,waptself')
        self.assertIn('NOT DEPLOYABLE', entry.description)
        entry.unzip_package(target_dir=os.path.join(self.root, 'verified'), cabundle=self.cert)
        with zipfile.ZipFile(path) as package:
            names = set(package.namelist())
            self.assertTrue({'WAPT/control', 'setup.py', 'transition.json', 'waptagent.exe',
                             'waptagent.sha256', 'patchs/wapttransition.exe', 'padit_transition_confirmation.py', 'certificates/https.pem',
                             'certificates/packages.pem', 'signer-policy.json', 'WAPT/manifest.sha256',
                             'WAPT/manifest.sha1'}.issubset(names))
            self.assertEqual(package.read('patchs/wapttransition.exe'), 'inert engine fixture')
            self.assertNotIn('patchs/waptdeploy.exe', names)
            self.assertEqual(self.signature_checks, ['waptagent.exe', 'wapttransition.exe'])
            self.assertEqual(package.read('certificates/https.pem'), self.cert.as_pem())
            self.assertEqual(package.read('certificates/packages.pem'), self.cert.as_pem())
            self.assertNotIn('WAPT/wapt.psproj', names)
            self.assertNotIn('.env', names)
            self.assertFalse(any(name.startswith('.vscode/') for name in names))
            for name in names:
                content = package.read(name)
                for secret in ('PRIVATE KEY', 'admin-test', 'server-password-test', 'key-password-test'):
                    self.assertNotIn(secret, content)
            transition = json.loads(package.read('transition.json'))
            self.assertEqual(transition['agent_version'], '1.8.3.7759')
            expected_sha256 = hashlib.sha256(package.read('waptagent.exe')).hexdigest()
            self.assertEqual(transition['agent_sha256'], expected_sha256)
            self.assertEqual(package.read('waptagent.sha256'), '%s  waptagent.exe\n' % expected_sha256)
            for field in ('source_server_url', 'target_server_url', 'target_repo_url'):
                self.assertEqual(transition[field], self.arguments[field])
            self.assertFalse(transition['deployable'])
            self.assertEqual(transition['schema_version'], 2)
            self.assertEqual(set(transition['components_sha256']), {
                'waptagent.exe', 'waptagent.sha256', 'patchs/wapttransition.exe',
                'padit_transition_confirmation.py', 'certificates/https.pem', 'certificates/packages.pem', 'signer-policy.json'})
            for name, digest in transition['components_sha256'].items():
                self.assertEqual(hashlib.sha256(package.read(name)).hexdigest(), digest)
            namespace = {}
            eval(compile(package.read('setup.py'), 'setup.py', 'exec'), namespace)
            with self.assertRaises(RuntimeError):
                namespace['install']()
        self.assertEqual(os.listdir(self.output), [result['filename']])

    def test_historical_signer_policy_gate(self):
        entry = PackageEntry(waptfile=self.build()['localpath'])
        source = os.path.join(self.root, 'authenticated')
        entry.unzip_package(target_dir=source, cabundle=self.cert)
        stage = os.path.join(self.root, 'fixture-stage')
        shutil.copytree(source, stage)
        self.console.cabundle = self.cert
        namespace = {}
        with open(os.path.join(source, 'setup.py'), 'rb') as script:
            eval(compile(script.read(), 'setup.py', 'exec'), namespace)
        checks, launches = [], []
        namespace['_check_protected_payload'] = lambda path: None
        pins = {'wapttransition.exe': 'a' * 64, 'waptagent.exe': 'b' * 64}

        def signer(path, handle):
            self.assertTrue(handle)
            checks.append(os.path.basename(path))
            return pins[os.path.basename(path)]

        real_signer = namespace['_windows_authenticode_signer']
        namespace['_windows_authenticode_signer'] = signer

        def launch(path, digest):
            self.assertEqual(checks[-2:], ['wapttransition.exe', 'waptagent.exe'])
            self.assertEqual(path, os.path.join(stage, 'patchs', 'wapttransition.exe'))
            with open(os.path.join(source, 'transition.json'), 'rb') as stream:
                self.assertEqual(digest, hashlib.sha256(stream.read()).hexdigest())
            launches.append(path)

        def gated():
            namespace['with_verified_transition_engine'](self.console, entry, source, stage, launch)

        namespace['_windows_authenticode_signer'] = real_signer
        with self.assertRaisesRegexp(RuntimeError, 'Authenticode verification failed'):
            gated()
        self.assertEqual(launches, [])
        namespace['_windows_authenticode_signer'] = signer
        gated()
        pins['wapttransition.exe'] = 'c' * 64
        with self.assertRaisesRegexp(RuntimeError, 'Unauthorized.*engine'):
            gated()
        pins.update({'wapttransition.exe': 'b' * 64, 'waptagent.exe': 'a' * 64})
        with self.assertRaisesRegexp(RuntimeError, 'Unauthorized.*engine'):
            gated()
        original_archive = entry.localpath
        entry.localpath = source
        with self.assertRaisesRegexp(RuntimeError, 'authenticated WAPT archive'):
            gated()
        entry.localpath = original_archive

        policy_path = os.path.join(source, 'signer-policy.json')
        with open(policy_path, 'rb') as policy:
            original = policy.read()
        for bad in ('{}', original + ' ', None):
            if bad is None:
                os.remove(policy_path)
            else:
                with open(policy_path, 'wb') as policy:
                    policy.write(bad)
            with self.assertRaises(Exception):
                gated()
        self.assertEqual(len(launches), 1)

    def test_release_signature_policy_rejects_unsigned_fixture(self):
        waptdevutils._verify_transition_executable = self.release_signature_check
        with self.assertRaises(RuntimeError) as error:
            self.build()
        self.assertIn('valid Authenticode', str(error.exception))
        self.assertEqual(os.listdir(self.output), [])

    @unittest.skipUnless(os.environ.get('PADIT_HANDOFF_FIXTURE'), 'Build the native handoff fixture')
    def test_controlled_native_handoff(self):
        executable = os.environ['PADIT_HANDOFF_FIXTURE']
        package = self.build()['localpath']
        source = os.path.join(self.root, 'source')
        PackageEntry(waptfile=package).unzip_package(target_dir=source, cabundle=self.cert)
        manifest = os.path.join(source, 'transition.json')
        with open(manifest, 'rb') as stream:
            approved = hashlib.sha256(stream.read()).hexdigest()
        namespace = {}
        with open(os.path.join(source, 'setup.py'), 'rb') as stream:
            eval(compile(stream.read(), 'setup.py', 'exec'), namespace)

        def invoke(args, data=None):
            child = subprocess.Popen([executable] + args, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            out, _ = child.communicate(data)
            return child.returncode, out

        def prepare(root, digest):
            return invoke(['prepare', root, source, digest], '{"uuid":"fixture"}\n')

        helper = os.path.join(source, 'padit_transition_confirmation.py')
        with open(helper, 'ab') as stream:
            stream.write('# modified')
        bad_root = os.path.join(self.root, 'modified')
        code, out = prepare(bad_root, approved)
        self.assertNotEqual(code, 0)
        self.assertIn('source component SHA256', out)
        self.assertFalse(os.path.exists(os.path.join(bad_root, 'staging', 'historical.json')))
        code, out = invoke(['relay', bad_root, os.path.join(self.root, 'unused.sqlite')])
        self.assertNotEqual(code, 0)
        self.assertIn('No fully staged', out)
        with zipfile.ZipFile(package) as archive:
            with open(helper, 'wb') as stream:
                stream.write(archive.read('padit_transition_confirmation.py'))
        code, out = prepare(os.path.join(self.root, 'wrong-manifest'), '0' * 64)
        self.assertNotEqual(code, 0)
        self.assertIn('source component SHA256', out)

        root = os.path.join(self.root, 'transition')
        def native_fixture(package_dir, digest, snapshot):
            code, out = invoke(['prepare', root, package_dir, digest], snapshot + '\n')
            self.assertEqual(code, 0, out)

        namespace['prepare_fixture_handoff']('{"uuid":"fixture"}', source, approved, native_fixture)
        self.assertNotEqual(prepare(root, approved)[0], 0)
        os.rename(source, source + '-removed')
        with open(os.path.join(root, 'state.json'), 'rb') as stream:
            state = json.load(stream)
        self.assertEqual(state['payload_sha256'], approved)
        self.assertEqual(state['state'], 'PRECHECK')
        db_path = os.path.join(self.root, 'fixture.sqlite')
        with sqlite3.connect(db_path) as database:
            database.execute('create table test (id)')
        database.close()

        # Failed relay creation leaves the staged attempt intact and unresolved.
        with self.assertRaises(WindowsError):
            subprocess.Popen([os.path.join(self.root, 'no-relay.exe')])
        self.assertFalse(os.path.exists(os.path.join(root, 'staging', 'fixture-handoff.ready')))
        code, out = invoke(['relay', root, db_path])
        self.assertEqual(code, 0, out)
        self.assertIn('PASS relay', out)

    def test_normal_edit_and_build_handle_development_files(self):
        result = self.build(source_server_url='https://[2001:db8::1]:8443/wapt')
        target = os.path.join(self.root, 'edit')
        entry = common.Wapt.edit_package.im_func(
            self.console, result['localpath'], target_directory=target, cabundle=self.cert)
        self.assertEqual(self.console.projects, ['pyscripter', 'vscode'])
        entry.build_package(target_directory=self.root)
        with zipfile.ZipFile(entry.localpath) as package:
            for path in ('WAPT/wapt.psproj', '.env', '.vscode/launch.json', '.vscode/settings.json'):
                self.assertIn(path, package.namelist())

    def test_configured_prefix_and_revision_from_latest_package(self):
        self.console.config.set('global', 'default_package_prefix', 'another-site')
        name = 'another-site-padit-transition'
        self.repo.entries = [PackageEntry(name, '1.8.3.7749-7'),
                             PackageEntry(name, '1.8.3.7748-12')]
        result = self.build()
        self.assertEqual(result['package'], name)
        self.assertEqual(self.repo.request, name)
        self.assertEqual(result['version'], '1.8.3.7759-8')

    def test_required_parameters_and_credentials_in_urls(self):
        arguments = dict(self.arguments)
        del arguments['source_server_url']
        with self.assertRaises(TypeError):
            waptdevutils.build_transition_package(**arguments)
        for field, value in (('agent_path', os.path.join(self.root, 'absent.exe')),
                             ('source_server_url', None),
                             ('source_server_url', 'ftp://source.example.test'),
                             ('source_server_url', 'https://user:secret@source.example.test'),
                             ('source_server_url', 'https://source.example.test?token=secret'),
                             ('source_server_url', 'https://source.example.test/#fragment'),
                             ('source_server_url', 'https://source.example.test:65536'),
                             ('source_server_url', 'https://source.example.test:'),
                             ('source_server_url', 'https://[2001:db8::xyz]/wapt'),
                             ('source_server_url', 'https://[2001:::1]/wapt'),
                             ('source_server_url', 'https://source..example.test'),
                             ('target_server_url', 'http://target.example.test'),
                             ('target_server_url', ''),
                             ('target_repo_url', 'https://admin:password@target.example.test/wapt'),
                             ('target_repo_url', 'https://target.example.test/wapt?token=secret'),
                             ('https_certificate_path', None),
                             ('package_certificate_path', None)):
            with self.assertRaises(ValueError):
                self.build(**{field: value})
            self.assertEqual(os.listdir(self.output), [])
        self.console.config.remove_option('global', 'default_package_prefix')
        with self.assertRaises(ValueError):
            self.build()

    def test_non_deployable_package_cannot_be_published(self):
        with self.assertRaises(RuntimeError) as error:
            self.build(publish=True, wapt_server_user='admin-test',
                       wapt_server_passwd='server-password-test')
        self.assertIn('non-deployable', str(error.exception))
        self.assertEqual(self.console.uploads, [])
        self.assertEqual(self.repo.updates, 0)
        self.assertEqual(os.listdir(self.output), [])

    def test_cleanup_on_signing_error(self):
        def fail_sign(*args, **kwargs):
            raise RuntimeError('Simulated signing error')

        self.addCleanup(setattr, PackageEntry, 'sign_package', PackageEntry.sign_package.im_func)
        PackageEntry.sign_package = fail_sign
        with self.assertRaises(RuntimeError) as error:
            self.build()
        self.assertEqual(str(error.exception), 'Simulated signing error')
        self.assertEqual(self.console.uploads, [])
        self.assertEqual(os.listdir(self.output), [])

    def test_waptupgrade_still_builds_signs_and_uploads(self):
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        sources = os.path.join(self.root, 'upgrade')
        shutil.copytree(os.path.join(root, 'waptupgrade'), sources)
        waptdevutils.get_file_properties = lambda path: {'FileVersion': '1.8.3.7759'}
        result = waptdevutils.build_waptupgrade_package(
            self.console, self.repo, sources_directory=sources,
            target_directory=self.output, key_password='key-password-test',
            wapt_server_user='admin-test', wapt_server_passwd='server-password-test')
        self.assertEqual(result['package'], 'test-site-waptupgrade')
        self.assertEqual(result['version'], '1.8.3.7759-1')
        self.assertEqual(len(self.console.uploads), 1)
        self.assertEqual(self.repo.updates, 2)

if __name__ == '__main__':
    unittest.main()
