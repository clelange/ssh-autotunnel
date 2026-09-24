#!/usr/bin/env python3
"""Integration checks using Sparkle's real signing tools and a temporary key."""
import base64
import copy
import secrets
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

import generate_appcast as appcast


class AppcastTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix='ssh-autotunnel-appcast-test-')
        cls.addClassCleanup(cls.directory.cleanup)
        cls.root = Path(cls.directory.name)
        cls.key = cls.root / 'test-key'
        # The seed stays in this temporary file; only the public key is returned.
        key_program = '''
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
let url = URL(fileURLWithPath: CommandLine.arguments[1])
try key.rawRepresentation.base64EncodedString().write(to: url, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
print(key.publicKey.rawRepresentation.base64EncodedString())
'''
        cls.public_key = subprocess.check_output(
            ['swift', '-e', key_program, str(cls.key)], text=True).strip()
        cls.key_args = ['--ed-key-file', str(cls.key)]
        source = appcast.ROOT / 'dist/package/SSH AutoTunnel/SSHAutoTunnel.app'
        if not source.is_dir():
            raise RuntimeError('Run script/package_local.sh --verify before these tests')
        cls.app = cls.root / 'payload/SSHAutoTunnel.app'
        subprocess.run(['ditto', str(source), str(cls.app)], check=True)
        info_path = cls.app / 'Contents/Info.plist'
        cls.info = plistlib.loads(info_path.read_bytes())
        cls.info.update(SUPublicEDKey=cls.public_key, SSHAutoTunnelUpdatesEnabled=True)
        info_path.write_bytes(plistlib.dumps(cls.info))
        subprocess.run(['codesign', '--force', '--sign', '-', str(cls.app)], check=True,
                       capture_output=True)
        cls.archive = cls.root / f'SSH-AutoTunnel-{cls.info["CFBundleShortVersionString"]}.dmg'
        subprocess.run(['hdiutil', 'create', '-srcfolder', str(cls.app.parent),
                        '-format', 'UDZO', str(cls.archive)], check=True, capture_output=True)
        cls.feed = cls.root / 'appcast.xml'
        appcast.generate(cls.archive, cls.app, cls.feed, cls.key_args)

    def test_signed_feed_and_final_archive_verify(self):
        appcast.verify(self.feed, self.archive, self.info, self.key_args)
        self.assertIn(b'hardwareRequirements', self.feed.read_bytes())

    def test_changed_feed_is_rejected(self):
        changed = self.root / 'changed.xml'
        changed.write_bytes(self.feed.read_bytes().replace(b'https://github.com', b'https://example.com'))
        with self.assertRaises(subprocess.CalledProcessError):
            appcast.verify(changed, self.archive, self.info, self.key_args)

    def test_changed_archive_is_rejected_even_with_correct_length(self):
        original = self.archive.read_bytes()
        altered = bytearray(original)
        altered[100] ^= 1
        try:
            self.archive.write_bytes(altered)
            with self.assertRaises(subprocess.CalledProcessError):
                appcast.verify(self.feed, self.archive, self.info, self.key_args)
        finally:
            self.archive.write_bytes(original)

    def test_valid_signature_with_wrong_release_url_is_rejected(self):
        changed = self.root / 'wrong-url.xml'
        changed.write_bytes(self.feed.read_bytes().replace(b'/download/v', b'/download/wrong-v'))
        appcast.run('sign_update', *self.key_args, changed)
        with self.assertRaisesRegex(ValueError, 'download URL'):
            appcast.verify(changed, self.archive, self.info, self.key_args)

    def test_wrong_build_is_rejected(self):
        info = copy.deepcopy(self.info)
        info['CFBundleVersion'] = str(int(info['CFBundleVersion']) + 1)
        with self.assertRaisesRegex(ValueError, 'build number'):
            appcast.verify(self.feed, self.archive, info, self.key_args)

    def test_wrong_signing_key_cannot_publish(self):
        key = self.root / 'wrong-key'
        key.write_text(base64.b64encode(secrets.token_bytes(32)).decode())
        key.chmod(0o600)
        output = self.root / 'wrong-key.xml'
        with self.assertRaises((ValueError, subprocess.CalledProcessError)):
            appcast.generate(self.archive, self.app, output, ['--ed-key-file', str(key)])
        self.assertFalse(output.exists())

    def test_development_app_cannot_publish(self):
        app = self.root / 'disabled.app'
        info_path = app / 'Contents/Info.plist'
        info_path.parent.mkdir(parents=True)
        info = copy.deepcopy(self.info)
        info['SSHAutoTunnelUpdatesEnabled'] = False
        info_path.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, 'update-enabled release'):
            appcast.generate(self.archive, app, self.root / 'disabled.xml', self.key_args)
        self.assertFalse((self.root / 'disabled.xml').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
