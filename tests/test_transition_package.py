# -*- coding: utf-8 -*-
"""Offline Windows tests for the PADIT transition package generator."""
import hashlib
import json
import os
import shutil
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
        self.write('waptdeploy.exe', 'inert deploy fixture')
        cert_path = self.write('test.pem', self.cert.as_pem() + self.key.as_pem())
        self.repo = OfflineRepository()
        self.console = OfflineConsole(self.root, cert_path, self.cert, self.key)
        self.arguments = dict(wapt=self.console, mainrepo=self.repo, agent_path=self.agent,
                              source_server_url='http://source.example.test:8080/wapt',
                              target_server_url='https://target.example.test',
                              target_repo_url='https://repo.example.test:8443/wapt',
                              https_certificate_path=cert_path, package_certificate_path=cert_path,
                              target_directory=self.output, key_password='key-password-test')
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
                             'waptagent.sha256', 'patchs/waptdeploy.exe', 'certificates/https.pem',
                             'certificates/packages.pem', 'WAPT/manifest.sha256',
                             'WAPT/manifest.sha1'}.issubset(names))
            self.assertEqual(package.read('patchs/waptdeploy.exe'), 'inert deploy fixture')
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
            namespace = {}
            eval(compile(package.read('setup.py'), 'setup.py', 'exec'), namespace)
            with self.assertRaises(RuntimeError):
                namespace['install']()
        self.assertEqual(os.listdir(self.output), [result['filename']])

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
