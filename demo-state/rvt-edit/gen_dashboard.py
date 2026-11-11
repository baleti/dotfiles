#!/usr/bin/env python3
"""No-LLM: build the RVT editing dashboard from matrix.json + ledger.jsonl (+progress log). Output: ~/share/pixel6/rvt-edit-dashboard.html"""
import json, os, re, time, html
H = os.path.expanduser('~'); D = H + '/demo-state'
M = json.load(open(D + '/rvt-edit/matrix.json'))
YEARS = M['years']
led = {}  # (cat,item,year) -> (result,date,note,agent)
recent = []
lp = D + '/rvt-edit/ledger.jsonl'
import subprocess
age = {'host3': int(time.time() - os.path.getmtime(lp)) if os.path.exists(lp) else None}
lines = open(lp).read().splitlines() if os.path.exists(lp) else []
for h in (() if os.environ.get('RVT_DASH_NO_SSH') else ('host2', 'host1')):
    try:
        _o = subprocess.run(['ssh', '-n', '-o', 'ConnectTimeout=8', h, 'stat -c %Y ~/demo-state/rvt-edit/ledger.jsonl; cat ~/demo-state/rvt-edit/ledger.jsonl'], capture_output=True, text=True, timeout=25).stdout.splitlines()
        age[h] = int(time.time() - int(_o[0])); lines += _o[1:]
    except Exception: age[h] = None
rows = []
for ln in lines:
    try: rows.append(json.loads(ln))
    except Exception: pass
ALIAS = {'Move column (FamilyInstance)': 'column', 'Rotate column (FamilyInstance)': 'column', 'Delete column (FamilyInstance)': 'column',
         'Rotate wall': 'wall', 'Resize wall length (end point)': 'wall', 'Rotate beam': 'beam', 'rotate family instance': 'family instance',
         'create new family 2020': 'create new family', 'wall on Revit-saved file': 'wall',
         'wall on Revit-saved file (in-place member layout, RVTGEN_INPLACE)': 'wall',
         'in-place SAVE! viewport move (backup, restore)': 'backup + rollback verified',
         'kill during restore leaves original or saved state': 'kill -9 mid-save leaves no partial file'}
_cats = {c['name'] for c in M['categories']}
def _y(r, t):
    if not r.get('years'):
        ys = [y for y in (2024, 2026) if str(y) in t]
        if ys: r['years'] = ys
def _fix(r):
    c, i = r.get('cat', ''), r.get('item', '')
    if not c: return None
    # shifted-argument rows: (cat 'N. X / detail', item PASS|FAIL, result=note) and (cat = item name, item = note, result PASS|FAIL)
    if ' / ' in c and i in ('PASS', 'FAIL') and c.split(' / ')[0] in {x['name'] for x in M['categories']}:
        r['cat'], r['item'], r['note'], r['result'] = c.split(' / ')[0], 'wall' if 'wall' in c else i, r.get('result', ''), i
        _y(r, c + ' ' + r.get('note', ''))
        return r if r['item'] in dict((x['name'], x['items']) for x in M['categories'])[r['cat']] else None
    if c in ('yes/no parameter', 'string parameter') and r.get('result') in ('PASS', 'FAIL'):
        r['cat'], r['item'], r['note'] = '4. Types and parameters', c, i
        _y(r, i)
        return r
    if c == '5.Families': r['cat'] = '5. Families'
    if c == '1. Move / text note': r['cat'] = '1. Move / rotate / resize'
    if c == '1. Move / viewport': r['cat'] = '1. Move / rotate / resize'
    r['item'] = ALIAS.get(i, i)
    return r if r['cat'] in _cats else None
skipped = [r for r in rows if _fix(dict(r)) is None]
rows = [x for x in (_fix(r) for r in rows) if x]
rows.sort(key=lambda r: r.get('date', ''))
if True:
    for r in rows:
        yrs = r.get('years') or ([r['year']] if r.get('year') else YEARS)
        for y in yrs:
            led[(r['cat'], r['item'], int(y))] = (r['result'], r.get('date', ''), r.get('note', ''), r.get('agent', ''))
        recent.append(r)
def cell(c, i, y):
    return led.get((c, i, y))
cats = []
tot = ok = bad = 0
for c in M['categories']:
    n = len(c['items']) * len(YEARS)
    p = sum(1 for i in c['items'] for y in YEARS if (cell(c['name'], i, y) or ('',))[0] == 'PASS')
    f = sum(1 for i in c['items'] for y in YEARS if (cell(c['name'], i, y) or ('',))[0] == 'FAIL')
    cats.append((c, n, p, f)); tot += n; ok += p; bad += f
def pct(a, b): return 0 if not b else round(100 * a / b)
usage = ''
try:
    st = json.load(open(H + '/.cache/claude-usage/state.json'))
    usage = ' '.join('%s %s/%s' % (a['account'], a.get('session_pct'), a.get('weekly_pct')) for a in st['accounts'])
except Exception: pass
prog = []
pp = D + '/c3x-progress.md'
if os.path.exists(pp):
    for ln in open(pp, errors='replace'):
        if 'RVT-EDIT' in ln or re.search(r'rung \d', ln, re.I): prog.append(ln.strip()[:300])
prog = prog[-12:][::-1]
e = html.escape
out = []
out.append('''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>RVT editing progress</title><style>
:root{--bg:#fff;--fg:#1c1b1f;--mut:#625f66;--line:#d9d6dd;--ok:#1e8e3e;--okb:#d7f0de;--bad:#c5221f;--badb:#fad7d5;--na:#f1eff4;--acc:#4a4ae0}
@media (prefers-color-scheme:dark){:root{--bg:#141317;--fg:#e8e6ec;--mut:#a29fa8;--line:#34323a;--ok:#6fd58a;--okb:#1e3a29;--bad:#ff8a84;--badb:#4a2220;--na:#201f25;--acc:#9c9cff}}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.45 system-ui,sans-serif;padding:16px;max-width:1100px;margin-inline:auto}
h1{font-size:22px;margin:0 0 4px}h2{font-size:17px;margin:26px 0 8px}.mut{color:var(--mut);font-size:13px}
.big{font-size:40px;font-weight:700}.bar{height:10px;background:var(--na);border-radius:5px;overflow:hidden;display:flex}.bar i{display:block;height:100%}
.g{background:var(--ok)}.r{background:var(--bad)}table{border-collapse:collapse;width:100%;font-size:13px}th,td{border-bottom:1px solid var(--line);padding:4px 6px;text-align:center}
td:first-child,th:first-child{text-align:left}td.p{background:var(--okb);color:var(--ok)}td.f{background:var(--badb);color:var(--bad)}td.n{color:var(--mut)}
.cat{margin:14px 0}.row{display:flex;gap:10px;align-items:center}.row b{min-width:60px}ul{padding-left:18px;margin:6px 0}li{margin:3px 0}
details{border:1px solid var(--line);border-radius:8px;padding:6px 10px;margin:8px 0}summary{cursor:pointer;font-weight:600}
</style></head><body>''')
out.append('<h1>Editing .rvt files: progress to 100%%</h1><div class="mut">Updated %s UTC. A cell is PASS only when a test in the Revit VM opened the saved file cleanly and the readback matched. Anything untested counts as not done.</div>' % time.strftime('%Y-%m-%d %H:%M', time.gmtime()))
out.append('<div class="row" style="margin-top:12px"><div class="big">%d%%</div><div style="flex:1"><div class="bar"><i class="g" style="width:%d%%"></i><i class="r" style="width:%d%%"></i></div><div class="mut">%d of %d checks pass, %d fail, %d untested (%d items x %d Revit years)</div></div></div>' % (pct(ok, tot), pct(ok, tot), pct(bad, tot), ok, tot, bad, tot - ok - bad, tot // len(YEARS), len(YEARS)))
anyp = sum(1 for c in M['categories'] for i in c['items'] if any((cell(c['name'], i, y) or ('',))[0] == 'PASS' for y in YEARS))
nit = sum(len(c['items']) for c in M['categories'])
peryr = ', '.join('%d: %d%%' % (y, pct(sum(1 for c in M['categories'] for i in c['items'] if (cell(c['name'], i, y) or ('',))[0] == 'PASS'), nit)) for y in YEARS)
out.append('<div class="mut" style="margin:6px 0">Items passing in at least one Revit year: <b>%d of %d (%d%%)</b>. Per year: %s. The headline above counts item x year cells, so a test on one year only moves it by 1/%d of an item.</div>' % (anyp, nit, pct(anyp, nit), peryr, len(YEARS)))
def _a(v): return 'unreachable' if v is None else ('%dh' % (v // 3600) if v >= 3600 else '%dm' % (v // 60)) + ' ago'
out.append('<div class="mut">Last ledger write: %s. %s</div>' % (', '.join('%s %s' % (h, _a(v)) for h, v in age.items()), 'WARNING: a ledger is unreachable, numbers may be low.' if any(v is None for v in age.values()) else ''))
out.append('<h2>By area</h2>')
for c, n, p, f in cats:
    out.append('<div class="cat"><div class="row"><b>%d%%</b><div style="flex:1"><div>%s</div><div class="bar"><i class="g" style="width:%d%%"></i><i class="r" style="width:%d%%"></i></div></div><span class="mut">%d/%d</span></div></div>' % (pct(p, n), e(c['name']), pct(p, n), pct(f, n), p, n))
out.append('<h2>Whats left (grouped by area)</h2>')
for c, n, p, f in cats:
    todo = [i for i in c['items'] if not all((cell(c['name'], i, y) or ('',))[0] == 'PASS' for y in YEARS)]
    out.append('<details%s><summary>%s: %d items not fully done</summary><table><tr><th>item</th>%s</tr>' % (' open' if todo and len(todo) < len(c['items']) else '', e(c['name']), len(todo), ''.join('<th>%d</th>' % y for y in YEARS)))
    for i in c['items']:
        row = ''
        for y in YEARS:
            r = cell(c['name'], i, y)
            if not r: row += '<td class="n" title="untested">-</td>'
            elif r[0] == 'PASS': row += '<td class="p" title="%s">PASS</td>' % e(r[1] + ' ' + r[3] + ' ' + r[2])
            else: row += '<td class="f" title="%s">FAIL</td>' % e(r[1] + ' ' + r[3] + ' ' + r[2])
        out.append('<tr><td>%s</td>%s</tr>' % (e(i), row))
    out.append('</table></details>')
out.append('<h2>Latest results</h2><ul>')
for r in recent[-12:][::-1]:
    out.append('<li><b>%s</b> %s / %s: %s <span class="mut">%s %s</span></li>' % (e(r.get('result', '')), e(r.get('cat', '')), e(r.get('item', '')), e(r.get('note', ''))[:200], e(r.get('date', '')), e(r.get('agent', ''))))
if not recent: out.append('<li class="mut">No results recorded yet. Agents record each test with ~/demo-state/bin/rvt-edit-record.</li>')
out.append('</ul><h2>Skipped ledger rows (%d, malformed, not counted)</h2><ul>' % len(skipped))
for r in skipped[-10:][::-1]: out.append('<li class="mut">%s %s | %s | %s</li>' % (e(r.get('date', '')), e(str(r.get('cat', '')))[:60], e(str(r.get('item', '')))[:60], e(r.get('agent', ''))))
out.append('</ul><h2>Agent progress notes (rungs)</h2><ul>')
for l in prog: out.append('<li class="mut">%s</li>' % e(l))
if not prog: out.append('<li class="mut">none yet</li>')
out.append('</ul><div class="mut" style="margin-top:20px">Account usage (session/weekly %%): %s</div></body></html>' % e(usage))
dst = H + '/share/pixel6/rvt-edit-dashboard.html'
tmp = dst + '.tmp'
open(tmp, 'w').write('\n'.join(out)); os.replace(tmp, dst)
