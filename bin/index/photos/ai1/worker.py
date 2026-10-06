#!/usr/bin/env python3
"""Face-embedding worker on ai1. Reads a tar stream of images on stdin,
writes one JSON line per image to stdout (faces + 512-d ArcFace embeddings).

GPU sharing: registers as participant 'insightface' on slot 'gpu1' of the
gpu-model-manager arbiter (127.0.0.1:8101). Acquires the slot per batch,
releases after. Serves POST /evict on 127.0.0.1:8200 so the arbiter can take
the card back (e.g. TTS needs chatterbox-b); eviction waits for the in-flight
batch to finish, then unloads the model.
Batches only start when the TTS/STT server has been quiet for IDLE_SECS.
"""
import contextlib, gc, io, json, os, sys, tarfile, threading, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import cv2, numpy as np

ARBITER = "http://127.0.0.1:8101"
SLOT, MODEL = "gpu1", "insightface"
EVICT_PORT = 8200
EVICT_URL = f"http://127.0.0.1:{EVICT_PORT}/evict"
TTS_LOG = os.path.expanduser("~/tts-stt-server/server.log")
IDLE_SECS = int(os.environ.get("IDLE_SECS", "120"))
BATCH = int(os.environ.get("BATCH", "32"))
DEVICE_ID = int(os.environ.get("CUDA_DEVICE", "1"))

lock = threading.RLock()        # held while a batch runs and while evicting
app = None                      # insightface FaceAnalysis when loaded

def post(path, body):
    req = urllib.request.Request(ARBITER + path, data=json.dumps(body).encode(),
                                 method="POST", headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read())

def load_model():
    global app
    from insightface.app import FaceAnalysis
    providers = [("CUDAExecutionProvider", {"device_id": DEVICE_ID}), "CPUExecutionProvider"]
    with contextlib.redirect_stdout(sys.stderr):   # keep stdout pure JSON
        app = FaceAnalysis(name="buffalo_l", providers=providers)
        app.prepare(ctx_id=0, det_size=(640, 640))
    log(f"model loaded, providers={app.models['detection'].session.get_providers()}")

def unload_model():
    global app
    app = None
    gc.collect()
    log("model unloaded (evicted)")

class EvictHandler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        if self.path != "/evict":
            self.send_response(404); self.end_headers(); return
        with lock:                      # blocks until any in-flight batch finishes
            unload_model()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(b'{"ok": true}')

def idle_wait():
    while True:
        try:
            age = time.time() - os.path.getmtime(TTS_LOG)
        except OSError:
            return
        if age >= IDLE_SECS:
            return
        time.sleep(min(30, IDLE_SECS - age + 1))

def log(msg):
    print(f"{time.strftime('%T')} {msg}", file=sys.stderr, flush=True)

def process(members):
    out = []
    for name, data in members:
        img = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR) if data else None
        if img is None:
            out.append({"name": name, "error": "undecodable"}); continue
        faces = app.get(img)
        out.append({"name": name, "faces": [
            {"bbox": [round(float(v), 1) for v in f.bbox],
             "score": round(float(f.det_score), 4),
             "emb": [round(float(v), 6) for v in f.normed_embedding]}
            for f in faces]})
    return out

def main():
    threading.Thread(target=ThreadingHTTPServer(("127.0.0.1", EVICT_PORT), EvictHandler).serve_forever,
                     daemon=True).start()
    post("/register", {"slot": SLOT, "model": MODEL, "evict_url": EVICT_URL})
    log(f"registered {MODEL} on {SLOT}; evict on :{EVICT_PORT}")
    tar = tarfile.open(fileobj=sys.stdin.buffer, mode="r|")
    batch = []
    def run(batch):
        idle_wait()
        post("/acquire", {"slot": SLOT, "model": MODEL})
        try:
            with lock:
                if app is None:
                    load_model()
                for rec in process(batch):
                    print(json.dumps(rec), flush=True)
        finally:
            post("/release", {"slot": SLOT, "model": MODEL})
    for m in tar:
        if not m.isfile():
            continue
        batch.append((m.name, tar.extractfile(m).read()))
        if len(batch) >= BATCH:
            run(batch); batch = []
    if batch:
        run(batch)
    log("done")

if __name__ == "__main__":
    main()
