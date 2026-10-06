#!/usr/bin/env python3
"""CLIP ViT-B/32 image-embedding worker on ai1 (ONNX, CUDA). Reads a tar stream
of images on stdin, writes one JSON line per image: {"name", "emb": [512 floats]}.
Same GPU-sharing contract as worker.py: registers as 'clip-vision' on slot
'gpu1' of the arbiter, evicts on POST :8201/evict, idle-gated on TTS log."""
import json, os, sys, tarfile, threading, time, urllib.request, gc
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import cv2, numpy as np

ARBITER = "http://127.0.0.1:8101"
SLOT, MODEL = "gpu1", "clip-vision"
# CLIP runs on cuda:0 WITHOUT the arbiter: sharing gpu1 with the face worker
# made the two evict each other every batch (thrash). cuda:0 holds only the
# small primary chatterbox; CLIP vision needs ~0.5 GB.
DEVICE_ID = int(os.environ.get("CLIP_DEVICE", "0"))
EVICT_PORT = 8201
EVICT_URL = f"http://127.0.0.1:{EVICT_PORT}/evict"
TTS_LOG = os.path.expanduser("~/tts-stt-server/server.log")
IDLE_SECS = int(os.environ.get("IDLE_SECS", "120"))
BATCH = int(os.environ.get("BATCH", "32"))
MODEL_PATH = os.path.expanduser("~/indexer/clip/vision_model.onnx")
MEAN = np.array([0.48145466, 0.4578275, 0.40821073], np.float32)
STD = np.array([0.26862954, 0.26130258, 0.27577711], np.float32)

lock = threading.RLock()
sess = None

def log(m): print(f"{time.strftime('%T')} {m}", file=sys.stderr, flush=True)

def post(path, body):
    req = urllib.request.Request(ARBITER + path, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r: return json.loads(r.read())

def load():
    global sess
    import onnxruntime as ort
    sess = ort.InferenceSession(MODEL_PATH, providers=[("CUDAExecutionProvider", {"device_id": DEVICE_ID}), "CPUExecutionProvider"])
    log(f"clip vision loaded: {sess.get_providers()}")

def unload():
    global sess
    sess = None; gc.collect(); log("clip vision unloaded (evicted)")

class Evict(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        with lock: unload()
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"ok": true}')

def preprocess(img):
    h, w = img.shape[:2]; s = 224 / min(h, w)
    img = cv2.resize(img, (max(224, round(w * s)), max(224, round(h * s))), interpolation=cv2.INTER_CUBIC)
    h, w = img.shape[:2]; y, x = (h - 224) // 2, (w - 224) // 2
    img = img[y:y + 224, x:x + 224][:, :, ::-1].astype(np.float32) / 255.0   # BGR->RGB
    return ((img - MEAN) / STD).transpose(2, 0, 1)

def idle_wait():
    while True:
        try: age = time.time() - os.path.getmtime(TTS_LOG)
        except OSError: return
        if age >= IDLE_SECS: return
        time.sleep(min(30, IDLE_SECS - age + 1))

def run(batch, out):
    idle_wait()
    try:
        with lock:
            if sess is None: load()
            imgs, names = [], []
            for name, data in batch:
                im = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR) if data else None
                if im is None:
                    out.write(json.dumps({"name": name, "error": "undecodable"}) + "\n"); continue
                imgs.append(preprocess(im)); names.append(name)
            if imgs:
                embs = sess.run(None, {sess.get_inputs()[0].name: np.stack(imgs).astype(np.float32)})[0]
                embs = embs / np.linalg.norm(embs, axis=1, keepdims=True)
                for n, e in zip(names, embs):
                    out.write(json.dumps({"name": n, "emb": [round(float(v), 6) for v in e]}) + "\n")
            out.flush()
    finally:
        pass

def main():
    threading.Thread(target=ThreadingHTTPServer(("127.0.0.1", EVICT_PORT), Evict).serve_forever, daemon=True).start()
    log(f"clip-vision on cuda:{DEVICE_ID} (no arbiter slot)")
    tar = tarfile.open(fileobj=sys.stdin.buffer, mode="r|")
    batch = []
    for m in tar:
        if not m.isfile(): continue
        batch.append((m.name, tar.extractfile(m).read()))
        if len(batch) >= BATCH:
            run(batch, sys.stdout); batch = []
    if batch: run(batch, sys.stdout)
    log("done")

if __name__ == "__main__":
    main()
