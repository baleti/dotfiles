import torch, sys
from pathlib import Path
from sentence_transformers import SentenceTransformer

src = Path.home() / ".cache/indexes/models/all-MiniLM-L6-v2"
out = Path.home() / ".cache/indexes/models/minilm-onnx"
st = SentenceTransformer(str(src), local_files_only=True)
hf = st[0].auto_model.eval()
tok = st.tokenizer

class Embed(torch.nn.Module):
    def __init__(self, m):
        super().__init__(); self.m = m
    def forward(self, input_ids, attention_mask, token_type_ids):
        h = self.m(input_ids=input_ids, attention_mask=attention_mask, token_type_ids=token_type_ids).last_hidden_state
        mask = attention_mask.unsqueeze(-1).to(h.dtype)
        pooled = (h * mask).sum(1) / mask.sum(1).clamp(min=1e-9)
        return torch.nn.functional.normalize(pooled, p=2, dim=1)

enc = tok(["hello world"], padding="max_length", max_length=256, truncation=True, return_tensors="pt")
torch.onnx.export(Embed(hf), (enc["input_ids"], enc["attention_mask"], enc["token_type_ids"]), str(out / "model.onnx"),
                  input_names=["input_ids", "attention_mask", "token_type_ids"], output_names=["embedding"],
                  dynamic_axes={k: {0: "batch", 1: "seq"} for k in ["input_ids", "attention_mask", "token_type_ids", "embedding"]},
                  opset_version=17, dynamo=False)
tok.save_pretrained(str(out))
print("exported", out, file=sys.stderr)
