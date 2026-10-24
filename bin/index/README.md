# Search and indexing infrastructure

Everything here is generic code. The private parts are kept outside the repo:

- `~/.config/indexes/photos.json`: machine paths, mounts, SSH hosts, the Recoll index list.
- `~/.config/indexes/collections.json`: the list of paths whose content is indexed (all into one Recoll index, `documents`), every index type on for every path (fulltext, chroma, page-CLIP, image CLIP, faces; a path object can switch one off, none do), `max_images_per_run`, and the `ai1` SSH command. Read through `photos/index_config.py`.
- `~/.config/indexes/search-app.json`: folders hidden from results unless opted in with `//path`.
- `~/.cache/indexes/`: all index data (Recoll/Xapian, Chroma, embeddings, crops, models).

## Parts

| Part | Where | What it does |
|---|---|---|
| File-name index | `catalog/` (`catalog.py`, `filesearch.py`) | Walks the local home, rclone remotes and restic snapshots into `catalog.db`, then keeps every distinct path in memory for substring search. |
| Restic store | `catalog/restic_store.py` | `catalog-restic.db`: every distinct version of a path stored once with its snapshot range (960k versions, 357 MB for 11 snapshots), ingested by `build-restic` (6-hourly, restic listing of snapshots newer than the newest stored). |
| Photo search server | `photos/search_server.py`, `search.py` | HTTP on 127.0.0.1:8765. File-name search, `/fts` (Recoll), `/clip` and `/face` (photo embeddings), `/paths` (folder completion), `/faces/pane` (face crops). |
| Picker | `images/` (Rust, egui) | The mod+1 "Search files" window. Talks only to the server. |
| Photo embeddings | `photos/index_photos.py`, `face_index.py`, `clip_text.py` | CLIP and InsightFace on the ai1 GPU (`photos/ai1/`). |
| PDF page images | `photos/pdf_pages_clip.py` | CLIP on large images inside PDFs, one record per page. Resumable through a done list. |
| Full text | Recoll (`recollindex`), one merged index, `~/.cache/indexes/documents/recoll`, built from the path list (`recoll.conf` is rewritten from it by the driver) | Word search over file contents. Narrow by folder with words before the verb: `ksr /fts contractor`. A listed path that does not exist is skipped and its documents stay. |
| Semantic text | `chroma/recoll_fulltext_to_chroma.py` | Chunks extracted text, embeds on ai1 (`chroma/minilm_embed_ai1.py`), stores in Chroma. |
| Image CLIP + faces | `photos/remote_images.py` (host3), `photos/host1_image_job.py` (host1), timers `image-index-start` (daily check, runs every 3 days) and `image-index-pull` (every 2 h) | New and changed images (size or mtime) of the `collections.json` paths go to the ai1 GPU workers via host1, at most `image_job_hours` per run (smallest folders first, resumable). The Drive credentials are copied into RAM on host1 (`/dev/shm`, 0600) per run and shredded when the job ends; nothing on host1's disk. `pull` appends host1's records to the local clip/faces files and replaces a changed file's old record. `remote_images.py status`, `start --force`, `start --dry-run`. |
| Driver | `photos/index_all.py` | Runs full text, Chroma, page-CLIP, image CLIP and InsightFace faces for the paths in `collections.json` (all on unless a path opts out; images come from the file-name catalog, at most `max_images_per_run` new ones per run). Chroma counts documents already embedded in the old per-folder stores (`~/.cache/indexes/<old name>/chroma`, kept as read-only shards) as done. |
| Catalog refresh | `~/.config/systemd/user/catalog-*.{service,timer}` | Safety-net walks: local nightly at 03:00 and once after each boot (`catalog-local`, incremental, about 30 s; what it finds is mostly files still held open and being written), newest restic snapshot every 6 h (`catalog-remote`), Google Drive weekly on Sunday 04:20 (`catalog-drive-full`), the NFS roots monthly (`catalog-extra`). A full walk drops deleted files and old versions. Full builds touch `catalog.db.gen`, which makes the server reload; live changes do not (see below). |
| Nightly | `~/.config/systemd/user/nightly-index.{service,timer}` | 02:30 run of the driver, nice 19, idle I/O, 2 CPUs, memory capped at 8 GB. |
| Nightly supplier-details | `~/.config/systemd/user/index-supplier-details.{service,timer}` | 01:15 plain `recollindex` of the supplier-details collection (nice 19, idle I/O, 3 GB cap, 3 h timeout). Separate because the 02:30 driver walks collections in config order and hit its 12 h timeout (orms extractions that fail with `internfile failure` take ~20 min each) before reaching supplier-details; the driver still lists it, but finds nothing left to do. |
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

## View settings, verbs and shortcuts

- **Settings file** `~/.config/indexes/picker-settings.json` (`Ctrl+P` in the picker edits it): defaults for
  `show_dotfiles` (true), `show_backup_restic` (false), `show_backup_btrfs` (false), and a `shortcuts` map
  (action -> list of chords such as `"Ctrl+R"`, `"F4"`). The server reads the view defaults on every query.
- **Query verbs** override the defaults for one search, anywhere in the query, later ones win:
  `/show-dotfiles` `/hide-dotfiles`, `/show-backup` `/hide-backup` (both kinds), `/show-backup-restic`
  `/hide-backup-restic`, `/show-backup-btrfs` `/hide-backup-btrfs`. Hiding dotfiles adds the negated term `!/.`.
- **Restic backups** are a table of their own in the server, loaded in the background the first time a query asks
  for them (about 10 s; the status line says so and the panel refreshes when ready). One row per path (its newest
  version) with the path under the restic mount, `<mount>/ids/<short id><original path>`, so open, copy and
  preview work like on any file. They are not part of the main catalog, so default searches pay nothing and no
  longer show backup-only ghost paths. Cache churn is left out of the history (`restic_exclude` in the catalog
  config). btrfs snapshots (snapper) are not indexed yet; `/show-backup-btrfs` says so.
- **Shortcuts** (`ACTIONS` in `images/src/main.rs`) are rebindable in the settings window: click one, press the new
  keys (Esc cancels, Backspace removes, bare letters are refused). Arrows, Enter, Tab, Esc, paging, Delete and
  Shift+arrows are fixed. Colours follow the wallpaper: the picker re-reads `~/.local/state/quickshell/scheme.json`
  when it changes.

## Command line (`search`) and `/chroma`

- **`bin/search`** (symlinked into `~/.local/bin`) asks the search server the same question the picker asks, with the
  same query language, ordering and view settings: `search montgomer corpus '!pdf-to-png' .pdf`. Options: `-n`, `-s/--asc`,
  `-c` (count and summary), `-l`, `--json`, `-0`, `--score`, `--snippets`, `--dotfiles/--no-dotfiles`,
  `--backup restic|btrfs|all|none`, `--start` (start the server if it is down), `--raw`, `--syntax` (the query
  language). Exit 0 results / 1 none / 2 server unreachable. Photo results are mapped to real mount paths.
  `tools/search_cli_check.py` verifies it against the live server (17 checks).
- **`/chroma words`** is semantic search over the Chroma text indexes (about 1.4M chunks): files whose text means
  something close to the words, best first, with a score; it takes `//path //mime //name //size`, `/chroma/<index>`
  for one index, and shows the matching chunks as snippets. The Chroma indexes live in a separate on-demand worker
  (`photos/chroma_worker.py`, `chroma-search.service`, 127.0.0.1:8766, about 3.5 GB while loaded, exits after 15 idle
  minutes); the search server starts it on the first `/chroma` query (about 30 s) and the panel refreshes when it
  is ready. Queries are embedded on the CPU with the ONNX MiniLM model (`photos/minilm_text.py`).
- **Typing speed**: the name scan is multi-threaded C (`catalog/scan.c`), requests for characters you have typed
  past are dropped by the server (client id + sequence number), thumbnail workers run at low priority, summaries over
  500k matches are sampled and shown with a leading `≈`.

## Choosing the indexed directories (picker: Settings > Indexing, Ctrl+P)

- **File names (path search)**: the directories the local catalog walk covers (default: the config's `catalog.local_roots`).
  Stored in `~/.config/indexes/index-dirs.json` (`path`), read by `catalog.py build-local` and by the live watcher
  (changes outside the list are ignored). Google Drive, NFS roots and restic keep their own sources.
- **File contents**: `fts.dirs` plus four switches, built as the managed collection `user-dirs`
  (`~/.cache/indexes/user-dirs/`): `bm25` = Recoll (`/fts`, searched together with the other indexes, `/fts/user-dirs` alone),
  `chroma` = semantic text index (`/chroma/user-dirs`, embeds on ai1), `clip` = image contents and `face` = InsightFace
  (`index_photos.py --base /`, records keyed by absolute path, ai1 GPU, resumable; records stay if a directory is removed later).
  A changed directory list resets the Recoll and Chroma indexes of `user-dirs`.
- **Apply and index now** runs `photos/apply_index_dirs.py` as the transient user unit `apply-index-dirs` (nice 19, idle I/O;
  one run at a time); the window follows its progress from `GET /index-dirs` (`~/.cache/indexes/index-dirs-status.json`).
  The paths in `collections.json` are untouched and not shown there.

## Revit and DWG content indexes (separate Recoll indexes)
Revit (`.rvt .rfa .rte .rft`) and DWG/DXF contents live in their own Recoll indexes, `~/.cache/indexes/revit/recoll` and
`~/.cache/indexes/dwg/recoll`, because they are large and slow to build. Both are listed in `fts.indexes` in
`~/.config/indexes/photos.json`, so `/fts` searches them (`/fts/revit words`, `/fts/dwg words` select one).
- `photos/index_cad.py revit|dwg [--limit N] [--batch N] [--roots ...]` takes the file list from the catalog and runs
  `recollindex -i` on batches (unchanged files are skipped). Topdirs: `/mnt/backups/office`, `~/gdrive-rclone-crypt/office`.
- Revit filter: `~/rvt-research/rvt2recoll.py` (decoded and cached on host1; one decode at a time, only when host1 has >11 GB
  free, capped at 4 GB / 200% CPU, and it writes `~/.cache/indexes/revit/HALT` if the ai1 VM restarts). DWG: NOT indexed yet. LibreDWG/dwgread
  was dropped by decision; the filter will be built on our own parser (`~/dwg-research/dwg2text.py`) when it is ready, see `~/dwg-research/NEEDS-FROM-INDEX.md`.
- The Revit build runs as the transient unit `index-revit` (nice 19, idle IO). Nightly updates: `nightly-cad-index.timer` (04:30, revit only).
- The corpus-*, part3-books and professional-reference collections skip these extensions (`skippedNames+` in their recoll.conf) so nothing is indexed twice.

Settings > Indexing also shows the real setup, read live by `photos/index_info.py` (`GET /index-dirs`): the Excluded list for
the file-name walk (`exclude` in index-dirs.json: a path, or a bare folder name wherever it occurs; applied by the walk and
the live watcher) next to the config's own exclusions and mount points, every content index with documents and size on disk,
and the schedule of each indexing job (fanotify watcher, Drive changes and weekly full listing, local safety-net walk, restic
and btrfs ingestion, NFS stream and monthly walk, nightly collections, nightly Revit/DWG) with last and next run.

## Compact name table and automatic NFS roots (2026-10-24)
- **Compact name table**: `NAMES_COMPACT=1` (set in `~/.config/systemd/user/images-search.service.d/compact.conf`, with `MemoryHigh=2G` / `MemoryMax=3G`)
  makes `filesearch.NameTable` map a snapshot instead of holding 4M+ Python strings. The snapshot (`catalog.db.nt/NameTable-<gen>/`: lower-case
  and original-case blobs, offsets, sort orders as `.npy`, about 1.6 GB on disk) is built by a child process (`filesearch.py --build NameTable DB OUT`,
  about 35 s, 2.3 GB peak while it runs) whenever the catalog generation changes, and the server maps it (anonymous memory ~0.1-0.3 GB, the rest is
  reclaimable page cache). Results are identical to the in-memory table (checked on 2060 queries plus live-overlay ops). Unset the variable to go back.
  The restic and btrfs tables are not converted yet.
- **Path search covers every content-indexed path**: `catalog.py` adds an extra (NFS) root for every directory under `/mnt/backups` that is
  a Recoll `topdirs` entry of an index in `fts.indexes` or a path in `collections.json`, unless an existing extra root already contains it. So
  `supplier-details` is found by name as well as by content. After adding such an index run `systemctl --user start catalog-extra` and restart `catalog-host1-watch`.
- **Only the name table is resident** (2026-10-24): `search_server.py` starts with just the compact name table (~0.1 GB anonymous memory). The CLIP/face
  matrices are memory-mapped from `~/.cache/indexes/photos/cache/*.npy`, their metadata, the CLIP text model and the photo size/date lists load on the
  first image/face query (about 7 s) and are dropped again after `IDLE_UNLOAD_S` (default 600 s) without use (`_idle_unloader`). Full-text search was
  already out of process (`recollq` per query, Chroma in its own on-demand worker). The restic and btrfs tables use the same compact snapshots
  (`catalog-restic.db.nt`, `catalog-btrfs.db.nt`; building them takes 10-30 s and up to 2.8 GB in a short-lived child). The recent-term cache keeps
  16 masks (`TERM_CACHE`, 4.4 MB each). After an unload the process keeps ~150-250 MB of imported Python/torch modules; only a restart returns that.
