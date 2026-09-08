#!/usr/bin/env python3
"""Loopback TLS registry and observable proxy; never forwards to the internet."""
import hashlib
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
import json
from pathlib import Path
import select
import socket
import ssl
import threading

def encoded(value):return json.dumps(value,separators=(',',':')).encode()
def digest(data):return 'sha256:'+hashlib.sha256(data).hexdigest()
config=encoded(dict(architecture='amd64',os='linux',config={'Labels':{'lazycat.fixture':'verified'}},rootfs={'type':'layers','diff_ids':[]},history=[]))
manifest=encoded(dict(schemaVersion=2,mediaType='application/vnd.docker.distribution.manifest.v2+json',config=dict(mediaType='application/vnd.docker.container.image.v1+json',size=len(config),digest=digest(config)),layers=[]))

class Registry(BaseHTTPRequestHandler):
    def respond(self,body=True):
        with Path('/tmp/docker-registry-requests').open('a') as stream:stream.write(self.command+' '+self.path+'\n')
        if self.path.rstrip('/')=='/v2':data,kind=b'{}','application/json'
        elif self.path in ('/v2/test/image/manifests/fixture','/v2/test/image/manifests/'+digest(manifest)):
            data,kind=manifest,'application/vnd.docker.distribution.manifest.v2+json'
        elif self.path=='/v2/test/image/blobs/'+digest(config):data,kind=config,'application/octet-stream'
        else:self.send_error(404);return
        self.send_response(200);self.send_header('Content-Type',kind);self.send_header('Content-Length',str(len(data)));self.send_header('Docker-Content-Digest',digest(data));self.send_header('Docker-Distribution-Api-Version','registry/2.0');self.end_headers()
        if body:self.wfile.write(data)
    def do_GET(self):self.respond()
    def do_HEAD(self):self.respond(False)

class Proxy(BaseHTTPRequestHandler):
    def do_CONNECT(self):
        with Path('/tmp/docker-proxy-requests').open('a') as stream:stream.write(self.command+' '+self.path+'\n')
        if self.path!='registry.fixture.invalid:443' or not Path('/tmp/docker-proxy-allow').exists():
            self.send_error(502,'fixture denies registry access');return
        with socket.create_connection(('127.0.0.1',18443),timeout=5) as upstream:
            self.send_response(200,'Connection Established');self.end_headers();self.wfile.flush()
            peers=(self.connection,upstream)
            while True:
                ready,_,_=select.select(peers,[],[],15)
                if not ready:return
                for source in ready:
                    data=source.recv(65536)
                    if not data:return
                    (upstream if source is self.connection else self.connection).sendall(data)
    def do_GET(self):self.send_error(502,'fixture never forwards HTTP')

registry=ThreadingHTTPServer(('127.0.0.1',18443),Registry)
context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain('/tmp/docker-registry.crt','/tmp/docker-registry.key')
registry.socket=context.wrap_socket(registry.socket,server_side=True)
threading.Thread(target=registry.serve_forever,daemon=True).start()
server=ThreadingHTTPServer(('127.0.0.1',18081),Proxy)
Path('/tmp/docker-proxy-ready').touch()
server.serve_forever()
