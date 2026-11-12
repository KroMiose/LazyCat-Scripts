#!/usr/bin/env python3
"""Build immutable candidate assets; never publish or update a stable pointer."""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
ROOT=Path(__file__).resolve().parents[1]

def tarball(path,files):
    with path.open('wb') as output,gzip.GzipFile(filename='',fileobj=output,mode='wb',mtime=0) as zipped,tarfile.open(fileobj=zipped,mode='w') as archive:
        for name,data,mode in sorted(files):
            info=tarfile.TarInfo(name);info.size=len(data);info.mode=mode;info.mtime=0;info.uid=info.gid=0
            archive.addfile(info,io.BytesIO(data))

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--scripts-version',required=True);parser.add_argument('--ssh-version',required=True);parser.add_argument('--output',type=Path,required=True);parser.add_argument('--development',action='store_true');a=parser.parse_args()
    for prefix,value in [('lazycat-scripts',a.scripts_version),('lazycat-ssh',a.ssh_version)]:
        if not re.fullmatch(prefix+r'-v\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?',value):raise ValueError('invalid version: '+value)
    dirty=bool(subprocess.check_output(['git','status','--porcelain'],cwd=ROOT))
    if dirty and not a.development:raise ValueError('release requires a clean candidate; use --development only for local review')
    if a.output.exists():raise ValueError('output already exists; immutable assets are not overwritten')
    a.output.mkdir(parents=True)
    subprocess.run(['python3','scripts/embed.py','--check'],cwd=ROOT,check=True)
    commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    manifest={'format_version':1,'commit':commit,'development':a.development,'dirty':dirty,'versions':{'scripts':a.scripts_version,'ssh':a.ssh_version},'assets':[],'evidence':{}}
    names=subprocess.check_output(['git','ls-files','-z','--cached','--others','--exclude-standard'],cwd=ROOT).split(b'\0')
    frozen=[]
    for raw in sorted(set(names)):
        if not raw:continue
        name=os.fsdecode(raw);source=ROOT/name
        if source.is_symlink():raise ValueError('build input symlink requires review: '+name)
        if source.is_file():frozen.append((name,source.read_bytes(),source.stat().st_mode & 0o777))
    tree=hashlib.sha256()
    for name,data,mode in frozen:
        tree.update(name.encode()+b'\0'+str(mode).encode()+b'\0'+hashlib.sha256(data).digest())
    manifest['source_tree_sha256']=tree.hexdigest()
    manifest['go_version']=subprocess.check_output(['go','version'],text=True).strip()
    with tempfile.TemporaryDirectory(prefix='lazycat-build-source-') as directory:
        snapshot=Path(directory)
        for name,data,mode in frozen:
            path=snapshot/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data);path.chmod(mode)
        build_assets(a,snapshot,manifest)
    print('Candidate assets built. Cross-compilation is not native platform verification. No stable pointer changed.')

def build_assets(a,snapshot,manifest):
    common=(snapshot/'ssh/lib/common.sh').read_text()
    scripts=[]
    for folder in ('common','linux','ssh/client','ssh/ca','ssh/node','ssh/lib'):
        for source in sorted((snapshot/folder).glob('*')):
            if not source.is_file() or source.suffix not in ('.sh','.md'):continue
            data=source.read_bytes()
            if folder in ('ssh/client','ssh/ca','ssh/node') and source.suffix=='.sh' and b'\n__lc_source_common\n' in data:
                data=data.replace(b'\n__lc_source_common\n',b'\n# Bundled common.sh: no runtime download/cache sourcing.\n'+common.encode()+b'\n',1)
            scripts.append((str(source.relative_to(snapshot)),data,0o755 if source.suffix=='.sh' else 0o644))
    reference='https://github.com/KroMiose/LazyCat-Scripts/tree/'+manifest['commit']
    readme='# LazyCat Shell candidate\n\nVersion: '+a.scripts_version+'\n\nReview scripts before running. User configuration tools run as the intended ordinary user; system changes require an explicit maintenance operation. Existing keys, credentials and backups are not migrated by unpacking this archive.\n\nEntries: common/, linux/, ssh/ca/, ssh/node/. ssh/client/ contains the legacy Shell client. SSH shared code is bundled into executable entrypoints.\n\nSource documentation and test drivers: '+reference+'\n\nDevelopment archives can include uncommitted changes; BUILD.json identifies the exact source snapshot. This archive does not promote stable.\n'
    scripts.append(('README.md',readme.encode(),0o644))
    provenance={key:manifest[key] for key in ('commit','development','dirty','source_tree_sha256','go_version','versions')}
    scripts.append(('BUILD.json',(json.dumps(provenance,indent=2)+'\n').encode(),0o644))
    tarball(a.output/(a.scripts_version+'.tar.gz'),scripts)
    with tempfile.TemporaryDirectory(prefix='lazycat-release-') as directory:
        work=Path(directory)
        subprocess.run(['go','mod','download','all'],cwd=snapshot/'ssh',check=True,timeout=180)
        modules=subprocess.check_output(['go','list','-m','-json','all'],cwd=snapshot/'ssh',text=True)
        decoder=json.JSONDecoder();remaining=modules;notices=[]
        while remaining.strip():
            module,offset=decoder.raw_decode(remaining.lstrip());remaining=remaining.lstrip()[offset:]
            if module.get('Main'):continue
            source=Path(module['Dir']);licenses=[x for x in source.iterdir() if x.is_file() and x.name.upper().startswith(('LICENSE','COPYING','NOTICE'))]
            if not licenses:raise ValueError('dependency license missing: '+module['Path'])
            for license in licenses:
                notices.append(('licenses/'+module['Path']+'@'+module['Version']+'/'+license.name,license.read_bytes(),0o644))
        for system in ('linux','darwin'):
            for arch in ('amd64','arm64'):
                binary=work/f'lazycat-ssh-{system}-{arch}'
                subprocess.run(['go','build','-trimpath','-ldflags','-s -w -X main.version='+a.ssh_version,'-o',str(binary),'.'],cwd=snapshot/'ssh',env={**os.environ,'CGO_ENABLED':'0','GOOS':system,'GOARCH':arch},check=True,timeout=240)
                tarball(a.output/f'{a.ssh_version}-{system}-{arch}.tar.gz',[
                    ('lazycat-ssh',binary.read_bytes(),0o755),
                    ('README.md',('LazyCat SSH candidate '+a.ssh_version+'\n\nRun lazycat-ssh help for CLI usage. Stage independently and use migrate --check before activation. Existing keys and unknown resources are preserved.\n\nFull source documentation: '+reference+'/ssh\n\nSee BUILD.json for development status and exact source snapshot. Cross-compilation is not native verification.\n').encode(),0o644),
                    ('BUILD.json',(json.dumps({**provenance,'os':system,'architecture':arch},indent=2)+'\n').encode(),0o644),
                    ('go.mod',(snapshot/'ssh/go.mod').read_bytes(),0o644),
                    ('go.sum',(snapshot/'ssh/go.sum').read_bytes(),0o644)]+notices)
    shutil.copyfile(snapshot/'scripts/install-ssh.sh',a.output/'install-ssh.sh')
    for path in sorted(a.output.iterdir()):
        manifest['assets'].append({'path':path.name,'sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
    (a.output/'SHA256SUMS').write_text(''.join(x['sha256']+'  '+x['path']+'\n' for x in manifest['assets']))
    (a.output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')

if __name__=='__main__':main()
