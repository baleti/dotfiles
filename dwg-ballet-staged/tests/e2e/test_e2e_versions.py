"""SAVE!, SAVE! again, RESTORE over HTTP on every template variant (blank/lt/spec/vp/xr x version): file valid after each step,
RESTORE returns the exact original bytes, refusals leave the file untouched."""
import os, sys, glob, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import *
EDIT = {'layers': {'A-WALL': {'off': True}}}


class Versions(unittest.TestCase):
    def test_every_template(self):
        e = Env('versions', overwrite=True); rows = {}
        try:
            for t in sorted(glob.glob(os.path.join(TPL, '*_20*.dwg'))):
                name = os.path.basename(t); f = os.path.join(e.work, name); import dwgdoc, wtest
                try: d = dwgdoc.Doc(open(t, 'rb').read()); wtest.basic(d); open(f, 'wb').write(d.save())
                except Exception as ex: rows[name] = 'cannot build %r' % ex; continue
                h0 = sha(f)
                s = e.start(f)
                try:
                    c, r = s.post('/api/save', EDIT)
                    if c != 200:
                        self.assertEqual(sha(f), h0, '%s refused %s but changed' % (name, c)); rows[name] = 'refused %s %s' % (c, str(r.get("error"))[:70]); continue
                    self.assertTrue(valid_dwg(f), name + ' invalid after save')
                    c2, r2 = s.post('/api/save', EDIT)
                    if c2 == 200: self.assertTrue(valid_dwg(f), name + ' invalid after 2nd save')
                    n = len(s.get('/api/backups')[1])
                    c3, r3 = s.post('/api/restore', {'n': n - 1}) if n else (0, 0)
                    self.assertEqual(c3, 200, (name, r3)); self.assertEqual(sha(f), h0, name + ' restore not byte-identical')
                    rows[name] = 'ok'
                finally: s.kill()
                self.assertEqual(junk(e.work), [], name)
            print(rows)
        finally: e.close()


if __name__ == '__main__': unittest.main()
