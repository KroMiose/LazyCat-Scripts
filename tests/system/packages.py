"""Materialize a reviewed package lock outside the guest; real apt runs inside."""
import hashlib
import os
import json
from pathlib import Path
import shutil
import re
import tarfile
import tempfile
import urllib.request

def cache_bytes(cache,digest,data):
    with tempfile.NamedTemporaryFile(dir=cache,prefix='.package-',delete=False) as stream:
        temporary=Path(stream.name)
        try:
            stream.write(data);stream.flush();os.fsync(stream.fileno())
            temporary.replace(cache/digest)
        finally:temporary.unlink(missing_ok=True)

def materialize(lock_path,image,cache,destination,fresh=False):
    raw=lock_path.read_bytes();lock=json.loads(raw)
    if lock.get('format_version')!=1 or lock.get('image_digest')!=image['digest']:
        raise ValueError('package lock does not match this exact base image')
    packages=lock.get('packages',[])
    if not packages:raise ValueError('empty package lock')
    cache.mkdir(parents=True,exist_ok=True)
    names=set()
    with tempfile.TemporaryDirectory(prefix='lazycat-packages-') as directory:
        root=Path(directory);index=[]
        for package in packages:
            name=package['filename']
            if Path(name).name!=name or name in names or not name.endswith('.deb') or any(c.isspace() for c in name):raise ValueError('invalid package filename')
            names.add(name);digest=package['sha256'];size=package['size']
            if not re.fullmatch('[0-9a-f]{64}',digest):raise ValueError('invalid package digest')
            cached=cache/digest
            if type(size) is not int or not 0<size<256*1024*1024:raise ValueError('invalid package size')
            if fresh or not cached.exists():
                if not package['url'].startswith(('https://','http://')):raise ValueError('invalid package URL')
                # HTTP pool URLs are allowed only because every byte is pinned by
                # the reviewed SHA-256 lock, originally resolved by authenticated apt.
                with urllib.request.urlopen(package['url'],timeout=60) as response:
                    data=response.read(size+1)
                if len(data)!=size or hashlib.sha256(data).hexdigest()!=digest:raise ValueError('package download checksum mismatch')
                cache_bytes(cache,digest,data)
            if cached.stat().st_size!=size or hashlib.sha256(cached.read_bytes()).hexdigest()!=digest:raise ValueError('cached package checksum mismatch')
            shutil.copyfile(cached,root/name)
            control=package['control']
            if '\nFilename:' in '\n'+control or '\nSHA256:' in '\n'+control or '\nSize:' in '\n'+control:raise ValueError('unexpected archive routing fields in control')
            index.append(control.rstrip()+f'\nFilename: {name}\nSize: {size}\nSHA256: {digest}\n\n')
        (root/'Packages').write_text(''.join(index))
        with tarfile.open(destination,'w') as archive:
            for path in sorted(root.iterdir()):archive.add(path,arcname=path.name)
    return hashlib.sha256(raw).hexdigest()

def record_export(archive_path,image,cache,output):
    import shlex
    import urllib.parse
    cache.mkdir(parents=True,exist_ok=True)
    with tarfile.open(archive_path) as archive:
        files={}
        for member in archive.getmembers():
            name=member.name.removeprefix('./')
            if member.isfile() and '/' not in name:
                if name in files or member.size>256*1024*1024:raise ValueError('invalid exported member')
                files[name]=archive.extractfile(member).read()
        urls={}
        for line in files['uris.txt'].decode().splitlines():
            if not line.startswith("'"):continue
            parts=shlex.split(line)
            if len(parts)!=4:raise ValueError('invalid apt URI record')
            urls[urllib.parse.unquote(parts[1])]=parts[0]
        packages=[]
        for stanza in files['Packages'].decode().strip().split('\n\n'):
            fields={line.split(': ',1)[0]:line.split(': ',1)[1] for line in stanza.splitlines() if ': ' in line and not line.startswith(' ')}
            name=fields['Filename'];data=files[name];digest=hashlib.sha256(data).hexdigest()
            if digest!=fields['SHA256'] or len(data)!=int(fields['Size']):raise ValueError('exported archive checksum mismatch')
            control='\n'.join(line for line in stanza.splitlines() if not line.startswith(('Filename:','Size:','SHA256:')))+'\n'
            url=urls.get(urllib.parse.unquote(name))
            if not url:raise ValueError('missing original URL for '+name)
            packages.append(dict(filename=name,url=url,sha256=digest,size=len(data),control=control))
            cache_bytes(cache,digest,data)
    output.parent.mkdir(parents=True,exist_ok=True)
    if output.exists():raise ValueError('refusing to overwrite an existing reviewed package lock')
    output.write_text(json.dumps(dict(format_version=1,image_digest=image['digest'],scope='base-image-specific apt closure; review before CI adoption',packages=packages),indent=2)+'\n')
