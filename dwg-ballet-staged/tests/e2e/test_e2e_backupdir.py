"""the backup store is the safety net of SAVE!: if it cannot be written (read-only dir, path is a file, deleted under us) the save must be
refused with the source untouched, never done without a backup."""
import os, sys, shutil, stat, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import *
from test_e2e_save import clear
EDIT = {'layers': {'A-WALL': {'off': True}}}


class BackupDir(unittest.TestCase):
    def setUp(self): self.e = Env(self.id().split('.')[-1], overwrite=True); self.f = self.e.drawing(); self.h0 = sha(self.f); self.s = self.e.start(self.f)
    def tearDown(self):
        for r, ds, fs in os.walk(self.e.dir):
            for d in ds: os.chmod(os.path.join(r, d), 0o755)
        self.e.close()

    @property
    def sg(self): return os.path.join(self.e.work, '.savegate')    # backups live next to the source

    def refused(self):
        c, r = self.s.post('/api/save', EDIT)
        if c == 200:       # fallback to the cache store is fine, but only with a real byte-identical backup
            b = r.get('backup'); self.assertTrue(b and os.path.isfile(b), 'saved without a backup: %s' % r); self.assertEqual(sha(b), self.h0); print('fallback backup', b); return
        self.assertEqual(sha(self.f), self.h0, 'source changed'); self.assertTrue(r.get('error')); print(c, r['error'][:150])
        self.assertTrue(clear(r['error']), r['error'])

    def test_backup_dir_readonly(self):
        os.makedirs(self.sg, exist_ok=True); os.chmod(self.sg, 0o555); self.refused()

    def test_backup_dir_is_a_file(self):
        shutil.rmtree(self.sg, ignore_errors=True); open(self.sg, 'w').write('x'); self.refused()

    def test_work_dir_readonly(self):
        os.chmod(self.e.work, 0o555); self.refused()

    def test_backup_dir_deleted_between_saves(self):
        c, r = self.s.post('/api/save', EDIT); self.assertEqual(c, 200, r); h1 = sha(self.f)
        shutil.rmtree(self.sg, ignore_errors=True)
        c, r = self.s.post('/api/save', EDIT); self.assertIn(c, (200, 409), r)
        self.assertTrue(valid_dwg(self.f))
        if c == 200: self.assertTrue(self.s.get('/api/backups')[1], 'saved but no backup exists')


if __name__ == '__main__': unittest.main()
