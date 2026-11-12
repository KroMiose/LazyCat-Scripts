import gzip
from pathlib import Path
import struct
import tempfile
import unittest
import zlib
from system.vm import extract_image, source_snapshot

class VMArchive(unittest.TestCase):
    def test_plain_and_fwtool_trailer(self):
        data = gzip.compress(b'fixture disk')
        signature = b'# fake certificate'
        signed = data + signature
        signed += struct.pack('>IIB3xI', 0x46577830, zlib.crc32(signed)^0xffffffff, 0, len(signature)+16)
        for payload in (data, signed):
            with tempfile.TemporaryDirectory() as directory:
                source, target = Path(directory)/'source', Path(directory)/'disk'
                source.write_bytes(payload)
                extract_image(source, target)
                self.assertEqual(target.read_bytes(), b'fixture disk')

    def test_trailing_junk_and_bad_crc_rejected(self):
        data = gzip.compress(b'fixture disk')
        for payload in (data+b'junk', data+struct.pack('>IIB3xI', 0x46577830, 123, 0, 16)):
            with tempfile.TemporaryDirectory() as directory:
                source, target = Path(directory)/'source', Path(directory)/'disk'
                source.write_bytes(payload)
                with self.assertRaises((ValueError, OSError)):
                    extract_image(source,target)

    def test_snapshot_includes_new_fixtures_and_rejects_source_links(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);fixture=root/'tests/fixtures/legacy/new-component.sh'
            fixture.parent.mkdir(parents=True);fixture.write_text('fixture bytes');fixture.chmod(0o640)
            self.assertEqual(source_snapshot(root),[('tests/fixtures/legacy/new-component.sh',b'fixture bytes',0o640)])
            (fixture.parent/'alias.sh').symlink_to(fixture)
            with self.assertRaises(ValueError):source_snapshot(root)
