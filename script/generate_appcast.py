#!/usr/bin/env python3
"""Generate and validate the signed GitHub Releases feed after notarization."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / '.build/artifacts/sparkle/Sparkle/bin'
RELEASES = 'https://github.com/clelange/ssh-autotunnel/releases'
SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def run(tool, *args):
    return subprocess.run([str(TOOLS / tool), *map(str, args)], check=True,
                          capture_output=True, text=True).stdout.strip()


def verify(feed, archive, info, key_args):
    run('sign_update', *key_args, '--verify', feed)
    items = ET.parse(feed).findall('./channel/item')
    if len(items) != 1:
        raise ValueError('Expected exactly one update in the feed')
    item = items[0]
    enclosure = item.find('enclosure')
    version = info['CFBundleShortVersionString']
    expected_url = f'{RELEASES}/download/v{version}/{archive.name}'
    if enclosure is None or enclosure.get('url') != expected_url:
        raise ValueError('Update download URL does not match this release')
    if item.findtext(SPARKLE + 'version') != info['CFBundleVersion']:
        raise ValueError('Update build number does not match the app')
    if item.findtext(SPARKLE + 'shortVersionString') != version:
        raise ValueError('Update version does not match the app')
    if item.findtext(SPARKLE + 'minimumSystemVersion') != info['LSMinimumSystemVersion']:
        raise ValueError('Update minimum macOS version does not match the app')
    if enclosure.get('length') != str(archive.stat().st_size):
        raise ValueError('Update length does not match the final archive')
    signature = enclosure.get(SPARKLE + 'edSignature')
    if not signature:
        raise ValueError('Update has no EdDSA signature; check the signing key')
    run('sign_update', *key_args, '--verify', archive, signature)


def generate(archive, app, output, key_args):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    version = info['CFBundleShortVersionString']
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not str(info['CFBundleVersion']).isdigit():
        raise ValueError('Stable releases require a three-part version and numeric build')
    if archive.name != f'SSH-AutoTunnel-{version}.dmg':
        raise ValueError('Archive filename does not match the app version')
    if not info.get('SSHAutoTunnelUpdatesEnabled') or not info.get('SURequireSignedFeed'):
        raise ValueError('Only update-enabled release bundles can publish a feed')
    if info.get('SUFeedURL') != RELEASES + '/latest/download/appcast.xml':
        raise ValueError('App must use the stable GitHub Releases feed')
    output.parent.mkdir(parents=True, exist_ok=True)
    # A fresh directory prevents historical DMGs/deltas or a stale feed being published.
    with tempfile.TemporaryDirectory(prefix='appcast-', dir=output.parent) as directory:
        staged = Path(directory)
        shutil.copy2(archive, staged / archive.name)
        candidate = staged / 'appcast.xml'
        run('generate_appcast', *key_args, '--maximum-deltas', '0',
            '--download-url-prefix', f'{RELEASES}/download/v{version}/',
            '--link', f'{RELEASES}/tag/v{version}',
            '--versions', info['CFBundleVersion'], '-o', candidate, staged)
        verify(candidate, archive, info, key_args)
        os.replace(candidate, output)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('app', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    account = os.environ.get('SPARKLE_KEYCHAIN_ACCOUNT', 'dev.clange.ssh-autotunnel')
    key_args = ['--account', account]
    info = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
    if run('generate_keys', *key_args, '-p') != info.get('SUPublicEDKey'):
        raise ValueError('Keychain signing key does not match the public key in the app')
    print(generate(args.archive.resolve(), args.app.resolve(), args.output.resolve(), key_args))


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit(f'Sparkle tool failed: {error.stderr or error.stdout}')
    except ValueError as error:
        raise SystemExit(str(error))
