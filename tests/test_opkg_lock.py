"""Metadata/lock rejection checks; real signature/opkg behavior lives in QEMU."""
import copy
import hashlib
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from system.opkg import resolve_export, materialize, official_url

class OpkgLock(unittest.TestCase):
    def fixture(self):
        files={'feeds.txt':b'fixture https://downloads.openwrt.org/fixture\n','feeds/fixture/Packages.sig':b'fictional-signature-not-real-system-coverage'}
        index=[]
        for name in ('bash','openssh-client','openssh-keygen','openssh-server'):
            payload=('fictional '+name+' archive').encode();filename=name+'_1_x86_64.ipk';files['cache/'+filename]=payload
            index.append('Package: '+name+'\nVersion: 1\nArchitecture: x86_64\nFilename: '+filename+'\nSize: '+str(len(payload))+'\nSHA256sum: '+hashlib.sha256(payload).hexdigest()+'\n')
        files['feeds/fixture/Packages']=('\n'.join(index)).encode()
        return files

    def test_archive_must_match_signed_metadata(self):
        files=self.fixture();resources=resolve_export(files)
        self.assertEqual(len(resources),6)
        for mutate in ('hash','missing','path','duplicate','upstream'):
            changed=copy.deepcopy(files)
            if mutate=='hash':changed['cache/bash_1_x86_64.ipk']=b'wrong'
            elif mutate=='missing':del changed['cache/bash_1_x86_64.ipk']
            elif mutate=='path':changed['feeds/fixture/Packages']=changed['feeds/fixture/Packages'].replace(b'Filename: bash',b'Filename: ../bash')
            elif mutate=='duplicate':changed['feeds/fixture/Packages']+=changed['feeds/fixture/Packages']
            else:changed['feeds.txt']=b'fixture https://attacker.invalid/fixture\n'
            with self.subTest(mutate=mutate),self.assertRaises(ValueError):resolve_export(changed)
        for url in ('http://downloads.openwrt.org/a','https://downloads.openwrt.org@evil.invalid/a','https://downloads.openwrt.org/../a'):
            with self.assertRaises(ValueError):official_url(url)

    def test_exact_base_signed_feed_and_cache(self):
        files=self.fixture();resources=resolve_export(files)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);cache=root/'cache';cache.mkdir()
            for resource in resources:
                source=resource['path'] if not resource['path'].endswith('.ipk') else 'cache/'+Path(resource['path']).name
                (cache/resource['sha256']).write_bytes(files[source])
            lock=root/'lock.json';data=dict(format_version=1,manager='opkg',image_digest='fixture',resources=resources);lock.write_text(json.dumps(data))
            materialize(lock,{'digest':'fixture'},cache,root/'repo.tar')
            with tarfile.open(root/'repo.tar') as archive:
                self.assertEqual(archive.extractfile('feeds/fixture/Packages').read(),files['feeds/fixture/Packages'])
                self.assertEqual(archive.extractfile('feeds/fixture/Packages.sig').read(),files['feeds/fixture/Packages.sig'])
            with self.assertRaises(ValueError):materialize(lock,{'digest':'another-base'},cache,root/'bad.tar')
            broken={**data,'resources':[r for r in resources if not r['path'].endswith('.sig')]};lock.write_text(json.dumps(broken))
            with self.assertRaises(ValueError):materialize(lock,{'digest':'fixture'},cache,root/'bad.tar')
            lock.write_text(json.dumps(data));(cache/resources[0]['sha256']).write_bytes(b'changed')
            with self.assertRaises(ValueError):materialize(lock,{'digest':'fixture'},cache,root/'bad.tar')
