import hashlib
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from system.packages import materialize

class PackageLock(unittest.TestCase):
    def test_exact_cache_and_base_required(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);cache=root/'cache';cache.mkdir();payload=b'fictional archive bytes, not apt coverage'
            digest=hashlib.sha256(payload).hexdigest();(cache/digest).write_bytes(payload)
            package=dict(filename='fixture_1_amd64.deb',sha256=digest,size=len(payload),url='https://example.invalid/fixture.deb',control='Package: fixture\nVersion: 1\nArchitecture: amd64\n')
            data=dict(format_version=1,image_digest='image-digest',packages=[package]);lock=root/'lock.json';lock.write_text(json.dumps(data))
            output=root/'repo.tar';materialize(lock,{'digest':'image-digest'},cache,output)
            with tarfile.open(output) as archive:
                self.assertEqual(archive.extractfile(package['filename']).read(),payload)
                self.assertIn(('SHA256: '+digest).encode(),archive.extractfile('Packages').read())
            with self.assertRaises(ValueError):materialize(lock,{'digest':'another-image'},cache,output)
            for field,value in [('filename','../escape.deb'),('filename','newline\nfile.deb'),('sha256','../escape'),('control','Package: fixture\nFilename: other\n')]:
                lock.write_text(json.dumps({**data,'packages':[{**package,field:value}]}))
                with self.subTest(field=field),self.assertRaises(ValueError):materialize(lock,{'digest':'image-digest'},cache,output)
            lock.write_text(json.dumps(data));(cache/digest).write_bytes(b'bad')
            with self.assertRaises(ValueError):materialize(lock,{'digest':'image-digest'},cache,output)
