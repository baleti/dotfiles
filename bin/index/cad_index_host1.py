#!/usr/bin/env python3
"""Runs ON HOST1: refreshes the CAD indexes for the designated roots (incremental).
  1. facts DB   ~/.cache/indexes/cadfacts/facts.db   (cadfacts.py: Revit elements/params in mm, DWG layers/blocks/text; errors kept in files.status)
  2. Recoll     ~/.cache/indexes/{revit,dwg}/recoll   (plain /fts text; filters rvt2recoll.py / dwg2recoll.py; paths /home/user1/backups/... are valid on host3 too via symlink)
Guards: aborts when MemAvailable < 4 GB, or when qemu-ai1 restarts DURING the run (the old absolute NRestarts>5 HALT file kept the nightly job dead for days).
usage: cad_index_host1.py [--kinds facts,revit,dwg] [--roots a,b] [--limit N]; start it under systemd-run with MemoryMax / CPUQuota / Nice."""
import os, sys, subprocess, time, argparse

HOME = os.path.expanduser('~')
IDX = os.path.join(HOME, '.cache', 'indexes')
ROOTS = ['/home/user1/backups/office/bm3', '/home/user1/backups/office/hwo']      # = collections.json roots that live on host1
EXT = {'revit': ('rvt', 'rfa', 'rte', 'rft'), 'dwg': ('dwg', 'dxf')}


def sh(*c, **k): return subprocess.run(c, capture_output=True, text=True, **k).stdout


def restarts():
    try: return int(sh('systemctl', '--user', 'show', 'qemu-ai1', '-p', 'NRestarts').split('=')[1])
    except Exception: return 0


def memavail_gb():
    for l in open('/proc/meminfo'):
        if l.startswith('MemAvailable'): return int(l.split()[1]) / 2**20


def log(m): print(time.strftime('%T'), m, flush=True)


def lst(kind, roots):
    pat = []
    for e in EXT[kind]: pat += ['-o', '-iname', '*.' + e]
    out = sh('find', *roots, '-type', 'f', '(', *pat[1:], ')')
    return sorted(set(l for l in out.splitlines() if l))


def write_conf(kind, roots):
    d = os.path.join(IDX, kind, 'recoll'); os.makedirs(d, exist_ok=True)
    flt = 'rvt2recoll.py' if kind == 'revit' else 'dwg2recoll.py'
    base = os.path.join(HOME, 'rvt-research' if kind == 'revit' else 'dwg-research')
    open(os.path.join(d, 'recoll.conf'), 'w').write('topdirs = ' + ' '.join('"%s"' % r for r in roots) + '\nonlyNames = ' + ' '.join('*.' + e for e in EXT[kind]) +
                                                    '\nfilterMaxSeconds = 1200\nindexStripChars = 1\n')
    mt = 'application/x-revit-project' if kind == 'revit' else 'application/x-dwg-drawing'
    open(os.path.join(d, 'mimemap'), 'w').write(''.join('.%s = %s\n' % (e, mt) for e in EXT[kind]))
    open(os.path.join(d, 'mimeconf'), 'w').write('[index]\n%s = exec %s ; mimetype = text/html\n' % (mt, os.path.join(base, flt)))
    return d


def main():
    ap = argparse.ArgumentParser(); ap.add_argument('--kinds', default='facts,revit,dwg'); ap.add_argument('--roots', default=','.join(ROOTS)); ap.add_argument('--limit', type=int, default=0)
    a = ap.parse_args(); roots = a.roots.split(','); kinds = a.kinds.split(',')
    if memavail_gb() < 4: log('MemAvailable %.1f GB < 4, not starting' % memavail_gb()); sys.exit(75)
    base = restarts(); log('qemu-ai1 NRestarts baseline %d' % base)
    here = os.path.dirname(os.path.abspath(__file__))
    if 'facts' in kinds:
        allf = lst('revit', roots) + lst('dwg', roots)
        if a.limit: allf = allf[:a.limit]
        lf = os.path.join(IDX, 'cadfacts', 'files.lst'); os.makedirs(os.path.dirname(lf), exist_ok=True); open(lf, 'w').write('\n'.join(allf) + '\n')
        for k, w in (('dwg', 3), ('rvt', 2)):
            log('facts %s (%d files listed)' % (k, len(allf)))
            r = subprocess.run([sys.executable, os.path.join(here, 'cadfacts.py'), 'build', '--db', os.path.join(IDX, 'cadfacts', 'facts.db'), '--list', lf, '--kind', k, '--workers', str(w), '--indexes'])
            if restarts() > base: log('qemu-ai1 restarted during the run, stopping'); sys.exit(1)
    for k in ('revit', 'dwg'):
        if k not in kinds: continue
        d = write_conf(k, roots); log('recollindex %s' % k)
        subprocess.run(['recollindex', '-c', d])
        if restarts() > base: log('qemu-ai1 restarted during the run, stopping'); sys.exit(1)
    log('done')


main()
