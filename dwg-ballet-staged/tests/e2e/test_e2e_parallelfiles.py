"""several servers, each with its own file, SAVE! at the same moment while sharing ONE backup/cache store: every file valid, every backup
belongs to its own file (byte-identical to that file's original), RESTORE of each returns its own original."""
import os, sys, threading, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import *
from test_e2e_race import big
EDIT = {'layers': {'A-WALL': {'off': True}}}


class Parallel(unittest.TestCase):
    def test_four_files_at_once(self):
        e = Env('parallel', overwrite=True)
        try:
            fs = []
            for i in range(4):
                f = os.path.join(e.work, 'p%d.dwg' % i); big(f, 300 + 700 * i); fs.append((f, sha(f)))
            ss = [e.start(f) for f, _ in fs]; res = [None] * 4
            def go(i): res[i] = ss[i].post('/api/save', EDIT)
            ts = [threading.Thread(target=go, args=(i,)) for i in range(4)]; [t.start() for t in ts]; [t.join() for t in ts]
            for i, (f, h0) in enumerate(fs):
                c, r = res[i]; self.assertEqual(c, 200, (i, r)); self.assertTrue(valid_dwg(f)); self.assertNotEqual(sha(f), h0)
                b = r['backup']; self.assertEqual(sha(b), h0, 'backup of file %d is not its own original' % i)
            for i, (f, h0) in enumerate(fs):
                c, r = ss[i].post('/api/restore', {'n': 0}); self.assertEqual(c, 200, r); self.assertEqual(sha(f), h0, 'restore %d wrong' % i)
            self.assertEqual(junk(e.work), [])
        finally: e.close()


if __name__ == '__main__': unittest.main()
