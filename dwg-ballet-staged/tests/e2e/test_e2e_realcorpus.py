"""LOCAL ONLY (skipped unless E2E_CORPUS=dir): HTTP SAVE! with a layer toggle on real drawings of every version found in a corpus dir.
Per file: refusal (409) must leave it byte-identical; 200 must give a valid re-parseable file, a byte-identical backup, and RESTORE must return the original.
Only aggregate numbers and short ids are printed."""
import os, sys, glob, hashlib, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import *
CORPUS = os.environ.get('E2E_CORPUS'); MAXN = int(os.environ.get('E2E_N', '12')); MAXMB = float(os.environ.get('E2E_MAXMB', '3'))


@unittest.skipUnless(CORPUS, 'set E2E_CORPUS')
class Real(unittest.TestCase):
    def test_corpus(self):
        import dwgdoc
        files = [f for f in sorted(glob.glob(os.path.join(CORPUS, '**', '*.dwg'), recursive=True)) if os.path.getsize(f) < MAXMB * 1e6]
        by = {}
        for f in files: by.setdefault(open(f, 'rb').read(6), []).append(f)
        pick = [f for v in sorted(by) for f in by[v][:max(1, MAXN // max(1, len(by)))]]
        e = Env('realcorpus', overwrite=True); tally = {'ok': 0, 'refused': 0, 'unreadable': 0}; bad = []
        try:
            for i, src in enumerate(pick):
                ver = open(src, 'rb').read(6).decode('latin1'); f = os.path.join(e.work, 'f%d.dwg' % i); open(f, 'wb').write(open(src, 'rb').read()); h0 = sha(f)
                try: lay = [l for l in dwgdoc.Doc(open(f, 'rb').read()).layers()]; name = getattr(lay[0], 'name', None) or lay[0][0]
                except Exception: tally['unreadable'] += 1; continue
                s = e.start(f)
                try:
                    c, r = s.post('/api/save', {'layers': {name: {'off': True}}})
                    if c != 200:
                        tally['refused'] += 1
                        if sha(f) != h0: bad.append((i, ver, 'refused but changed'))
                        continue
                    if not valid_dwg(f): bad.append((i, ver, 'invalid after save'))
                    b = r.get('backup')
                    if not (b and os.path.isfile(b) and sha(b) == h0): bad.append((i, ver, 'backup not identical'))
                    c2, _ = s.post('/api/restore', {'n': 0})
                    if c2 != 200 or sha(f) != h0: bad.append((i, ver, 'restore mismatch'))
                    tally['ok'] += 1
                finally: s.kill()
                if junk(e.work): bad.append((i, ver, 'junk'))
            print('real corpus', len(pick), 'files', tally, 'bad', bad)
            self.assertEqual(bad, [])
        finally: e.close()


if __name__ == '__main__': unittest.main()
