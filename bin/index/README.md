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
| Restic store | `catalog/restic_store.py` | `catalog-restic.db`: every distinct version of a path stored once with its snapshot range (960k versions, 357 MB for 11 snapshots), ingested by `build-restic` (6-hourly, restic listing of snapshots newer than the newest stored). |
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
  Existing collections in `collections.json` are untouched and not shown there.
