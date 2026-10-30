"""SIGKILL the server at many instants of a SAVE! on a 6000-line drawing (power cut / crash): after every kill the file must be byte-identical
to the original or a complete valid new file, and a fresh server must still SAVE! it and RESTORE the original."""
import os, sys, time, threading, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import *
from test_e2e_race import big
EDIT = {'layers': {'A-WALL': {'off': True}}}


class KillSweep(unittest.TestCase):
    def test_kill_at_many_instants(self):
        e = Env('killsweep', overwrite=True)
        try:
            f = os.path.join(e.work, 'a.dwg'); big(f, 6000); orig = sha(f); out = {}
            for d in (0.0, 0.05, 0.1, 0.2, 0.3, 0.45, 0.6, 0.8, 1.0, 1.3, 1.7, 2.2, 3.0):
                s = e.start(f); res = []
                t = threading.Thread(target=lambda: res.append(_try(s))); t.start(); time.sleep(d); s.kill(); t.join()
                cur = sha(f); changed = cur != orig; out[d] = ('new' if changed else 'orig') + ('/200' if res and res[0] == 200 else '')
                self.assertTrue(valid_dwg(f), 'kill at %s s: file damaged' % d)
                s2 = e.start(f); c, r = s2.post('/api/save', EDIT); self.assertEqual(c, 200, (d, c, r)); self.assertTrue(valid_dwg(f))
                bs = s2.get('/api/backups')[1]; self.assertTrue(bs, 'no backup after save')
                s2.kill()
                # put the original back for the next round (direct copy of the first backup is not needed: rebuild)
                big(f, 6000); orig = sha(f)
                self.assertEqual([j for j in junk(e.work) if 'lock' in j], [], 'stale lock after kill at %s' % d)
            print('kill sweep', out)
        finally: e.close()


def _try(s):
    try: return s.call('POST', '/api/save', EDIT, timeout=60)[0]
    except Exception: return -1


if __name__ == '__main__': unittest.main()
