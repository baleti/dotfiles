#!/usr/bin/env python3
"""Synthetic regression: 2 cats, 2 items, 2 years. Checks headline, any-year line, aliasing, malformed-row skipping."""
import os, json, subprocess, tempfile, re, sys
here = os.path.dirname(os.path.abspath(__file__))
t = tempfile.mkdtemp()
os.makedirs(t + '/demo-state/rvt-edit'); os.makedirs(t + '/share/pixel6')
json.dump({'years': [2024, 2025], 'categories': [{'name': 'A', 'items': ['x', 'y']}, {'name': 'B', 'items': ['z']}]}, open(t + '/demo-state/rvt-edit/matrix.json', 'w'))
rows = [{'cat': 'A', 'item': 'x', 'result': 'PASS', 'years': [2024], 'date': '1'},
        {'cat': 'A', 'item': 'y', 'result': 'FAIL', 'date': '2'},
        {'cat': 'B', 'item': 'z', 'result': 'PASS', 'date': '3'},
        {'cat': '', 'item': '', 'result': '', 'date': '4'},
        {'cat': 'A / x', 'item': 'PASS', 'date': '5'}]
open(t + '/demo-state/rvt-edit/ledger.jsonl', 'w').write('\n'.join(json.dumps(r) for r in rows) + '\n')
subprocess.run([sys.executable, here + '/gen_dashboard.py'], env={'HOME': t, 'RVT_DASH_NO_SSH': '1', 'PATH': os.environ['PATH']}, check=True)
h = open(t + '/share/pixel6/rvt-edit-dashboard.html').read()
# cells: 6 total; PASS = x@2024 + z@2024 + z@2025 = 3 -> 50%; FAIL = y x2 = 2
assert '3 of 6 checks pass, 2 fail, 1 untested' in h, re.findall(r'\d+ of \d+ checks[^<]*', h)
assert '<b>2 of 3 (67%)' in h, re.findall(r'Items passing[^<]*<b>[^<]*', h)
assert 'big">50%' in h
print('ok')
