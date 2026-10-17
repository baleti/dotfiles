"""all-MiniLM-L6-v2 sentence embedder (ONNX, CPU): the model the Chroma text indexes were built with
(see ../chroma/export_minilm_onnx.py, which bakes in mean pooling and L2 normalisation)."""
import os
import numpy as np, onnxruntime as ort
from transformers import AutoTokenizer

HERE = os.path.expanduser("~/.cache/indexes/models/minilm-onnx")
MAX_LEN = 256
_sess = None
_tok = None

def _load():
    global _sess, _tok
    if _sess is None:
        _tok = AutoTokenizer.from_pretrained(HERE)
        _sess = ort.InferenceSession(os.path.join(HERE, "model.onnx"), providers=["CPUExecutionProvider"])

def embed_texts(texts):
    """(n, 384) float32, unit length."""
    _load()
    enc = _tok(list(texts), padding=True, truncation=True, max_length=MAX_LEN, return_tensors="np")
    feed = {i.name: enc[i.name].astype(np.int64) for i in _sess.get_inputs() if i.name in enc}
    return _sess.run(None, feed)[0].astype(np.float32)
