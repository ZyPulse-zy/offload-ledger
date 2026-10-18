#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Run built OpenWrt Lua/module APKs in a temporary AArch64/musl chroot.

The SDK and its packages are read-only inputs. QEMU must be a static executable.
No APK installation, mounts or changes to the host's module paths are made.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--sdk', type=Path, required=True)
parser.add_argument('--qemu', type=Path, required=True)
parser.add_argument('--report', type=Path)
args = parser.parse_args()
sdk = args.sdk.resolve()
repo = Path(__file__).resolve().parents[2]
qemu = args.qemu.resolve(strict=True)


def one(pattern):
    paths = sorted(sdk.glob(pattern))
    if len(paths) != 1:
        raise RuntimeError(f'Expected exactly one {pattern}, got {paths}')
    return paths[0]


packages = [one('bin/packages/*/base/offload-ledger-0.1.0-r1.apk'),
            one('bin/packages/*/base/lua-5.1.5-r*.apk'),
            one('bin/packages/*/base/liblua5.1.5-5.1.5-r*.apk')]
libc = one('staging_dir/toolchain-aarch64*_musl/lib/libc.so')
libgcc = one('staging_dir/toolchain-aarch64*_musl/lib/libgcc_s.so.1')
apk = sdk / 'staging_dir/host/bin/apk'
env = os.environ.copy()
for key in ('LUA_PATH', 'LUA_CPATH', 'LD_LIBRARY_PATH', 'LD_PRELOAD',
            'QEMU_LD_PREFIX'):
    env.pop(key, None)

with tempfile.TemporaryDirectory(prefix='ledger-openwrt-') as directory:
    root = Path(directory) / 'root'
    root.mkdir()
    subprocess.run([str(apk), 'extract', '--allow-untrusted', '--no-chown',
                    '--destination', str(root), *map(str, packages)], check=True)
    installed = root / 'usr/share/lua/offload_ledger.lua'
    assert installed.read_bytes() == (repo / 'lua/offload_ledger.lua').read_bytes()
    assert not (root / 'etc').exists(), 'Module package must not install a service'
    (root / 'lib').mkdir(exist_ok=True)
    shutil.copy2(libc, root / 'lib/libc.so')
    (root / 'lib/ld-musl-aarch64.so.1').symlink_to('libc.so')
    shutil.copy2(libgcc, root / 'lib/libgcc_s.so.1')
    shutil.copy2(qemu, root / 'qemu-aarch64')
    (root / 'tests').mkdir()
    shutil.copy2(repo / 'tests/test_ledger.lua', root / 'tests/test_ledger.lua')

    def lua(code):
        # Fresh user, mount AND network namespaces. chroot restricts lookup to
        # extracted packages; neither host modules nor the checkout are visible.
        result = subprocess.run(
            ['unshare', '-Urnm', '--', 'chroot', str(root),
             '/qemu-aarch64', '/usr/bin/lua', '-e', code],
            env=env, text=True, capture_output=True, timeout=120)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        print(result.stdout, end='')
        return result.stdout

    # Reproduce the old versioned installation against the actual default path.
    old = root / 'usr/share/lua/5.1/offload_ledger.lua'
    old.parent.mkdir()
    installed.rename(old)
    lua("assert(_VERSION=='Lua 5.1'); "
        "assert(not pcall(require, 'offload_ledger'), 'old path unexpectedly loads'); "
        "print('Old versioned installation fails default require as expected')")
    old.rename(installed)
    output = lua("assert(_VERSION=='Lua 5.1'); "
                 "assert(package.path:find('/usr/share/lua/?.lua', 1, true)); "
                 "assert(require('offload_ledger')); "
                 "print('Default OpenWrt path: '..package.path); "
                 "arg={'--installed'}; dofile('/tests/test_ledger.lua')")
    assert '92819' in output, 'Complete policy suite did not finish'

    stage = Path(directory) / 'make-install'
    subprocess.run(['make', '-C', str(repo), 'install', f'DESTDIR={stage}',
                    'LUA_DIR=/usr/share/lua'], check=True, capture_output=True)
    assert (stage / 'usr/share/lua/offload_ledger.lua').read_bytes() == installed.read_bytes()

report = {
    'packages': {str(p.relative_to(sdk)): hashlib.sha256(p.read_bytes()).hexdigest()
                 for p in packages},
    'qemu': str(qemu), 'runtime': 'actual SDK OpenWrt Lua 5.1.5 AArch64/musl',
    'default_require': 'passed without LUA_PATH/LUA_CPATH overrides',
    'old_versioned_path': 'expected require failure reproduced',
    'policy_checks': 92819, 'make_install_override': 'passed',
    'host_or_router_installed': False, 'firmware_or_hardware_tested': False,
}
if args.report:
    args.report.write_text(json.dumps(report, indent=2) + '\n')
print('OpenWrt extracted-package/default-require regression passed')
