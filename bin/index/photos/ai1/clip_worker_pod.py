#!/usr/bin/env python3
"""CLIP ViT-B/32 image-embedding worker for the host1 podman setup (replaces clip_worker.py of the old ai1 VM).

Reads a tar stream of images on stdin, writes one JSON line per image to stdout: {"name", "emb": [512 floats]} or
{"name", "error"}. Runs as a throw-away container (clip-run.sh), so it holds no GPU memory between jobs and needs no
arbiter. Uses CUDA with a small memory cap; if the GPU is full (TTS / imagechat loaded) it falls back to the CPU provider.
"""
import json, os, sys, tarfile, time
import cv2, numpy as np
import onnxruntime as ort

BATCH = int(os.environ.get("BATCH", "32"))
MODEL = os.environ.get("CLIP_MODEL", "/ai1/models/clip/vision_model.onnx")
GPU_MEM = int(os.environ.get("CLIP_GPU_MEM_MB", "900")) * 2**20
MEAN = np.array([0.48145466, 0.4578275, 0.40821073], np.float32)
STD = np.array([0.26862954, 0.26130258, 0.27577711], np.float32)
sess, on_gpu = None, False


def log(m): print(f"{time.strftime('%T')} {m}", file=sys.stderr, flush=True)


def load(gpu):
    global sess, on_gpu
    so = ort.SessionOptions(); so.intra_op_num_threads = int(os.environ.get("CLIP_THREADS", "4"))
    prov = [("CUDAExecutionProvider", {"device_id": 0, "gpu_mem_limit": GPU_MEM, "arena_extend_strategy": "kSameAsRequested"}),
            "CPUExecutionProvider"] if gpu else ["CPUExecutionProvider"]
    sess = ort.InferenceSession(MODEL, so, providers=prov)
    on_gpu = sess.get_providers()[0] == "CUDAExecutionProvider"
    log(f"clip vision loaded: {sess.get_providers()[0]}")


def preprocess(img):
    h, w = img.shape[:2]; s = 224 / min(h, w)
    img = cv2.resize(img, (max(224, round(w * s)), max(224, round(h * s))), interpolation=cv2.INTER_CUBIC)
    h, w = img.shape[:2]; y, x = (h - 224) // 2, (w - 224) // 2
    img = img[y:y + 224, x:x + 224][:, :, ::-1].astype(np.float32) / 255.0   # BGR->RGB
    return ((img - MEAN) / STD).transpose(2, 0, 1)


def infer(x):
    global sess
    try:
        return sess.run(None, {sess.get_inputs()[0].name: x})[0]
    except Exception as e:
        if not on_gpu:
            raise
        log(f"GPU run failed ({str(e)[:80]}); continuing on CPU")
        load(False)
        return sess.run(None, {sess.get_inputs()[0].name: x})[0]


def run(batch, out):
    imgs, names = [], []
    for name, data in batch:
        im = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR) if data else None
        if im is None:
            out.write(json.dumps({"name": name, "error": "undecodable"}) + "\n"); continue
        imgs.append(preprocess(im)); names.append(name)
    if imgs:
        embs = infer(np.stack(imgs).astype(np.float32))
        embs = embs / np.linalg.norm(embs, axis=1, keepdims=True)
        for n, e in zip(names, embs):
            out.write(json.dumps({"name": n, "emb": [round(float(v), 6) for v in e]}) + "\n")
    out.flush()


def main():
    try:
        load(os.environ.get("CLIP_CPU_ONLY") != "1")
    except Exception as e:
        log(f"CUDA load failed ({str(e)[:80]}); CPU"); load(False)
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
