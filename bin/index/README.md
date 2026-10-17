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
| Catalog refresh | `~/.config/systemd/user/catalog-*.{service,timer}` | Safety-net walks: local nightly at 03:00 and once after each boot (`catalog-local`, incremental, about 30 s; what it finds is mostly files still held open and being written), newest restic snapshot every 6 h (`catalog-remote`), Google Drive weekly on Sunday 04:20 (`catalog-drive-full`), the NFS roots monthly (`catalog-extra`). A full walk drops deleted files and old versions. Full builds touch `catalog.db.gen`, which makes the server reload; live changes do not (see below). |
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

## Live updates (new and changed files show up in about a second)

    helper (system unit, root-owned code)  ->  watcher.py (user)  ->  catalog.db + POST /delta  ->  search server overlay

- **fanwatch/helper.py** holds ONE fanotify filesystem mark for a whole btrfs volume. fanotify refuses marks
  inside btrfs subvolumes (EXDEV), so the unit's root pre-step (`mount-top.sh`) mounts the top-level subvolume
  (`subvolid=5`) read-only at `/run/btrfs-top`, the helper marks through it, opens a descriptor on it and then
  detaches the mount itself (`umount2 MNT_DETACH`; the mark belongs to the filesystem, the descriptor keeps the
  detached mount alive for handle -> path). A startup self-test requires its own test file's event to arrive.
  It runs as the desktop user with only `CAP_SYS_ADMIN` + `CAP_DAC_READ_SEARCH` and writes resolved path events
  (JSON lines) to `/run/fanwatch/events.sock` (0600). Code is installed root-owned in `/usr/local/lib/fanwatch`
  so nothing running as the user can change what holds the capabilities.
- **Install / update (needs sudo, host3 and host1 alike)**: copy `fanwatch/{helper.py,mount-top.sh,stream.py}` to
  `/usr/local/lib/fanwatch/` (mode 755), `fanwatch-helper.service` to `/etc/systemd/system/`, per-host settings as
  a drop-in `fanwatch-helper.service.d/host.conf` (`FANWATCH_VOLUME`, `FANWATCH_SKIP_UNDER`, `FANWATCH_ONLY`,
  `FANWATCH_CANARY_DIR`; host1's is `fanwatch/host1/host.conf`), then `systemctl enable --now fanwatch-helper`.
  Only a change to those files needs sudo again; everything else is user space.
- **watcher.py** (`catalog-watcher.service`, unprivileged): applies the walk's exclusions, coalesces per path,
  `lstat`s when a path settles, writes the catalog database and POSTs the result to the search server
  (`/delta`, token in `catalog.db.delta-token`). The server (`filesearch.NameTable`) overlays deltas on its
  in-memory table (dead mask + small delta table merged at query time) and never reloads for them.
- **NFS roots (host1)**: kernel notifications do not cross NFS (NFSv4.1 directory delegations with CB_NOTIFY
  reached nfsd in Linux 7.3 but nothing hands them to user space), so the same helper runs on host1 and
  `fanwatch/stream.py` there turns events into resolved ops. `hostwatch.py` (`catalog-host1-watch.service`)
  reads them over `ssh host1-wg`: a restricted key (`restrict,from=<wg address>,command=stream.py`), bound to the
  WireGuard address (`~/.ssh/config`). Writes made through the NFS mount are seen too (nfsd operations are
  ordinary VFS operations on host1). A reconnect after a gap or an overflow starts a full `build-extra`.
- **Google Drive**: `poll-drive` (every 2 min) reads the Drive changes feed and relists only changed folders.
- The helper keeps ONE client; a second consumer displaces the first (and both then rescan).
- What none of this sees: files held open and still being written (updated on close), other filesystems on host3
  (the periodic walks cover them), changes while a piece was down (reconnect triggers a walk).
