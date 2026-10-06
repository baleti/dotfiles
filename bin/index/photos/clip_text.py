"""CLIP ViT-B/32 text encoder (ONNX, CPU) for host3. Matches the ai1 vision
model's embedding space (both from Xenova/clip-vit-base-patch32)."""
import os, numpy as np, onnxruntime as ort
from transformers import CLIPTokenizerFast

import config
HERE = config.CFG["clip_text_dir"]
_sess = None; _tok = None

def _load():
    global _sess, _tok
    if _sess is None:
        _tok = CLIPTokenizerFast.from_pretrained(HERE)
        _sess = ort.InferenceSession(os.path.join(HERE, "text_model.onnx"),
                                     providers=["CPUExecutionProvider"])

def embed_texts(texts):
    _load()
    enc = _tok(list(texts), padding=True, truncation=True, max_length=77, return_tensors="np")
    feed = {i.name: enc[i.name].astype(np.int64) for i in _sess.get_inputs() if i.name in enc}
    out = _sess.run(None, feed)[0].astype(np.float32)
    return out / np.linalg.norm(out, axis=1, keepdims=True)

if __name__ == "__main__":
    import sys
    e = embed_texts(sys.argv[1:] or ["a photo of a building"])
    print(e.shape, [i.name for i in _sess.get_inputs()], [o.name for o in _sess.get_outputs()])
