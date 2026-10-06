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
