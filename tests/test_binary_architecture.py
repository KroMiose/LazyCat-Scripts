"""Header parser tests only; native execution is verified on real runners."""
import struct
import unittest
from package import binary_platform

class BinaryArchitecture(unittest.TestCase):
    def test_actual_headers_and_unsupported_formats(self):
        for system,architecture,machine in [('linux','amd64',62),('linux','arm64',183),('darwin','amd64',0x1000007),('darwin','arm64',0x100000c)]:
            payload=bytearray(32)
            if system=='linux':payload[:6]=b'\x7fELF\x02\x01';struct.pack_into('<H',payload,18,machine)
            else:payload[:4]=b'\xcf\xfa\xed\xfe';struct.pack_into('<I',payload,4,machine)
            self.assertEqual(binary_platform(payload),system+'/'+architecture)
        for payload in (b'',b'\xca\xfe\xba\xbe'+bytes(28),b'#!/bin/sh\n'+bytes(32),b'\x7fELF\x01\x01'+bytes(26),b'\x7fELF\x02\x01'+bytes(26)):
            with self.assertRaises(ValueError):binary_platform(payload)
