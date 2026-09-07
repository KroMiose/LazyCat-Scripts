"""Materialize a reviewed package lock outside the guest; real apt runs inside."""
import hashlib
import os
import json
from pathlib import Path
import shutil
import re
import tarfile
import tempfile
import urllib.parse
import subprocess

def resolve_exported_url(url, files):
    prefix='mirror+file:/etc/apt/mirrors/'
    if url.startswith(prefix):
        name,sep,suffix=url[len(prefix):].partition('/')
        if not sep or name not in ('debian.list','debian-security.list'):
            raise ValueError('unsupported fixture mirror list')
        choices=[line.strip() for line in files['mirror-'+name].decode().splitlines() if line.strip() and not line.lstrip().startswith('#')]
        if len(choices)!=1:raise ValueError('multiple or missing fixture mirrors require review')
        url=choices[0].rstrip('/')+'/'+suffix
    parts=urllib.parse.urlsplit(url)
    if parts.scheme not in ('http','https') or not parts.hostname or parts.username or parts.password or parts.fragment or parts.query or any(c.isspace() for c in url):
        raise ValueError('unsupported exported package URL')
    return url

def resolved_packages(files):
    """Match apt's selected archive to independent authenticated index metadata."""
    import shlex
    metadata={}
    for stanza in files['metadata.txt'].decode().strip().split('\n\n'):
        fields={line.split(': ',1)[0]:line.split(': ',1)[1] for line in stanza.splitlines() if ': ' in line and not line.startswith(' ')}
        if 'Filename' not in fields:continue  # installed dpkg status, not an index
        filename=urllib.parse.unquote(Path(fields['Filename']).name)
        if filename in metadata and metadata[filename][0]!=fields:raise ValueError('ambiguous package index metadata')
        metadata[filename]=(fields,stanza)
    result=[];seen=set()
    for line in files['uris.txt'].decode().splitlines():
        if not line.startswith("'"):continue
        parts=shlex.split(line)
        if len(parts) not in (3,4):raise ValueError('invalid apt URI record')
        # Recent security indices omit MD5. Trust only their SHA-256 below.
        url,filename,size=parts[:3];filename=urllib.parse.unquote(filename)
        if filename in seen or Path(filename).name!=filename or not filename.endswith('.deb'):raise ValueError('invalid resolved filename')
        seen.add(filename)
        remote_name=urllib.parse.unquote(Path(urllib.parse.urlsplit(url).path).name)
        fields,stanza=metadata[remote_name]
        # apt's cache filename may contain an epoch (1%3a...), while the
        # repository filename omits it. Compare the full package identity.
        identity=filename[:-4].rsplit('_',2)
        if int(size)!=int(fields['Size']) or identity!=[fields['Package'],fields['Version'],fields['Architecture']]:
            raise ValueError('apt resolution and index disagree')
        digest=fields['SHA256']
        if not re.fullmatch('[0-9a-f]{64}',digest):raise ValueError('authenticated SHA-256 missing')
        control='\n'.join(line for line in stanza.splitlines() if not line.startswith(('Filename:','Size:','SHA256:','SHA1:','MD5sum:')))+'\n'
        result.append(dict(filename=filename,url=resolve_exported_url(url,files),size=int(size),sha256=digest,control=control))
    if not result:raise ValueError('empty apt resolution')
    return result

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
                url=resolve_exported_url(package['url'],{})
                # HTTP pool URLs are allowed only because every byte is pinned by
                # the reviewed SHA-256 lock, originally resolved by authenticated apt.
                # A socket inactivity timeout does not bound a slowly trickling
                # response. curl supplies an overall deadline and size limit.
                with tempfile.TemporaryDirectory(prefix='lazycat-package-download-') as download:
                    path=Path(download)/'archive.deb'
                    subprocess.run(['curl','--fail','--silent','--show-error','--location','--proto','=http,https','--proto-redir','=http,https','--connect-timeout','15','--max-time','180','--max-filesize',str(size),url,'--output',str(path)],check=True,timeout=190)
                    if path.stat().st_size!=size:raise ValueError('package download size mismatch')
                    data=path.read_bytes()
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
        if 'metadata.txt' in files:
            packages=resolved_packages(files)
            # Use the same downloader/checksum verifier as ordinary CI, before
            # accepting the proposed lock. No guest dependency is preinstalled.
            with tempfile.TemporaryDirectory(prefix='lazycat-resolved-') as directory:
                proposed=Path(directory)/'lock.json'
                proposed.write_text(json.dumps(dict(format_version=1,image_digest=image['digest'],packages=packages)))
                materialize(proposed,image,cache,Path(directory)/'verified.tar')
            output.parent.mkdir(parents=True,exist_ok=True)
            if output.exists():raise ValueError('refusing to overwrite an existing reviewed package lock')
            output.write_text(json.dumps(dict(format_version=1,image_digest=image['digest'],scope='authenticated apt resolution, host downloads verified by SHA-256; review before CI adoption',packages=packages),indent=2)+'\n')
            return
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
