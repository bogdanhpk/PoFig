"""Exercise the actual updater against disposable packages and processes only."""
import hashlib
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import time
import uuid
import zipfile
from pathlib import Path

helper = str(Path(sys.argv[1]).resolve())
platform = 'windows' if sys.platform == 'win32' else 'macos'

def write(path, value):
    path.write_text(json.dumps(value))

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def manifest(root, version):
    return dict(product='PoFig', platform=platform, version=version, files=[dict(path=p.relative_to(root).as_posix(), sha256=digest(p), mode=p.stat().st_mode & 0o777) for p in sorted(root.rglob('*')) if p.is_file() and p.name != 'PoFig-update.json'])

def bundle(root, version):
    exe = root / ('PoFig.exe' if platform == 'windows' else 'Contents/MacOS/PoFig')
    exe.parent.mkdir(parents=True)
    exe.write_text(version)
    if platform == 'macos':
        (root / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleShortVersionString=version)))
    else:
        write(root / 'PoFig-update.json', manifest(root, version))

def run(action, job, *extra, success=True):
    result = subprocess.run([helper, action, str(job), *extra], capture_output=True, text=True, timeout=15)
    assert (result.returncode == 0) == success, result.stdout + result.stderr
    return result

with tempfile.TemporaryDirectory(prefix='PoFig updater tests ') as folder:
    base = Path(folder)
    package = base / 'source'
    root = package if platform == 'windows' else package / 'PoFig.app'
    bundle(root, '0.3.0')
    write(package / 'PoFig-update.json', manifest(root, '0.3.0'))
    archive = base / 'update.zip'
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as z:
        for p in package.rglob('*'):
            if p.is_file(): z.write(p, p.relative_to(package).as_posix())
    job = base / 'prepare.json'
    def prepare(archive, dest, checksum=None, success=True):
        write(job, dict(archive=str(archive), destination=str(dest), sha256=checksum or digest(archive), version='0.3.0', platform=platform))
        return run('prepare', job, success=success)
    prepare(archive, base / 'verified')
    prepare(archive, base / 'bad-hash', '0' * 64, success=False)
    assert not (base / 'bad-hash').exists()
    for index, name in enumerate(['../escaped', '/absolute', 'a/../../escaped', 'C:/escaped']):
        bad = base / f'bad-{index}.zip'
        with zipfile.ZipFile(bad, 'w') as z: z.writestr(name, 'bad')
        prepare(bad, base / f'rejected-{index}', success=False)
    linked = base / 'link.zip'
    with zipfile.ZipFile(linked, 'w') as z:
        info = zipfile.ZipInfo('link'); info.create_system = 3; info.external_attr = (0o120777 << 16)
        z.writestr(info, '../escaped')
    prepare(linked, base / 'rejected-link', success=False)
    assert not (base / 'escaped').exists()
    tampered = base / 'tampered.zip'
    with zipfile.ZipFile(tampered, 'w') as z:
        for p in package.rglob('*'):
            if p.is_file(): z.writestr(p.relative_to(package).as_posix(), b'changed' if p.name in ('PoFig', 'PoFig.exe') else p.read_bytes())
    prepare(tampered, base / 'rejected-content', success=False)

    workspace = base / 'transaction'; workspace.mkdir()
    identity = str(uuid.uuid4())
    target = base / ('target' if platform == 'windows' else 'PoFig.app')
    stage = workspace / 'stage' if platform == 'windows' else base / f'.PoFig-update-{identity}.app'
    backup = workspace / 'backup' if platform == 'windows' else base / f'.PoFig-backup-{identity}.app'
    bundle(target, '0.2.0'); bundle(stage, '0.3.0')
    mf = stage / 'PoFig-update.json' if platform == 'windows' else workspace / 'PoFig-update.json'
    write(mf, manifest(stage, '0.3.0'))
    parent = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
    install = workspace / 'install.json'
    write(install, dict(id=identity, target=str(target), stage=str(stage), manifest=str(mf), manifest_sha256=digest(mf), backup=str(backup), parent_pid=parent.pid, version='0.3.0', platform=platform, restart=False))
    worker = subprocess.Popen([helper, 'install', str(install)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        ready = json.loads(worker.stdout.readline()); assert ready['event'] == 'ready', ready
        executable = 'PoFig.exe' if platform == 'windows' else 'Contents/MacOS/PoFig'
        assert (target / executable).read_text() == '0.2.0', 'Replacement happened before app exit'
        parent.terminate(); parent.wait(timeout=5)
        stdout, stderr = worker.communicate(timeout=15)
        assert worker.returncode == 0, stdout + stderr
        assert (target / executable).read_text() == '0.3.0'
        assert (backup / executable).read_text() == '0.2.0'
        assert json.loads((workspace / 'result.json').read_text())['status'] == 'installed'
        # Simulate restart after an interrupted update. Recovery is safe to repeat.
        run('recover', install, '99999999')
        run('recover', install, '99999999')
        assert (target / executable).read_text() == '0.2.0'
        assert json.loads((workspace / 'result.json').read_text())['status'] == 'failed'
    finally:
        if parent.poll() is None: parent.kill(); parent.wait()
        if worker.poll() is None: worker.kill(); worker.wait()
print('Updater: archive checksums, traversal, symlinks, tampered files, wait-for-exit, installation and repeatable recovery verified')
