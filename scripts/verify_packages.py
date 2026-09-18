#!/usr/bin/env python3
"""Verify unpacked Hex sources outside the workspace using a temporary local registry.
Only the unpublished core's repository name is overridden in verification copies;
tarballs and version requirements remain unchanged. No global Hex config is changed.
"""
import functools
import http.server
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading

import release


def main():
    import argparse
    args = argparse.Namespace(version='0.1.0')
    if release.command_inspect(args):
        return 1
    with tempfile.TemporaryDirectory(prefix='autonomic-isolated-') as tmp:
        root = Path(tmp)
        env = {**os.environ, 'HEX_HOME': str(root / 'hex'), 'MIX_ENV': 'dev'}
        env.pop('TYPESAFE_SDK_PATH', None)
        # Keep the selected repository toolchain when asdf shims change directory.
        for line in (release.ROOT / '.tool-versions').read_text().splitlines():
            tool, version = line.split(maxsplit=1)
            env[f'ASDF_{tool.upper()}_VERSION'] = version
        public = root / 'public'
        (public / 'tarballs').mkdir(parents=True)
        stage = release.STAGE_BASE / args.version
        for tar in (stage / 'tarballs').glob('*.tar'):
            shutil.copy2(tar, public / 'tarballs')

        def run(command, cwd=root, extra=None):
            subprocess.run(command, cwd=cwd, env={**env, **(extra or {})}, check=True)

        run(['openssl', 'genrsa', '-out', str(root / 'key.pem'), '2048'])
        run(['mix', 'hex.registry', 'build', str(public), '--name', 'autonomic_verify', '--private-key', str(root / 'key.pem')])
        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(public))
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            run(['mix', 'hex.repo', 'add', 'autonomic_verify', f'http://127.0.0.1:{server.server_port}', '--public-key', str(public / 'public_key')])
            for package in release.TOPOLOGICAL_ORDER:
                dest = root / package
                shutil.copytree(stage / 'unpacked' / package, dest)
                # Tests are verification inputs, intentionally absent from distribution.
                shutil.copytree(release.PACKAGES_DIR / package / 'test', dest / 'test')
                mix = dest / 'mix.exs'
                mix.write_text(mix.read_text().replace('{:autonomic, "~> 0.1.0"}', '{:autonomic, "~> 0.1.0", repo: "autonomic_verify"}'))
                print(f'ISOLATED VERIFY: {package}', flush=True)
                run(['mix', 'deps.get'], dest)
                run(['mix', 'compile', '--warnings-as-errors'], dest)

                # The PostgreSQL package's default test selection excludes every
                # integration test. Starting its OTP application here would start
                # the Repo and attempt a database connection even though no DB test
                # will execute. This isolated-installation gate verifies that the
                # packaged test code compiles without requiring host PostgreSQL;
                # real PostgreSQL behavior is covered by the dedicated integration
                # and strict-QC gates.
                test_cmd = ['mix', 'test']
                if package == 'autonomic_postgres':
                    test_cmd.append('--no-start')

                run(test_cmd, dest, {'MIX_ENV': 'test'})
                run(['mix', 'docs', '--warnings-as-errors'], dest)
        finally:
            server.shutdown()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
