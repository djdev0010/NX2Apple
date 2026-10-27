"""An NRO's header is not code (GitHub issue #14).

An NRO's text segment starts at offset 0 with the file's own header in it: Hades' EOSSDK-Switch-Shipping.nro has text
{0x0, 0xa41000} in its segment table and NRO0 at +0x10. Scanning it from 0 read the header's build ID as instructions and
reported `44 ldr x18, #0xfffffffffff40370` on Final Fantasy X/X-2 HD Remaster. The segment table cannot give the bound
(it says 0): the earlier TEXT_LO = segs[0][1] form kept scanning the header, and used TEXT_LO before defining it, which
stopped every rewrite with a NameError.

patch_nso.py's code_start() is 0x80 for an NRO and 0 for an NSO, and code_ranges() starts no code range before it; both
scans (the x18 words and the rewrite sites) walk those ranges. This is seedds/nxnative#397, carried by patch_patch_nso in
scripts/sync_upstream.py until it is upstream (its own test there is test_nro_code_start.py). The functions are taken
from patch_nso.py itself, which runs as a script.
"""
import ast
from pathlib import Path
import struct
import unittest

TOOLS = Path(__file__).resolve().parents[1]
SOURCE = (TOOLS / 'patch_nso.py').read_text(encoding='utf-8')
scope = {}
exec(compile(ast.Module(body=[n for n in ast.parse(SOURCE).body if isinstance(n, ast.FunctionDef) and n.name in ('code_start', 'code_ranges')],
                        type_ignores=[]), str(TOOLS / 'patch_nso.py'), 'exec'), scope)
code_start, code_ranges = scope['code_start'], scope['code_ranges']

LDR_X18 = 0x58000000 | (0x7ff40370 >> 2 & 0x7ffff) << 5 | 18   # a literal load into x18: what the build ID's bytes read as


def nro(text_size=0x1000):
    """A synthetic NRO's first 0x80 bytes, laid out as Hades' EOS NRO is: text at offset 0 with the header inside it"""
    h = bytearray(0x80)
    h[0x10:0x14] = b'NRO0'
    struct.pack_into('<II', h, 0x20, 0, text_size)   # text {offset, size}
    struct.pack_into('<I', h, 0x44, LDR_X18)   # inside the build ID
    return bytes(h)


class CodeStart(unittest.TestCase):
    def test_an_nro_s_header_is_outside_every_code_range(self):
        d = nro()
        self.assertEqual(struct.unpack_from('<II', d, 0x20)[0], 0, 'the segment table says 0, so it cannot bound the scan')
        self.assertEqual(code_start(d), 0x80)
        ranges = code_ranges([(0x400, 0x500)], 0x1000, code_start(d))
        self.assertEqual(ranges, [(0x80, 0x400), (0x500, 0x1000)])
        self.assertFalse(any(s <= 0x44 < e for s, e in ranges))

    def test_an_nso_keeps_its_ranges(self):
        self.assertEqual(code_start(b'NSO0' + bytes(0x7c)), 0)
        self.assertEqual(code_ranges([(0x400, 0x500)], 0x1000), [(0, 0x400), (0x500, 0x1000)])

    def test_the_bounds_are_defined_before_the_scan_uses_them(self):
        """The NameError: each name the scan reads is assigned above its first use"""
        for name, use in (('CODE_START', 'starts = sorted('), ('CODE_RANGES', 'x18 = set().union(')):
            self.assertLess(SOURCE.index(f'{name} = '), SOURCE.index(use), name)
        self.assertNotIn('TEXT_LO', SOURCE)


if __name__ == '__main__':
    unittest.main()
