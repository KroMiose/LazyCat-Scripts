"""Preserve signed OpenWrt feeds and exact archives from a preparation VM."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import tarfile
import tempfile
import urllib.parse

if __package__:
    from .packages import cache_bytes
else:
    from packages import cache_bytes


def safe_path(name):
    path=PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts or str(path)!=name or any(c.isspace() for c in name):
        raise ValueError('unsafe opkg resource path')
    return path


def official_url(url):
    parsed=urllib.parse.urlsplit(url)
    if parsed.scheme!='https' or parsed.netloc!='downloads.openwrt.org' or parsed.query or parsed.fragment or any(c.isspace() for c in url):
        raise ValueError('unexpected opkg upstream URL')
    safe_path(parsed.path.lstrip('/'))
    return url


def resolve_export(files):
    resources=[];index={};feed_names=set()
    for line in files['feeds.txt'].decode().splitlines():
        name,url=line.split()
        if not re.fullmatch('[A-Za-z0-9_-]+',name) or name in feed_names:raise ValueError('invalid/duplicate feed')
        feed_names.add(name);official_url(url)
        for filename in ('Packages','Packages.sig'):
            path='feeds/'+name+'/'+filename;payload=files[path]
            if not payload:raise ValueError('empty signed feed')
            resources.append(dict(path=path,url=url+'/'+filename,size=len(payload),sha256=hashlib.sha256(payload).hexdigest()))
        for stanza in files['feeds/'+name+'/Packages'].decode().strip().split('\n\n'):
            fields={}
            for line in stanza.splitlines():
                if line.startswith((' ','\t')) or ': ' not in line:continue
                key,value=line.split(': ',1)
                if key in fields:raise ValueError('duplicate package field')
                fields[key]=value
            if 'Filename' not in fields:continue
            filename=fields['Filename'];safe_path(filename)
            if '/' in filename or not filename.endswith('.ipk'):raise ValueError('unsupported archive filename')
            if filename in index:raise ValueError('ambiguous package in feeds')
            index[filename]=(name,url,fields)
    packages=[]
    for path,payload in files.items():
        if not path.startswith('cache/'):continue
        filename=path.removeprefix('cache/')
        if filename not in index:raise ValueError('download absent from signed package index: '+filename)
        name,url,fields=index[filename]
        if not re.fullmatch('[a-f0-9]{64}',fields.get('SHA256sum','')):raise ValueError('signed package digest missing')
        if len(payload)!=int(fields['Size']) or hashlib.sha256(payload).hexdigest()!=fields['SHA256sum']:
            raise ValueError('opkg archive differs from signed metadata')
        resources.append(dict(path='feeds/'+name+'/'+filename,url=url+'/'+filename,size=len(payload),sha256=fields['SHA256sum']))
        packages.append(fields['Package'])
    if not {'bash','openssh-keygen','openssh-client','openssh-server'}<=set(packages):raise ValueError('required target archive not resolved')
    return resources


def record_export(archive_path,image,cache,output):
    files={}
    with tarfile.open(archive_path) as archive:
        for member in archive:
            if member.isdir():continue
            name=member.name.removeprefix('./');safe_path(name)
            if not member.isfile() or name in files or not 0<member.size<64*1024*1024:raise ValueError('invalid opkg export member')
            files[name]=archive.extractfile(member).read()
    resources=resolve_export(files)
    cache.mkdir(parents=True,exist_ok=True)
    for resource in resources:
        name=resource['path']
        source=name if not name.endswith('.ipk') else 'cache/'+Path(name).name
        cache_bytes(cache,resource['sha256'],files[source])
    if output.exists():raise ValueError('refusing to overwrite existing package lock')
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(json.dumps(dict(format_version=1,manager='opkg',image_digest=image['digest'],scope='signed indexes verified by image usign keys; opkg download-only; fresh offline lifecycle required before adoption',resources=resources),indent=2)+'\n')


def materialize(lock_path,image,cache,destination,fresh=False):
    raw=lock_path.read_bytes();lock=json.loads(raw)
    if lock.get('format_version')!=1 or lock.get('manager')!='opkg' or lock.get('image_digest')!=image['digest']:raise ValueError('opkg lock/base mismatch')
    cache.mkdir(parents=True,exist_ok=True);seen=set();resources=lock.get('resources',[])
    if not resources:raise ValueError('empty opkg lock')
    with tempfile.TemporaryDirectory(prefix='lazycat-opkg-') as directory:
        root=Path(directory)
        for resource in resources:
            name=resource['path'];parts=safe_path(name).parts
            if len(parts)!=3 or parts[0]!='feeds' or name in seen:raise ValueError('unexpected opkg resource')
            seen.add(name);digest=resource['sha256'];size=resource['size'];url=official_url(resource['url'])
            if not re.fullmatch('[a-f0-9]{64}',digest) or type(size) is not int or not 0<size<64*1024*1024:raise ValueError('invalid opkg size/digest')
            cached=cache/digest
            if fresh or not cached.exists():
                download=root/'download'
                subprocess.run(['curl','--fail','--silent','--show-error','--location','--proto','=https','--proto-redir','=https','--connect-timeout','15','--max-time','180','--max-filesize',str(size),url,'-o',str(download)],check=True,timeout=190)
                payload=download.read_bytes()
                if len(payload)!=size or hashlib.sha256(payload).hexdigest()!=digest:raise ValueError('opkg resource download mismatch')
                cache_bytes(cache,digest,payload);download.unlink()
            payload=cached.read_bytes()
            if len(payload)!=size or hashlib.sha256(payload).hexdigest()!=digest:raise ValueError('opkg cache mismatch')
            target=root/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(payload)
        for feed in (root/'feeds').iterdir():
            if not (feed/'Packages').is_file() or not (feed/'Packages.sig').is_file():raise ValueError('feed missing signed index')
        with tarfile.open(destination,'w') as archive:
            for path in sorted(root.rglob('*')):
                if path.is_file():archive.add(path,arcname=str(path.relative_to(root)))
    return hashlib.sha256(raw).hexdigest()
