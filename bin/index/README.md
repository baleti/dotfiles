# Search and indexing infrastructure

Everything here is generic code. The private parts are kept outside the repo:

- `~/.config/indexes/photos.json`: machine paths, mounts, SSH hosts, the Recoll index list.
- `~/.config/indexes/collections.json`: which folders each collection covers, which index types it gets, and the `ai1` SSH command.
- `~/.config/indexes/search-app.json`: folders hidden from results unless opted in with `//path`.
- `~/.cache/indexes/`: all index data (Recoll/Xapian, Chroma, embeddings, crops, models).

## Parts

| Part | Where | What it does |
|---|---|---|
| File-name index | `catalog/` (`catalog.py`, `filesearch.py`) | Walks the local home, rclone remotes and restic snapshots into `catalog.db`, then keeps every distinct path in memory for substring search. |
| Photo search server | `photos/search_server.py`, `search.py` | HTTP on 127.0.0.1:8765. File-name search, `/fts` (Recoll), `/clip` and `/face` (photo embeddings), `/paths` (folder completion), `/faces/pane` (face crops). |
| Picker | `images/` (Rust, egui) | The mod+1 "Search files" window. Talks only to the server. |
| Photo embeddings | `photos/index_photos.py`, `face_index.py`, `clip_text.py` | CLIP and InsightFace on the ai1 GPU (`photos/ai1/`). |
| PDF page images | `photos/pdf_pages_clip.py` | CLIP on large images inside PDFs, one record per page. Resumable through a done list. |
| Full text | Recoll (`recollindex`), one config directory per collection under `~/.cache/indexes/<name>/recoll` | Word search over file contents. `/fts` searches all of them. |
| Semantic text | `chroma/recoll_fulltext_to_chroma.py` | Chunks extracted text, embeds on ai1 (`chroma/minilm_embed_ai1.py`), stores in Chroma. |
| Driver | `photos/index_all.py` | Runs every flagged index for every collection in `collections.json`. |
| Nightly | `~/.config/systemd/user/nightly-index.{service,timer}` | 02:30 run of the driver, nice 19, idle I/O, 2 CPUs, memory capped at 8 GB. |
| Tools | `tools/pdf_list.py` (lists PDFs per collection), `tools/coverage.py` (indexed vs on disk) | Maintenance. |

## Behaviour

- Recoll only re-reads changed files, so re-runs are incremental.
- Chroma and page-image jobs skip documents they have already done. Changed documents are not re-embedded.
- A collection whose folder is on an unmounted NFS share is skipped.
- Folders listed in `search-app.json` are indexed but hidden from results unless the query has `//path <keyword>`.

## Commands

    ~/bin/index/photos/index_all.py                                # everything flagged, all collections
    ~/bin/index/photos/index_all.py --collections a,b --only fulltext
    ~/bin/index/tools/coverage.py                                  # indexed vs on disk, per collection
    ~/bin/index/tools/pdf_list.py <out.tsv>                        # PDF list for the page-image job
    systemctl --user status nightly-index
