# PROGRESS (keep this current; update at the end of every milestone)

Started 2026-11-08 by the previous session; you take over. Read HANDOFF.md first.

## Milestones
- [x] M0 scaffold builds (`dotnet build -c Release -o out`, 8 s, net48 WPF code-only, SearchApp.exe)
- [x] M1 Api/Dsl/Theme/Config + golden tests + --selftest (48313 golden records 0 diffs; live checks ok on the PC)
- [x] M2 main layout, chrome, query box, list view, status, --shot
- [x] M3 grid, thumbnails, zoom, header sort + resize
- [x] M4 keyboard/selection, open, context menu
- [x] M5 completion + history popups
- [x] M6 preview pane, settings panel
- [x] M7 live refresh, theme polling, light mode
- [x] M8 polish: DPI, persistence, icon, AppUserModelID, drag-out, Ctrl+N, command line
- [x] M9 deploy + README + final report

## Feature checklist (done = implemented and checked offscreen or by selftest; "needs hands" = needs the user's real desktop to confirm)
- [x] Window look, dark/light follows Windows theme, server palette polled every 1 s, JetBrains Mono from server, layout numbers as the page (light + dark shots compared)
- [x] Custom chrome (query box in title row, own min/max/close), size/position/maximised saved (needs hands: drag, resize, maximised margins)
- [x] AppUserModelID + icon (needs hands: pin to taskbar, Win+1)
- [x] Query box with bold accent command tokens (alignment checked with a debug overlay), 280 ms debounce, Enter, history Up/Down/Ctrl+J/K, Ctrl+R/F4 popup, Tab/Ctrl+Space completion incl. //path, golden-tested logic
- [x] Alt+D, Ctrl+E, Tab/Esc from list, typing in list goes to query (needs hands)
- [x] Virtual list and grid, 200 per page on demand (selftest: jump to last row of 13,006), stale handling (selftest), thumbnails with retry and LRU
- [x] Header sort by rewriting /s/ token (selftest), resize with persistence, double-click reset
- [x] Zoom: Ctrl+wheel, Ctrl +/-/0/9, saved
- [x] Selection and keyboard navigation, highlighting of matched terms
- [x] Status line: idle, busy spinner, errors, flashes
- [x] Preview pane for content searches
- [x] Settings panel (Ctrl+P), shared with the picker; live check toggles and restores a setting
- [x] Live refresh on catalog change; Ctrl+C; Ctrl+N; command line query; last query restored
- [x] Open: in place via drive map, else download to %TEMP%\SearchApp then ShellExecute; URL results open in the browser; danger confirmation (decisions covered by selftest in dry mode, real launch needs hands)
- [x] Context menu: Open, Open with, Show in folder, Copy path, Copy Windows path, Save a copy as, Open in browser (needs hands)
- [x] Drag a result out to Explorer/Outlook/Teams (needs hands)

## Decisions / deviations
- Text is drawn with TextFormattingMode.Ideal: Display mode rounds the mono advance to whole pixels (7 px instead of 6.6 at 11 px) and truncated the date column.
- With the preview pane open the column header is narrowed to the list width (the web page leaves it full width, so its columns do not line up).
- Settings section is called "This app" (the web page says "This browser").
- Popups, context menu and settings are drawn in an overlay layer inside the window, not as separate system windows (no focus side effects, also visible in offscreen shots).
- Mono/Linux cannot run the exe (no WPF): every test runs on the PC through ssh wsl, offscreen.
- Sorted queries over the whole catalog take about a minute on the server (for example `sample /s/size`, 13,006 hits); the web page has the same delay. Nothing to do on the client.

## Known gaps / not verified
- Nothing that needs a real desktop was tried: keyboard focus flow in a shown window, caption drag/resize/maximise (maximised margin uses SystemParameters.WindowResizeBorderThickness), taskbar pin and Win+1, the real ShellExecute of an .eml, Open with chooser, Show in folder, Save a copy dialog, drag-out, the system theme change event. The user does the final try-out.
- Braille spinner glyphs are not in JetBrains Mono, Windows falls back to another font.
- Smooth wheel scrolling and touch/pinch are not ported (not wanted).

## Server wishes (do not change the server; write requests here)
- Owner column: the Windows app reads owners itself for files under the drive map (NTFS/SMB, `OwnerCache`). Files that live on the Linux host have no owner in the API; a `owner` field per hit in /api/query would let the column work there too (and make it sortable).
- /api/query with /s/size is very slow on the full catalog (about 60 s). A cached size index on the server would help.

## Later work (after the first delivery)
- search-web: `fileok` is a string check instead of a stat per result (a page of 200 results took 20 s over the sshfs mounts, now 0.3 s).
- Query engine: `//<attribute> value` for every attribute stored with document-system entries (substring on the attribute name and
  on the value, `!` negates; `//own` matches owner, owner-id, owner-org ...) and `//pages >N` (counted PDFs only). /facets lists
  them, the Windows app completes and highlights them. The web page's completion list was not changed.
- Owner column (Windows files through the drive map), left-edge column resizing, Ctrl+W, Ctrl+Shift+R restart, rename-aside deploy.
- Live watcher for the Windows drives (see README). Found and fixed on the way: watcher.py (the local live watcher) retried a failing
  batch forever and held the catalog's write lock since ~03:15, starving every other writer; it now skips unreadable paths.
- Restarting images-search drops the live changes it holds in memory; touch `~/.cache/indexes/catalog/catalog.db.gen` afterwards (a
  reload takes about a minute).
- Not done: copying the catalog to the PC (the slowness was the per-result stat, not the indexes).
