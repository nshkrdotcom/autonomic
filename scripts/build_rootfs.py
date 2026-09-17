#!/usr/bin/env python3
"""Build a secret-free, offline BEAM verification rootfs from pinned installed tools.

Run as root, supplying trusted OTP/Elixir installation directories. Source binaries
and libraries are copied; no host home, credentials, network config, or sockets are
copied. Two documented offline startup adaptations are compiled into this rootfs.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def run(argv, **kwargs):
    return subprocess.run(argv, check=True, **kwargs)


def build(root, otp, elixir):
    if root.exists():
        raise SystemExit(f"Destination already exists; choose a new rootfs: {root}")
    root.mkdir(parents=True, mode=0o755)
    for directory in ('workspace', 'run', 'tmp', 'proc', 'dev', 'usr/bin', 'bin', 'etc', 'opt'):
        (root / directory).mkdir(parents=True, exist_ok=True)

    def copy_file(path):
        source = Path(path)
        destination = root / str(source).lstrip('/')
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)

    def dependencies(path):
        result = subprocess.run(['ldd', str(path)], capture_output=True, text=True, check=False)
        for library in re.findall(r'(/[^\s()]+)', result.stdout):
            if Path(library).is_file():
                copy_file(library)

    for name in ('sh', 'bash', 'sleep', 'git', 'patch', 'tar', 'env', 'true', 'false',
                 'cat', 'mkdir', 'rm', 'dirname', 'basename', 'readlink', 'python3'):
        source = shutil.which(name)
        if source is None:
            raise SystemExit(f"Required rootfs executable missing: {name}")
        destination = root / 'usr/bin' / name
        shutil.copy2(source, destination)
        dependencies(source)
        if name in ('sh', 'bash', 'sleep', 'cat', 'mkdir', 'rm', 'true', 'false'):
            (root / 'bin' / name).symlink_to('/usr/bin/' + name)

    python_lib = Path('/usr/lib') / ('python' + run(
        ['/usr/bin/python3', '-c', 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")'],
        capture_output=True, text=True).stdout.strip())
    shutil.copytree(python_lib, root / str(python_lib).lstrip('/'))
    for library in python_lib.rglob('*.so'):
        dependencies(library)

    for source, name in ((otp, 'otp'), (elixir, 'elixir')):
        destination = root / 'opt' / name
        shutil.copytree(source, destination)
        for path in source.rglob('*'):
            if path.is_file() and os.access(path, os.X_OK):
                dependencies(path)
    # Relocate the fallback path used when erl is invoked through /usr/bin.
    erl_script = root / "opt/otp/bin/erl"
    erl_script.write_text(erl_script.read_text().replace(str(otp), "/opt/otp"))
    for name in ('erl', 'escript'):
        (root / 'usr/bin' / name).symlink_to('/opt/otp/bin/' + name)
    for name in ('elixir', 'mix'):
        (root / 'usr/bin' / name).symlink_to('/opt/elixir/bin/' + name)

    kernel = next(otp.glob('lib/kernel-*'))
    source = kernel / 'src/inet_config.erl'
    original = source.read_text()
    start = original.index('set_hostname() ->')
    end = original.index('\nset_hostname({ok,Name})', start)
    offline = original[:start] + 'set_hostname() ->\n    set_hostname({ok, "autonomic"}).\n' + original[end:]
    with tempfile.TemporaryDirectory(prefix='autonomic-rootfs-build-') as temporary:
        temporary = Path(temporary)
        (temporary / 'inet_config.erl').write_text(offline)
        environment = os.environ.copy()
        environment['PATH'] = str(otp / 'bin') + ':' + str(elixir / 'bin') + ':' + environment['PATH']
        run([str(otp / 'bin/erlc'), '-I', str(kernel / 'src'), '-I', str(kernel / 'include'),
             '-o', str(temporary), str(temporary / 'inet_config.erl')], env=environment)
        shutil.copy2(temporary / 'inet_config.beam', root / 'opt/otp/lib' / kernel.name / 'ebin/inet_config.beam')
        subscriber = Path(__file__).parent / 'rootfs/offline_subscriber.ex'
        run([str(elixir / 'bin/elixirc'), '-o', str(temporary), str(subscriber)], env=environment)
        shutil.copy2(temporary / 'Elixir.Mix.PubSub.Subscriber.beam', root / 'opt/elixir/lib/mix/ebin')

    (root / 'etc/gitconfig').write_text('[safe]\n\tdirectory = /workspace\n')
    (root / 'etc/hostname').write_text('autonomic\n')
    manifest = {'otp_source': str(otp), 'elixir_source': str(elixir), 'offline_adaptations':
                ['inet_config.set_hostname: fixed non-network hostname',
                 'Mix.PubSub.Subscriber: no cross-process TCP notifications'], 'files': {}}
    for path in sorted(root.rglob('*')):
        if path.is_file() and not path.is_symlink():
            manifest['files'][str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
    (root / 'rootfs-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    for directory, _, _ in os.walk(root):
        os.chmod(directory, 0o755)
    print(root)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--otp', type=Path, required=True)
    parser.add_argument('--elixir', type=Path, required=True)
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise SystemExit('Run as root to create the trusted rootfs')
    build(args.destination.resolve(), args.otp.resolve(), args.elixir.resolve())
