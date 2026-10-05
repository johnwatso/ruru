#!/usr/bin/env python3
"""Vendor both official macOS connector slices into a universal app resource."""
from pathlib import Path
import hashlib, io, subprocess, tarfile, tempfile, urllib.request

VERSION = '2026.9.3'
# GitHub release asset SHA-256 digests from Cloudflare's release API.
DIGESTS = {
    'amd64': 'd1155d0837487f261183b15c1eab6c4ebcad9dc49b94675f1524c3564cea3977',
    'arm64': '587c2cfb1c230fe36c7fa7727da78be459dae028cabe8c001291999350f07095',
}
root = Path(__file__).resolve().parents[1]
resources = root / 'Resources'
resources.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='witness-cloudflared-') as folder:
    slices = []
    for arch, checksum in DIGESTS.items():
        url = f'https://github.com/cloudflare/cloudflared/releases/download/{VERSION}/cloudflared-darwin-{arch}.tgz'
        payload = urllib.request.urlopen(url, timeout=90).read()
        if hashlib.sha256(payload).hexdigest() != checksum:
            raise RuntimeError(f'Checksum mismatch for {arch}')
        with tarfile.open(fileobj=io.BytesIO(payload), mode='r:gz') as archive:
            members = [m for m in archive.getmembers() if Path(m.name).name == 'cloudflared' and m.isfile()]
            if len(members) != 1:
                raise RuntimeError('Expected one connector binary')
            binary = archive.extractfile(members[0]).read()
        output = Path(folder) / f'cloudflared-{arch}'
        output.write_bytes(binary)
        output.chmod(0o755)
        slices.append(str(output))
    subprocess.run(['lipo', '-create', *slices, '-output', str(resources / 'cloudflared')], check=True)
    (resources / 'cloudflared').chmod(0o755)
    subprocess.run(['codesign', '--force', '--sign', '-', str(resources / 'cloudflared')], check=True)
license_url = f'https://raw.githubusercontent.com/cloudflare/cloudflared/{VERSION}/LICENSE'
(resources / 'cloudflared-LICENSE.txt').write_bytes(urllib.request.urlopen(license_url, timeout=30).read())
print(f'Vendored cloudflared {VERSION}; both upstream archive digests verified.')
