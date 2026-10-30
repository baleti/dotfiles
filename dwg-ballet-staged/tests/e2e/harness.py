"""End-to-end harness: a REAL dwg-ballet server process on a synthetic drawing, driven over HTTP.
Isolated config, backups, journal, savegate cache and gate file under one scratch dir (default ~/.sgtmp/c3x-e2e)."""
import os, sys, json, time, shutil, signal, hashlib, subprocess, urllib.request, urllib.error, socket
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, ROOT)
SCRATCH = os.environ.get('E2E_SCRATCH') or os.path.expanduser('~/.sgtmp/c3x-e2e')
TPL = os.environ.get('E2E_TEMPLATES') or os.path.expanduser('~/dwg-write/templates')


def sha(p): return hashlib.sha256(open(p, 'rb').read()).hexdigest()


def make_drawing(path, year='2018'):
    """synthetic drawing (layers, lines, block with insert, text) from the blank template"""
    import dwgdoc, wtest
    d = dwgdoc.Doc(open(os.path.join(TPL, 'blank_%s.dwg' % year), 'rb').read()); wtest.basic(d); wtest.more(d)
    open(path, 'wb').write(d.save()); return path


class Env:
    """one isolated world: dir with config/backups/gate; open(file) starts a server"""
    def __init__(self, name, overwrite=False, gate=True):
        self.dir = os.path.join(SCRATCH, name); shutil.rmtree(self.dir, ignore_errors=True); os.makedirs(self.dir)
        self.cfg = os.path.join(self.dir, 'config.json'); self.bak = os.path.join(self.dir, 'bak'); self.gatef = os.path.join(self.dir, 'gate.json')
        self.work = os.path.join(self.dir, 'work'); os.makedirs(self.work)
        if overwrite: json.dump({'allow_overwrite': True}, open(self.cfg, 'w'))
        if gate: json.dump({'dwg': {'*': 'open'}}, open(self.gatef, 'w'))
        self.env = dict(os.environ, DWG_BALLET_CONFIG=self.cfg, DWG_BALLET_BACKUPS=self.bak, SAVEGATE_GATE=self.gatef,
                        SAVEGATE_CACHE=os.path.join(self.dir, 'sgcache'), SAVEGATE_JOURNAL=os.path.join(self.dir, 'journal'),
                        XDG_CACHE_HOME=os.path.join(self.dir, 'xdgcache'), PYTHONDONTWRITEBYTECODE='1')
        self.procs = []

    def drawing(self, name='a.dwg', year='2018'): return make_drawing(os.path.join(self.work, name), year)

    def start(self, path, preexec=None):
        s = socket.socket(); s.bind(('127.0.0.1', 0)); port = s.getsockname()[1]; s.close()
        p = subprocess.Popen([sys.executable, '-m', 'dwgballet', path, '--port', str(port), '--no-browser'], cwd=ROOT, env=self.env, preexec_fn=preexec,
                             stdout=open(os.path.join(self.dir, 'srv%d.log' % port), 'w'), stderr=subprocess.STDOUT)
        srv = Server(p, port); self.procs.append(srv)
        for _ in range(300):
            try: srv.get('/api/meta'); return srv
            except Exception: time.sleep(0.2)
        raise RuntimeError('server did not start')

    def close(self):
        for s in self.procs: s.kill()


class Server:
    def __init__(self, proc, port): self.proc, self.port = proc, port

    def call(self, method, path, body=None, timeout=300):
        data = json.dumps(body).encode() if body is not None else None
        rq = urllib.request.Request('http://127.0.0.1:%d%s' % (self.port, path), data=data, method=method, headers={'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(rq, timeout=timeout) as r: return r.status, json.loads(r.read() or b'null')
        except urllib.error.HTTPError as e:
            raw = e.read()
            try: return e.code, json.loads(raw)
            except Exception: return e.code, {'raw': raw[:200].decode('latin1')}

    def get(self, path): return self.call('GET', path)
    def post(self, path, body=None): return self.call('POST', path, body if body is not None else {})
    def kill(self):
        if self.proc.poll() is None: self.proc.kill(); self.proc.wait()


def valid_dwg(path):
    """re-parse with our reader; True when it loads and has entities"""
    import dwgdoc
    d = dwgdoc.Doc(open(path, 'rb').read()); return len(list(d.layers())) > 0


def junk(dirpath):
    return [f for f in os.listdir(dirpath) if f.endswith(('.sgtmp', '-tmp', '.restore-tmp')) or '.savegate-lock' in f or f.startswith('.tmp')]
