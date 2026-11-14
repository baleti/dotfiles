#!/usr/bin/env python3
"""Allow-list publisher: copies safe source files from working dirs into clean repos under ~/src/pub/<name>.
usage: publish.py [--scan-only] [name...]   (then commit/push is done by `git -C ~/src/pub/<name>`; see GITHUB.md)"""
import os, re, sys, shutil, subprocess, fnmatch
H = os.path.expanduser("~")
OK_EXT = {'.py','.rs','.toml','.lock','.sh','.js','.mjs','.html','.css','.md','.cfg','.ini','.cs','.ps1','.yml','.yaml'}
SKIP_DIRS = {'pipeline','oracle-out','campaign21','guest','dumps','out','cache','corpus','rosetta','scenes','xcache','samples','samples-rfa','_oda-quarantine','__pycache__','.git','.venv','.venv3','.claude','node_modules','target','files','generated','campaign','jobs','schema','exp','exp_out','exprdata','raw','raw2','raw3','streams','scratch','pout','dist','build','.pytest_cache','textures','data','logs','snap','.deps'}
SKIP_DIR_RE = re.compile(r'^(\.?venv|.*-venv|site-packages|\.cache|models|weights|gt|gtg|gt4|fid|fidfull|cov|pout|t2t|idstat|groundtruth|rosetta)')
SKIP_FILE_RE = re.compile(r'(REPLY-FROM|HANDOFF|HANDOVER|PROGRESS|NEEDS-FROM|^BRIEF|^pick\.py|chk_r12_corpus|^LOG|^STATUS|\.pre_|\.bak|~$)', re.I)
MAXSIZE = 400_000
BM3 = re.compile(r'bm3\w*', re.I)   # internal project code name: scrubbed from text and file names (audit 2026-10-24)
REPOS = {
 'rvt-reader': dict(src='rvt-research', top_only_dirs=['tests'], recurse=False),
 'rvt-writer': dict(src='rvt-research/write-lab', recurse=True),
 'rvt-ballet': dict(src='src/rvt-ballet', recurse=True),   # renamed from rvt-viewer; canonical tree = host2 src/rvt-viewer (rsync'd 2026-10-28)
 'rvt-sheets': dict(src='src/rvt-sheets', recurse=True),
 'rvt-core':   dict(src='src/rvt-core', recurse=True),
 'rvt-qa':     dict(src='src/rvt-qa', recurse=True),
 'dwg-reader': dict(src='dwg-research', recurse=True),
 'dwg-writer': dict(src='dwg-write', recurse=True),
 'dwg-ballet': dict(src='src/dwg-ballet', recurse=True),   # renamed from dwg-viewer; canonical tree = host2 ~/dwg-viewer (rsync'd 2026-10-28)
 'rvtplat':    dict(src='src/rvtplat', recurse=True),
 # added 2026-11-14 (c9x-pubreview): run on host2 (canonical trees) with PUB_OUT=<dir>
 'savegate':   dict(src='src/savegate', recurse=True),
 'rvt-extract':dict(src='src/rvt-extract', recurse=True),
 'skp-ballet': dict(src='src/skp-ballet', recurse=True, bin_ext={'.skp'}),
 '3dm-ballet': dict(src='src/3dm-ballet', recurse=True, bin_ext={'.3dm'}),
}
ALT_SRC = {'dwg-ballet': 'dwg-ballet'}   # host2 location of the dwg-ballet worktree
NAMES_OK = {'LICENSE', 'LICENSES', 'NOTICE', 'LICENSE-OpenSKP.txt'}
# infra scrub (substitute, never drop: keeps code valid)
INFRA_SUB = [(re.compile(r'/home/user1?/'), '~/'), (re.compile(r'/home/user1?\b'), '~'), (re.compile(r'\bhost[123]\b', re.I), 'remote-host'), (re.compile(r'\bai1\b'), 'gpu-host'), (re.compile(r'baleti3266@gmail\.com'), 'baleti@users.noreply.github.com')]
LINE_DROP2 = re.compile(r'(KSR|Queenwood|ksra|wireguard|rclone|\bVPN\b|/mnt/host1|ssh -|10\.(?:10|176|0)\.\d+\.\d+)', re.I)
LINE_DROP = re.compile(r'(HWO|Chetwoods|BimRv|wine|run_oda|parse_oda|_oda|oda_|WinDev2407Eval|192\.168\.|/\.ssh/|recoll)', re.I)
FORBID = re.compile(r'(KSR|Queenwood|ksra|25066|\bhost[123]\b|/home/user1?\b|HWO|Chetwoods|bm3|backups/office|hwo-project|rabat|montgomery|coronation|monier|sherwood|/mnt/host1|gho_[A-Za-z0-9]{10}|ghp_[A-Za-z0-9]{10}|BEGIN [A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{12}|dan94kra|@gmail\.com|password\s*[=:]\s*\S+|Teigha|OpenDesign|/home/user1/\.ssh|WinDev2407Eval|192\.168\.)', re.I)

import subprocess as _sp
def user_sets(dst):
    """files touched or deleted by commits that are NOT ours (ours: subject starts with 'sync' or 'Initial import')"""
    owned, deleted = set(), set()
    if not os.path.isdir(os.path.join(dst, '.git')): return owned, deleted
    out = _sp.run(['git', '-C', dst, 'log', '--name-status', '--format=@@%s'], capture_output=True, text=True).stdout
    mine = True
    for line in out.splitlines():
        if line.startswith('@@'):
            subj = line[2:]; mine = subj.startswith('sync') or subj.startswith('Initial import'); continue
        if mine or not line.strip(): continue
        parts = line.split('\t')
        st, paths = parts[0], parts[1:]
        for p in paths:
            if st.startswith('D'): deleted.add(p)
            else: owned.add(p)
    deleted -= {p for p in deleted if os.path.exists(os.path.join(dst, p))}
    return owned, deleted

BIN_EXT = {}
def walk(root, recurse):
    for dp, dn, fn in os.walk(root):
        rel = os.path.relpath(dp, root)
        dn[:] = [d for d in dn if (d not in SKIP_DIRS or (d == 'data' and rel.split(os.sep)[0] == 'tests')) and not SKIP_DIR_RE.match(d) and not (not recurse and rel=='.' and d!='tests')]
        for f in fn:
            p = os.path.join(dp, f)
            if os.path.islink(p): continue
            ext = os.path.splitext(f)[1].lower()
            if f in NAMES_OK: yield ('OK', p); continue
            if ext in BIN_EXT.get('cur', set()) and 'tests' in rel.split(os.sep) and os.path.getsize(p) <= 200_000: yield ('BIN', p); continue
            if ext not in OK_EXT or SKIP_FILE_RE.search(f): continue
            if os.path.getsize(p) > MAXSIZE and '/web/vendor/' not in p: yield ('BIG', p); continue
            yield ('OK', p)
def main():
    scan = '--scan-only' in sys.argv
    names = [a for a in sys.argv[1:] if not a.startswith('--')] or list(REPOS)
    for n in names:
        c = REPOS[n]; root = os.path.join(H, c['src'])
        if not os.path.isdir(root) and n in ALT_SRC: root = os.path.join(H, ALT_SRC[n])
        BIN_EXT['cur'] = c.get('bin_ext', set())
        if not os.path.isdir(root): print(n, 'missing src'); continue
        dst = os.path.join(os.environ.get('PUB_OUT') or os.path.join(H, 'src/pub'), n); os.makedirs(dst, exist_ok=True)
        files, hits, big = [], [], []
        for kind, p in walk(root, c['recurse']):
            if kind == 'BIG': big.append(p); continue
            if kind == 'BIN':
                b = open(p, 'rb').read()
                m = FORBID.search(b.decode('latin-1'))
                if m: hits.append((p, m.group(0))); continue
                files.append((p, b)); continue
            try: t = open(p, errors='replace').read()
            except Exception: continue
            if '/web/vendor/' not in p:
                t = BM3.sub('corpus', t)
                t = ''.join(l for l in t.splitlines(True) if not LINE_DROP.search(l) and not LINE_DROP2.search(l))
                for rx, rep in INFRA_SUB: t = rx.sub(rep, t)
            m = FORBID.search(t) if '/web/vendor/' not in p else None
            if m: hits.append((p, m.group(0))); continue
            files.append((p, t))
        print(f'{n}: {len(files)} files, {sum(len(t) for _,t in files)//1024} KB, {len(hits)} withheld(forbidden pattern), {len(big)} withheld(big)')
        for p,m in hits: print('   WITHHELD', os.path.relpath(p,root), '<-', m)
        for p in big: print('   BIG', os.path.relpath(p,root))
        if scan: continue
        owned, udel = user_sets(dst)
        keep = set()
        for p, t in files:
            r = BM3.sub('corpus', os.path.relpath(p, root))
            if r == 'README.md': r = 'README-orig.md'
            keep.add(r)
            if r in owned or r in udel: continue
            o = os.path.join(dst, r); os.makedirs(os.path.dirname(o), exist_ok=True)
            open(o, 'wb' if isinstance(t, bytes) else 'w').write(t); shutil.copymode(p, o)
        for dp, dn, fn in os.walk(dst):
            dn[:] = [d for d in dn if d != '.git']
            for f in fn:
                r = os.path.relpath(os.path.join(dp, f), dst)
                if r not in keep and r not in ('README.md', '.gitignore') and not r.startswith('.git/') and r not in owned and (os.path.splitext(r)[1].lower() in OK_EXT or os.path.splitext(r)[1].lower() in c.get('bin_ext', set())): os.remove(os.path.join(dp, f))
main()
