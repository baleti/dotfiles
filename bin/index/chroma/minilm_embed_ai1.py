"""Runs on ai1: reads a JSON list of texts on stdin, writes a JSON list of MiniLM embeddings on stdout (GPU if available)."""
import json, os, sys
import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer

HERE = os.path.dirname(os.path.abspath(__file__))
texts = json.load(sys.stdin)
tok = Tokenizer.from_file(os.path.join(HERE, "tokenizer.json"))
tok.enable_truncation(256)
tok.enable_padding()
sess = ort.InferenceSession(os.path.join(HERE, "model.onnx"),
                            providers=["CUDAExecutionProvider", "CPUExecutionProvider"])
out = []
for s in range(0, len(texts), 64):
    enc = tok.encode_batch(texts[s:s + 64])
    vecs = sess.run(None, {
        "input_ids": np.array([e.ids for e in enc], np.int64),
        "attention_mask": np.array([e.attention_mask for e in enc], np.int64),
        "token_type_ids": np.array([e.type_ids for e in enc], np.int64),
    })[0]
    out.extend(vecs.astype(np.float32).tolist())
json.dump({"providers": sess.get_providers(), "vectors": out}, sys.stdout)
