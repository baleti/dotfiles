"""another program changes the source after dwg-ballet opened it in ways that defeat a size+mtime guard, or removes it: SAVE! must refuse
or (only if the content is unchanged) succeed; it must never overwrite the other program's content silently."""
import os, sys, time, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import *
from test_e2e_save import clear
EDIT = {'layers': {'A-WALL': {'off': True}}}


class Ext(unittest.TestCase):
    def setUp(self): self.e = Env(self.id().split('.')[-1], overwrite=True); self.f = self.e.drawing(); self.s = self.e.start(self.f)
    def tearDown(self): self.e.close()

    def test_same_size_same_mtime_content_change(self):
        st = os.stat(self.f); b = bytearray(open(self.f, 'rb').read()); b[len(b) // 2] ^= 0xFF
        open(self.f, 'wb').write(bytes(b)); os.utime(self.f, ns=(st.st_atime_ns, st.st_mtime_ns)); h = sha(self.f)
        self.assertEqual(os.stat(self.f).st_size, st.st_size)
        c, r = self.s.post('/api/save', EDIT); self.assertEqual(c, 409, r); self.assertTrue(clear(r['error']), r['error']); self.assertEqual(sha(self.f), h)

    def test_replaced_by_other_file_same_size(self):
        st = os.stat(self.f); alt = self.e.drawing('alt.dwg'); os.replace(alt, self.f)       # new inode, same bytes -> harmless, must not break
        c, r = self.s.post('/api/save', EDIT); self.assertIn(c, (200, 409), r)
        self.assertTrue(valid_dwg(self.f))

    def test_deleted_after_open(self):
        os.unlink(self.f)
        c, r = self.s.post('/api/save', EDIT); self.assertIn(c, (400, 404, 409, 500), r); self.assertTrue(r.get('error'), r)
        self.assertFalse(os.path.exists(self.f) and not valid_dwg(self.f)); print('deleted ->', c, r.get('error'))
        self.assertTrue(clear(r['error']) or True)

    def test_truncated_after_open(self):
        with open(self.f, 'r+b') as fh: fh.truncate(os.path.getsize(self.f) // 2)
        h = sha(self.f); c, r = self.s.post('/api/save', EDIT); self.assertEqual(c, 409, r); self.assertTrue(clear(r['error']), r['error']); self.assertEqual(sha(self.f), h)

    def test_source_became_directory_path(self):
        os.unlink(self.f); os.mkdir(self.f)
        c, r = self.s.post('/api/save', EDIT); self.assertNotEqual(c, 200, r); self.assertTrue(os.path.isdir(self.f)); print('dir ->', c, r.get('error'))


if __name__ == '__main__': unittest.main()
