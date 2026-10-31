"""Erasing the boundary object of an associative hatch must not leave the hatch pointing at a deleted object (AutoCAD AUDIT: 'AcDbHatch Boundary Undefined, Remove Associativity').
Found by the chained real-file save sweep (AUDIT after the 3rd save of a real AC1024 drawing)."""
import os, unittest
import dwgdoc

TPL = os.environ.get('E2E_TEMPLATES') or os.path.expanduser('~/dwg-write/templates')


class EraseAssocHatch(unittest.TestCase):
    def build(self):
        d = dwgdoc.Doc(open(os.path.join(TPL, 'blank_2018.dwg'), 'rb').read())
        ln = [d.add_line((0, 0), (10, 0)), d.add_line((10, 0), (10, 10)), d.add_line((10, 10), (0, 0))]
        h = d.add_hatch([[('L', (0, 0), (10, 0)), ('L', (10, 0), (10, 10)), ('L', (10, 10), (0, 0))]], pattern='SOLID')
        hd = d.get(h); hd['assoc'] = 1; hd['paths'][0]['boundary'] = list(ln); hd['paths'][0]['nboundary'] = 3; d.put(hd)
        return dwgdoc.Doc(d.save()), h, ln

    def test_erase_boundary_drops_associativity(self):
        d, h, ln = self.build()
        self.assertEqual(d.get(h)['paths'][0]['boundary'], ln)
        d.erase(ln[1]); e = dwgdoc.Doc(d.save()); hd = e.get(h)
        for p in hd['paths']: self.assertNotIn(ln[1], p.get('boundary', []), 'hatch still references the erased object')
        if hd.get('assoc'):
            for p in hd['paths']: self.assertEqual(p['nboundary'], len(p['boundary']))
        self.assertFalse(e.exists(ln[1]))

    def test_erase_unrelated_keeps_hatch_associative(self):
        d, h, ln = self.build(); other = d.add_line((50, 50), (60, 60)); d.erase(other); hd = dwgdoc.Doc(d.save()).get(h)
        self.assertEqual(hd['assoc'], 1); self.assertEqual(hd['paths'][0]['boundary'], ln)


if __name__ == '__main__': unittest.main()
