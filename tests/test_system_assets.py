"""Synthetic archives test the input gate, not actual product behavior."""
import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from system.assets import materialize_assets


class SystemAssets(unittest.TestCase):
    def test_verified_artifacts_and_known_bad_inputs(self):
        for failure in ('none','commit','development','checksum','checksums','provenance','architecture','driver','missing-script','duplicate','traversal'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root=Path(directory);assets=root/'assets';assets.mkdir();snapshot=root/'snapshot';(snapshot/'common').mkdir(parents=True)
                product=snapshot/'common/tool.sh';product.write_text('source sentinel\n')
                binary=root/'binary'
                manifest={'format_version':1,'commit':'fixture-commit','development':False,'dirty':False,
                    'source_tree_sha256':'a'*64,'versions':{'scripts':'lazycat-scripts-v0.0.0-test','ssh':'lazycat-ssh-v0.0.0-test'},'assets':[]}
                provenance=json.dumps({**manifest,'commit':'wrong' if failure=='provenance' else manifest['commit']}).encode()
                payload=bytearray(32);payload[:6]=b'\x7fELF\x02\x01';payload[18]=183 if failure=='architecture' else 62
                shell=[('BUILD.json',provenance),('common/tool.sh',b'packaged sentinel\n')]
                if failure=='driver':shell.append(('tests/run.py',b'malicious driver'))
                if failure=='missing-script':shell.pop()
                if failure=='duplicate':shell.append(shell[-1])
                if failure=='traversal':shell.append(('../escape',b'escape'))
                for name,files in [(manifest['versions']['scripts']+'.tar.gz',shell),
                    (manifest['versions']['ssh']+'-linux-amd64.tar.gz',[('BUILD.json',provenance),('lazycat-ssh',bytes(payload))])]:
                    path=assets/name
                    with tarfile.open(path,'w:gz') as tar:
                        for filename,data in files:
                            member=tarfile.TarInfo(filename);member.size=len(data);member.mode=0o755;tar.addfile(member,io.BytesIO(data))
                    manifest['assets'].append({'path':name,'sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
                checks=''.join(asset['sha256']+'  '+asset['path']+'\n' for asset in manifest['assets'])
                (assets/'SHA256SUMS').write_text(checks+checks if failure=='checksums' else checks)
                if failure=='checksum':manifest['assets'][0]['sha256']='0'*64
                if failure=='development':manifest['development']=True
                (assets/'manifest.json').write_text(json.dumps(manifest))
                if failure=='none':
                    report=materialize_assets(assets,snapshot,binary,'fixture-commit')
                    self.assertEqual(product.read_text(),'packaged sentinel\n')
                    self.assertEqual(binary.read_bytes(),payload)
                    self.assertEqual(report['client_origin'],'verified-release-archive')
                else:
                    with self.assertRaises(ValueError):
                        materialize_assets(assets,snapshot,binary,'other' if failure=='commit' else 'fixture-commit')
                    self.assertEqual(product.read_text(),'source sentinel\n')
                    self.assertFalse(binary.exists())
                    self.assertFalse((root/'escape').exists())
