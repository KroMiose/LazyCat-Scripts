"""Materialize verified product archives while keeping test drivers independent."""
import hashlib
import io
import json
from pathlib import Path
import re
import struct
import tarfile

FOLDERS=('common','linux','ssh/client','ssh/ca','ssh/node','ssh/lib')

def unpack(data, limit):
    files={};total=0
    with tarfile.open(fileobj=io.BytesIO(data),mode='r:gz') as archive:
        for member in archive:
            path=Path(member.name)
            if (not member.isfile() or path.is_absolute() or '..' in path.parts or
                str(path)!=member.name or '\\' in member.name or member.name in files):
                raise ValueError('unsafe or duplicate candidate archive member')
            total+=member.size
            if member.size<0 or total>limit:raise ValueError('candidate archive exceeds size bound')
            files[member.name]=(archive.extractfile(member).read(),member.mode & 0o777)
    return files

def materialize_assets(directory, snapshot, binary, commit):
    directory=Path(directory);snapshot=Path(snapshot);binary=Path(binary)
    manifest=json.loads((directory/'manifest.json').read_text())
    if (manifest.get('format_version')!=1 or manifest.get('commit')!=commit or
        manifest.get('development') is not False or manifest.get('dirty') is not False):
        raise ValueError('system artifact must be a clean candidate for this exact commit')
    versions=manifest['versions']
    for component in ('scripts','ssh'):
        if not re.fullmatch('lazycat-'+component+r'-v[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?',versions[component]):
            raise ValueError('invalid candidate version')
    digests={}
    for asset in manifest['assets']:
        name=asset['path'];path=directory/name
        if (Path(name).name!=name or name in digests or not path.is_file() or path.is_symlink() or
            path.stat().st_size>128*1024*1024):raise ValueError('invalid candidate asset path/size')
        actual=hashlib.sha256(path.read_bytes()).hexdigest()
        if actual!=asset['sha256']:raise ValueError('candidate checksum mismatch: '+name)
        digests[name]=actual
    sums={}
    for line in (directory/'SHA256SUMS').read_text().splitlines():
        fields=line.split()
        if len(fields)!=2 or fields[1] in sums:raise ValueError('invalid or duplicate SHA256SUMS entry')
        sums[fields[1]]=fields[0]
    if sums!=digests:raise ValueError('SHA256SUMS differs from candidate manifest')
    names=[versions['scripts']+'.tar.gz',versions['ssh']+'-linux-amd64.tar.gz']
    if any(name not in digests for name in names):raise ValueError('required system candidate archive missing')
    archives=[unpack((directory/name).read_bytes(),96*1024*1024) for name in names]
    for files in archives:
        provenance=json.loads(files['BUILD.json'][0])
        for field in ('commit','versions','source_tree_sha256','development','dirty'):
            if provenance.get(field)!=manifest.get(field):raise ValueError('archive build provenance mismatch')
    shell,client=archives
    payload=client['lazycat-ssh'][0]
    if (len(payload)<32 or payload[:6]!=b'\x7fELF\x02\x01' or struct.unpack_from('<H',payload,18)[0]!=62):
        raise ValueError('Linux AMD64 guest needs an actual Linux AMD64 executable')
    expected={str(path.relative_to(snapshot)) for folder in FOLDERS for path in (snapshot/folder).glob('*.sh')}
    supplied={name for name in shell if name.endswith('.sh')}
    if expected!=supplied:raise ValueError('Shell archive script set differs from this candidate checkout')
    for name in shell:
        if name in ('README.md','BUILD.json'):continue
        if str(Path(name).parent) not in FOLDERS or Path(name).suffix not in ('.sh','.md'):
            raise ValueError('archive attempted to replace a test driver or unknown product resource')
    # Validate everything before writing any product bytes into the snapshot.
    for name,(data,mode) in shell.items():
        if name in ('README.md','BUILD.json'):continue
        target=snapshot/name
        if target.is_symlink():raise ValueError('snapshot contains an unexpected symlink')
        target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data);target.chmod(mode)
    binary.write_bytes(payload);binary.chmod(0o755)
    return {'commit':commit,'source_tree_sha256':manifest['source_tree_sha256'],
            'candidate_assets':digests,'versions':versions,'client_origin':'verified-release-archive',
            'shell_origin':'verified-release-archive','limits':'Linux AMD64 full-system only; no public download claim'}
