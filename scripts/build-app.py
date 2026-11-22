#!/usr/bin/env python3
"""Build a self-contained X6 app using public dependencies; never install it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', choices=['debug', 'release'], default='debug')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('X6 Remote requires macOS and Apple developer tools.')
    root = Path(__file__).resolve().parent.parent
    os.chdir(root)
    env = {k: v for k, v in os.environ.items() if not k.startswith('SAYALL_')}
    env['SAYALL_PRIVATE_PLATFORM_MODE'] = 'public'
    command = ['xcrun', 'swift', 'build', '--disable-keychain', '--jobs', '2',
               '--scratch-path', str(root / '.build' / 'x6'),
               '-c', args.configuration, '-Xswiftc', '-DX6_ADAPTER_PREVIEW',
               '-Xswiftc', '-file-prefix-map', '-Xswiftc', f'{root}=.',
               '-Xswiftc', '-debug-prefix-map', '-Xswiftc', f'{root}=.',
               '-Xcc', f'-ffile-prefix-map={root}=.',
               '--product', 'RemoteMic']
    run(*command, env=env)
    bin_dir = Path(subprocess.check_output(command + ['--show-bin-path'], env=env, text=True).strip())
    app = root / 'dist' / 'X6遥控.app'
    if app.exists():
        raise SystemExit(f'Output already exists: {app}. Move it aside before rebuilding.')
    contents = app / 'Contents'
    macos = contents / 'MacOS'
    resources = contents / 'Resources'
    frameworks = contents / 'Frameworks'
    for directory in [macos, resources, frameworks]:
        directory.mkdir(parents=True, exist_ok=True)
    binary = macos / 'RemoteMic'
    shutil.copy2(bin_dir / 'RemoteMic', binary)
    # ditto preserves framework symlinks and permissions.
    run('ditto', str(bin_dir / 'Sparkle.framework'), str(frameworks / 'Sparkle.framework'))
    for name in ['en.lproj', 'zh-Hans.lproj', 'Fonts']:
        shutil.copytree(root / 'Resources' / name, resources / name)
    for source in (root / 'Resources').glob('StatusIcon*.png'):
        shutil.copy2(source, resources / source.name)
    for name in ['X6Remote.icns', 'X6RemoteFront.png']:
        shutil.copy2(root / 'Resources' / name, resources / name)
    for name in ['LICENSE.md', 'COPYRIGHT.md', 'THIRD_PARTY_NOTICES.md', 'ASSETS.md']:
        shutil.copy2(root / name, resources / name)
    shutil.copy2(root / 'licenses' / 'Sparkle-LICENSE.txt', resources / 'Sparkle-LICENSE.txt')
    info = plistlib.loads((root / 'Resources' / 'X6-Info.plist').read_bytes())
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    # Eliminate absolute SwiftPM build paths from the distributed executable.
    load_commands = subprocess.check_output(['otool', '-l', str(binary)], text=True)
    rpaths = re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.+?) \(offset', load_commands)
    for path in rpaths:
        if path.startswith('/') and not path.startswith(('/usr/lib/', '/System/Library/')):
            run('install_name_tool', '-delete_rpath', path, str(binary))
    if '@executable_path/../Frameworks' not in rpaths:
        run('install_name_tool', '-add_rpath', '@executable_path/../Frameworks', str(binary))
    if args.configuration == 'release':
        # Remove linker debug-map object paths before applying the final signature.
        run('xcrun', 'strip', '-S', str(binary))
    try:
        revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True, stderr=subprocess.DEVNULL).strip()
        dirty = bool(subprocess.check_output(['git', 'status', '--porcelain'], text=True).strip())
    except subprocess.CalledProcessError:
        revision, dirty = 'source-archive', True
    manifest = {'source_commit': revision, 'source_dirty': dirty,
                'channel': 'community-public-source', 'configuration': args.configuration,
                'signing': 'ad-hoc; not notarized',
                'source_sha256': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                                  for p in sorted((root / 'Sources').rglob('*')) if p.is_file()}}
    (resources / 'X6BuildManifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    run('codesign', '--force', '--sign', '-', '--entitlements',
        str(root / 'Resources' / 'X6.entitlements'), str(app))
    run('codesign', '--verify', '--deep', '--strict', str(app))
    print(f'Built {app}\nNot installed or launched. First launch requires macOS permissions.')


if __name__ == '__main__':
    main()
