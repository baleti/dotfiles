#!/usr/bin/env python3
"""cadfacts.py: sqlite facts index of .rvt/.rfa/.rte/.rft and .dwg files (structured data, not full text).

  cadfacts.py build  --db DB --list FILE_OF_PATHS [--workers N] [--kind rvt|dwg]   incremental (path,size,mtime); failures go to files.status/errors
  cadfacts.py query  --db DB rvt|dwg ...                                              see `cadfacts.py query --help`
  cadfacts.py stats  --db DB

Runs on host1 (data and extractors live there). Extractors: ~/dwg-research/dwg2text.py --jsonl and ~/rvt-research/rvt2facts.py (both own code, no Autodesk/ODA/LibreDWG).
Design and numbers: ~/bin/index/README.md, section "CAD facts index"."""
import sys, os, re, json, sqlite3, subprocess, time, argparse
from concurrent.futures import ThreadPoolExecutor

HOME = os.path.expanduser('~')
DWG2TEXT = os.path.join(HOME, 'dwg-research', 'dwg2text.py')
RVT2FACTS = os.path.join(HOME, 'rvt-research', 'rvt2facts.py')
RVTPY = os.path.join(HOME, 'rvt-env', 'bin', 'python')
SCHEMA = """
CREATE TABLE IF NOT EXISTS files(id INTEGER PRIMARY KEY, kind TEXT, path TEXT UNIQUE, size INT, mtime INT, status TEXT, errors TEXT, seconds REAL, version TEXT, units INT, nent INT, at INT);
CREATE TABLE IF NOT EXISTS dwg_layers(fid INT, name TEXT);
CREATE TABLE IF NOT EXISTS dwg_blocks(fid INT, name TEXT);
CREATE TABLE IF NOT EXISTS dwg_layouts(fid INT, name TEXT, paper TEXT, w REAL, h REAL, viewports INT);
CREATE TABLE IF NOT EXISTS dwg_text(fid INT, kind TEXT, layer TEXT, block TEXT, text TEXT, x REAL, y REAL, tag TEXT, n INT);
CREATE TABLE IF NOT EXISTS dwg_xrefs(fid INT, path TEXT);
CREATE TABLE IF NOT EXISTS rvt_elems(fid INT, eid INT, class TEXT, category TEXT, family TEXT, type TEXT, level TEXT, mark TEXT, name TEXT);
CREATE TABLE IF NOT EXISTS rvt_nums(fid INT, eid INT, param TEXT, value REAL, unit TEXT);
CREATE TABLE IF NOT EXISTS rvt_strs(fid INT, eid INT, param TEXT, value TEXT);
CREATE TABLE IF NOT EXISTS rvt_levels(fid INT, name TEXT, elev_mm REAL);
"""
INDEXES = """
CREATE INDEX IF NOT EXISTS i_dl ON dwg_layers(name); CREATE INDEX IF NOT EXISTS i_dl2 ON dwg_layers(fid);
CREATE INDEX IF NOT EXISTS i_db ON dwg_blocks(name); CREATE INDEX IF NOT EXISTS i_db2 ON dwg_blocks(fid);
CREATE INDEX IF NOT EXISTS i_dt ON dwg_text(fid); CREATE INDEX IF NOT EXISTS i_dx ON dwg_xrefs(fid);
CREATE INDEX IF NOT EXISTS i_re ON rvt_elems(fid, eid); CREATE INDEX IF NOT EXISTS i_rec ON rvt_elems(category); CREATE INDEX IF NOT EXISTS i_ret ON rvt_elems(type);
CREATE INDEX IF NOT EXISTS i_rn ON rvt_nums(param, value); CREATE INDEX IF NOT EXISTS i_rn2 ON rvt_nums(fid, eid);
CREATE INDEX IF NOT EXISTS i_rs ON rvt_strs(fid, eid); CREATE INDEX IF NOT EXISTS i_rl ON rvt_levels(fid);
CREATE INDEX IF NOT EXISTS i_f ON files(kind, status);
"""
TABLES = ['dwg_layers', 'dwg_blocks', 'dwg_layouts', 'dwg_text', 'dwg_xrefs', 'rvt_elems', 'rvt_nums', 'rvt_strs', 'rvt_levels']


def kind_of(p):
    e = p.rsplit('.', 1)[-1].lower()
    return 'dwg' if e in ('dwg', 'dxf') else 'rvt' if e in ('rvt', 'rfa', 'rte', 'rft') else None


def extract(kind, path, timeout):
    """-> record dict (never raises)"""
    cmd = [sys.executable, DWG2TEXT, '--jsonl', path] if kind == 'dwg' else [RVTPY, RVT2FACTS, path]
    try:
        r = subprocess.run(['nice', '-n', '15'] + cmd, capture_output=True, timeout=timeout)
        line = r.stdout.decode('utf-8', 'replace').strip().splitlines()
        return json.loads(line[0]) if line else {'status': 'error', 'errors': ['no output rc=%d %s' % (r.returncode, r.stderr[-200:].decode('utf-8', 'replace'))]}
    except subprocess.TimeoutExpired:
        return {'status': 'error', 'errors': ['timeout %ds' % timeout]}
    except Exception as e:
        return {'status': 'error', 'errors': [repr(e)[:200]]}


def store(db, kind, path, st, d):
    fid = db.execute('SELECT id FROM files WHERE path=?', (path,)).fetchone()
    if fid:
        fid = fid[0]
        for t in TABLES: db.execute('DELETE FROM %s WHERE fid=?' % t, (fid,))
    errs = d.get('errors') or []
    hdr = d.get('header') or {}
    nent = sum((d.get('entity_counts') or {}).values()) if kind == 'dwg' else len(d.get('elems') or [])
    cur = db.execute('INSERT OR REPLACE INTO files(id,kind,path,size,mtime,status,errors,seconds,version,units,nent,at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',
                     (fid, kind, path, st.st_size, int(st.st_mtime), d.get('status', 'error'), json.dumps(errs, ensure_ascii=False)[:500] if errs else None, d.get('seconds'),
                      d.get('version') or d.get('year'), hdr.get('INSUNITS'), nent, int(time.time())))
    fid = cur.lastrowid
    if kind == 'dwg':
        db.executemany('INSERT INTO dwg_layers VALUES(?,?)', [(fid, s) for s in d.get('layers') or []])
        db.executemany('INSERT INTO dwg_blocks VALUES(?,?)', [(fid, s) for s in d.get('blocks') or []])
        db.executemany('INSERT INTO dwg_layouts VALUES(?,?,?,?,?,?)', [(fid, l.get('name'), l.get('paper'), (l.get('size_mm') or [0, 0])[0], (l.get('size_mm') or [0, 0])[1], l.get('viewports')) for l in d.get('layouts') or []])
        seen = {}
        for i in d.get('items') or []:                       # identical (kind, layer, block, text) repeats are stored once with a count; first position kept
            if not i.get('text'): continue
            k = (i.get('kind'), i.get('layer'), i.get('block'), i.get('text'), i.get('tag'))
            if k in seen: seen[k][8] += 1
            else: seen[k] = [fid, k[0], k[1], k[2], k[3], i.get('x'), i.get('y'), k[4], 1]
        db.executemany('INSERT INTO dwg_text VALUES(?,?,?,?,?,?,?,?,?)', list(seen.values()))
        xr = d.get('xrefs') or []
        db.executemany('INSERT INTO dwg_xrefs VALUES(?,?)', [(fid, x if isinstance(x, str) else json.dumps(x, ensure_ascii=False)) for x in xr])
    else:
        db.executemany('INSERT INTO rvt_elems VALUES(?,?,?,?,?,?,?,?,?)', [[fid] + e for e in d.get('elems') or []])
        db.executemany('INSERT INTO rvt_nums VALUES(?,?,?,?,?)', [[fid] + e for e in d.get('nums') or []])
        db.executemany('INSERT INTO rvt_strs VALUES(?,?,?,?)', [[fid] + e for e in d.get('strs') or []])
        db.executemany('INSERT INTO rvt_levels VALUES(?,?,?)', [[fid] + e for e in d.get('levels') or []])


def build(a):
    os.makedirs(os.path.dirname(os.path.abspath(a.db)), exist_ok=True)
    db = sqlite3.connect(a.db, timeout=60); db.executescript(SCHEMA); db.execute('PRAGMA journal_mode=WAL'); db.execute('PRAGMA synchronous=NORMAL')
    have = {p: (s, m) for p, s, m in db.execute('SELECT path,size,mtime FROM files')}
    todo = []
    for l in open(a.list, encoding='utf-8', errors='replace'):
        p = l.rstrip('\n')
        k = kind_of(p)
        if not k or (a.kind and k != a.kind): continue
        try: st = os.stat(p)
        except OSError: continue
        if have.get(p) == (st.st_size, int(st.st_mtime)): continue
        if a.max_mb and st.st_size > a.max_mb << 20: continue
        todo.append((k, p, st))
    if a.limit: todo = todo[:a.limit]
    print('to do: %d files (%d already current)' % (len(todo), len(have)), flush=True)
    t0 = time.time(); n = 0
    def work(x): return x, extract(x[0], x[1], a.timeout)
    with ThreadPoolExecutor(a.workers) as ex:
        for (k, p, st), d in ex.map(work, todo):
            store(db, k, p, st, d); n += 1
            if n % 50 == 0: db.commit(); print('%d/%d  %.0fs  %s' % (n, len(todo), time.time() - t0, d.get('status')), flush=True)
    db.commit(); print('done %d in %.0fs' % (n, time.time() - t0), flush=True)
    if a.indexes: db.executescript(INDEXES); db.commit()


def stats(a):
    db = sqlite3.connect(a.db)
    for r in db.execute('SELECT kind,status,count(*),sum(size)>>20,round(avg(seconds),2),round(max(seconds),1) FROM files GROUP BY 1,2'): print('files', r, '(kind,status,n,MB,avg s,max s)')
    for t in TABLES: print(t, db.execute('SELECT count(*) FROM %s' % t).fetchone()[0])
    print('db bytes', os.path.getsize(a.db))
    for r in db.execute('SELECT errors,count(*) FROM files WHERE status NOT IN ("ok") GROUP BY 1 ORDER BY 2 DESC LIMIT 8'): print('err', r)


# ---- queries -------------------------------------------------------------------------------------------------------------------------------
UNIT = {'mm': 1.0, 'cm': 10.0, 'm': 1000.0, 'in': 25.4, 'ft': 304.8}
COND = re.compile(r'^\s*(.+?)\s*(<=|>=|!=|=|<|>|~)\s*(-?[\d.]+)\s*(mm|cm|m|in|ft|m2|m3)?\s*$')


def cond_sql(c):
    """'Unconnected Height<2300mm' -> (sql, params) on rvt_nums alias n; 'Mark~A1' (text contains) -> rvt_strs alias s"""
    m = COND.match(c)
    if not m: raise SystemExit('bad condition: ' + c)
    p, op, v, u = m.groups(); v = float(v) * (UNIT.get(u, 1.0) if u else 1.0)
    return p, op, v


def q_rvt(db, a):
    w, par, j, jp = [], [], '', []
    if a.category: w.append('e.category LIKE ?'); par.append('%' + a.category + '%')
    if a.type: w.append('(e.type LIKE ? OR e.family LIKE ?)'); par += ['%' + a.type + '%'] * 2
    if a.level: w.append('e.level LIKE ?'); par.append('%' + a.level + '%')
    if a.path: w.append('f.path LIKE ?'); par.append('%' + a.path + '%')
    for i, c in enumerate(a.where or []):
        p, op, v = cond_sql(c)
        j += ' JOIN rvt_nums n%d ON n%d.fid=e.fid AND n%d.eid=e.eid AND n%d.param LIKE ? AND n%d.value %s ?' % (i, i, i, i, i, '=' if op == '~' else op)
        jp += ['%' + p + '%', v]
    sql = 'SELECT f.path,e.eid,e.category,e.family,e.type,e.level,e.name FROM rvt_elems e JOIN files f ON f.id=e.fid' + j + (' WHERE ' + ' AND '.join(w) if w else '') + ' LIMIT ' + str(a.limit)
    for r in db.execute(sql, jp + par): print('\t'.join(str(x) for x in r))


def q_dwg(db, a):
    w, par = [], []
    if a.layer: w.append('EXISTS(SELECT 1 FROM dwg_layers l WHERE l.fid=f.id AND l.name LIKE ?)'); par.append('%' + a.layer + '%')
    if a.block: w.append('EXISTS(SELECT 1 FROM dwg_blocks b WHERE b.fid=f.id AND b.name LIKE ?)'); par.append('%' + a.block + '%')
    if a.text: w.append('EXISTS(SELECT 1 FROM dwg_text t WHERE t.fid=f.id AND t.text LIKE ?)'); par.append('%' + a.text + '%')
    if a.path: w.append('f.path LIKE ?'); par.append('%' + a.path + '%')
    sql = 'SELECT f.path,f.version,f.units,f.nent FROM files f WHERE f.kind="dwg"' + ''.join(' AND ' + x for x in w) + ' LIMIT ' + str(a.limit)
    for r in db.execute(sql, par): print('\t'.join(str(x) for x in r))


def main():
    ap = argparse.ArgumentParser(); sp = ap.add_subparsers(dest='cmd', required=True)
    b = sp.add_parser('build'); b.add_argument('--db', required=True); b.add_argument('--list', required=True); b.add_argument('--kind'); b.add_argument('--workers', type=int, default=3)
    b.add_argument('--timeout', type=int, default=900); b.add_argument('--limit', type=int); b.add_argument('--max-mb', type=int); b.add_argument('--indexes', action='store_true')
    s = sp.add_parser('stats'); s.add_argument('--db', required=True)
    q = sp.add_parser('query'); q.add_argument('--db', required=True); qs = q.add_subparsers(dest='what', required=True)
    r = qs.add_parser('rvt'); r.add_argument('--category'); r.add_argument('--type'); r.add_argument('--level'); r.add_argument('--path'); r.add_argument('--where', action='append', help='"Unconnected Height<2300mm"'); r.add_argument('--limit', type=int, default=100)
    d = qs.add_parser('dwg'); d.add_argument('--layer'); d.add_argument('--block'); d.add_argument('--text'); d.add_argument('--path'); d.add_argument('--limit', type=int, default=100)
    a = ap.parse_args()
    if a.cmd == 'build': build(a)
    elif a.cmd == 'stats': stats(a)
    else:
        db = sqlite3.connect(a.db); (q_rvt if a.what == 'rvt' else q_dwg)(db, a)


if __name__ == '__main__':
    main()
