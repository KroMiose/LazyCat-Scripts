import hashlib
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from system.packages import materialize, resolved_packages

class PackageLock(unittest.TestCase):
    def test_download_uses_real_http_and_rejects_truncation(self):
        import http.server
        import threading
        import subprocess
        import os
        from unittest.mock import patch
        payload=b'fictional package bytes; this tests transport, not apt'
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200);self.send_header('Content-Length',str(len(payload)));self.end_headers()
                self.wfile.write(payload if self.path=='/complete' else payload[:3])
            def log_message(self,*args):pass
        server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
        thread=threading.Thread(target=server.serve_forever);thread.start()
        try:
            with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ,{'PATH':'/usr/bin:/bin','NO_PROXY':'127.0.0.1'},clear=True):
                root=Path(directory);digest=hashlib.sha256(payload).hexdigest()
                package=dict(filename='fixture_1_amd64.deb',sha256=digest,size=len(payload),url=f'http://127.0.0.1:{server.server_port}/complete',control='Package: fixture\nVersion: 1\nArchitecture: amd64\n')
                lock=root/'lock.json';data=dict(format_version=1,image_digest='fixture',packages=[package]);lock.write_text(json.dumps(data))
                materialize(lock,{'digest':'fixture'},root/'cache',root/'repo.tar')
                self.assertEqual((root/'cache'/digest).read_bytes(),payload)
                package['url']=package['url'].replace('/complete','/truncated');lock.write_text(json.dumps(data))
                with self.assertRaises((subprocess.CalledProcessError,ValueError)):
                    materialize(lock,{'digest':'fixture'},root/'failed-cache',root/'failed.tar')
                self.assertFalse((root/'failed-cache'/digest).exists());self.assertFalse((root/'failed.tar').exists())
        finally:
            server.shutdown();thread.join();server.server_close()

    def test_authenticated_resolution_and_fixture_mirror(self):
        name='fixture_1+2_amd64.deb';digest='a'*64
        url='mirror+file:/etc/apt/mirrors/debian.list/pool/main/f/'+name.replace('+','%2b')
        files={'uris.txt':("'%s' %s 12 MD5Sum:unused\n"%(url,name)).encode(),
               'metadata.txt':('Package: fixture\nVersion: 1+2\nArchitecture: amd64\nFilename: pool/main/f/'+name+'\nSize: 12\nSHA256: '+digest+'\nDescription: fixture\n').encode(),
               'mirror-debian.list':b'https://deb.debian.org/debian\n'}
        result=resolved_packages(files)
        self.assertEqual(result[0]['url'],'https://deb.debian.org/debian/pool/main/f/fixture_1%2b2_amd64.deb')
        self.assertEqual(result[0]['sha256'],digest)
        self.assertNotIn('Filename:',result[0]['control'])
        self.assertEqual(resolved_packages({**files,'uris.txt':files['uris.txt'].replace(b' MD5Sum:unused',b'')}),result)
        epoch={**files,'uris.txt':files['uris.txt'].replace((' '+name+' ').encode(),b' fixture_1%3a1+2_amd64.deb '),
               'metadata.txt':files['metadata.txt'].replace(b'Version: 1+2',b'Version: 1:1+2')}
        self.assertEqual(resolved_packages(epoch)[0]['filename'],'fixture_1:1+2_amd64.deb')
        for key,value in [('metadata.txt',files['metadata.txt'].replace(b'Size: 12',b'Size: 13')),
                          ('metadata.txt',files['metadata.txt'].replace(digest.encode(),b'not-a-sha256')),
                          ('mirror-debian.list',b'https://one.invalid\nhttps://two.invalid\n'),
                          ('uris.txt',files['uris.txt']*2)]:
            with self.subTest(key=key),self.assertRaises(ValueError):resolved_packages({**files,key:value})

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
