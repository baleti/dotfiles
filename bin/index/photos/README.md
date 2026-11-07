# photo index tools

Local search over the gdrive photo folders: CLIP image embeddings (content),
InsightFace face embeddings (people), a query server and a launcher picker.

Layout
- `config.py`, `config.example.json`: all machine-specific values. Real config is
  `~/.config/indexes/photos.json` (private, not committed; IMAGES_CONFIG overrides).
- `search.py`: query engine (`//face`, `//clip`, `//name`, `//path`, `//size`, `//dm`).
- `search_server.py`: keeps models in memory; systemd user unit `images-search`.
- `thumb.py`, `query_faces.py`: thumbnails and face lookups.
- `index_photos.py`: stages gdrive images in chunks and streams them to ai1 for
  CLIP + face embedding (resumable). `face_index.py`: face-only variant.
- `clip_text.py`: CLIP text encoder (ONNX, CPU) for query embedding.
- `tools/dedupe.py`: merges the rclone listings into one deduplicated path list.
- `ai1/`: worker scripts that run on the ai1 VM (copied here for reference;
  they are deployed under ~/indexer on ai1).

Data (indexes, people, listings, thumbnails, logs) lives in `data_dir` from the
config and is never committed.

Picker: `~/bin/index/images` (Rust, egui), reads the same config.

## PDF page CLIP on host1 (2026-11-07)

The old ai1 VM (with its `~/indexer` CLIP/face workers) was replaced by the podman pod `ai1` on host1 because of memory
pressure. CLIP now runs as a throw-away container, `~/ai1-native/bin/clip-run.sh` (tar of images on stdin, JSON lines on
stdout; GPU with a 900 MB cap, CPU fallback; venv `~/ai1-native/clip-venv`, model `~/ai1-native/models/clip/vision_model.onnx`,
worker `ai1/clip_worker_pod.py`). `remote_pdf_pages.py start|pull|status` runs `pdf_pages_host1.py` (pdfimages + pdftoppm + CLIP,
next to the files) as the user unit `pdf-pages` on host1 and pulls the records back (`pdf-pages-pull.timer`, every 2 h).
Not ported yet: the face worker, the minilm/chroma worker (`worker.py`, `run-worker.sh`) and Drive PDFs (no rclone on host1 for them).
