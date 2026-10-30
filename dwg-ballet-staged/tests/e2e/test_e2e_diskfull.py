"""disk-full simulation: the server process gets RLIMIT_FSIZE so any write above N bytes fails (EFBIG) at a chosen point of SAVE!
(backup copy, temp write, gate re-parse files). Whatever N is, the original must be byte-identical or a complete valid new file, no temp junk."""
import os, sys, resource, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import *
EDIT = {'layers': {'A-WALL': {'off': True}}}


class DiskFull(unittest.TestCase):
    def setUp(self): self.e = Env(self.id().split('.')[-1], overwrite=True)
    def tearDown(self): self.e.close()

    def test_write_limit_sweep(self):
        a = self.e.drawing('a.dwg'); size = os.path.getsize(a); h0 = sha(a); outcomes = {}
        for frac in (0.0, 0.05, 0.3, 0.7, 0.95, 1.0, 1.02, 1.3, 3.0):
            lim = int(size * frac) + 1
            s = self.e.start(a); resource.prlimit(s.proc.pid, resource.RLIMIT_FSIZE, (lim, lim))   # after startup: logs/cache already open
            try: c, r = s.post('/api/save', EDIT)
            except Exception as ex: c, r = -1, {'error': repr(ex)}
            s.kill(); now = sha(a)
            outcomes[frac] = c
            if c == 200: self.assertTrue(valid_dwg(a), 'limit %s: 200 but invalid file' % frac); h0 = now
            else:
                self.assertEqual(now, h0, 'limit %s: status %s but original changed: %s' % (frac, c, r))
                self.assertIn(c, (409, 500, 400), (frac, c, r))
                self.assertTrue(valid_dwg(a))
                if c != -1: self.assertTrue(r.get("error") and "not" in r["error"].lower(), r)
            self.assertEqual(junk(self.e.work), [], 'limit %s left temp files' % frac)
        print('disk-full outcomes', outcomes)


if __name__ == '__main__': unittest.main()
