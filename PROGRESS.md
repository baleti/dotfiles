# PROGRESS (keep this current; update at the end of every milestone)

Started 2026-11-08 by the previous session; you take over. Read HANDOFF.md first.

## Milestones
- [x] M0 scaffold builds (`dotnet build -c Release -o out`, 8 s, net48 WPF code-only, SearchApp.exe)
- [x] M1 Api/Dsl/Theme/Config + golden tests + --selftest (48313 golden records 0 diffs; live checks ok on the PC)
- [ ] M2 main layout, chrome, query box, list view, status, --shot
- [ ] M3 grid, thumbnails, zoom, header sort + resize
- [ ] M4 keyboard/selection, open, context menu
- [ ] M5 completion + history popups
- [ ] M6 preview pane, settings panel
- [ ] M7 live refresh, theme polling, light mode
- [ ] M8 polish: DPI, persistence, icon, AppUserModelID, drag-out, Ctrl+N, command line
- [ ] M9 deploy + README + final report

## Feature checklist
Copy the checklist from HANDOFF.md section 4.1 and 5 here and tick items as they are verified.

## Decisions / deviations

## Known gaps

## Server wishes (do not change the server; write requests here)

## How to test
- `node tools/golden.js ~/src/search-web/web/index.html hist.json facets.json golden.json` (golden.json is git-ignored)
- `./deploy.sh`, copy golden.json to the PC out folder, `tools/pcrun.sh st.txt --selftest --golden 'C:\\Users\\USER\\SearchApp\\out\\golden.json' --live`
- mono cannot run the exe (no WPF); everything runs on the PC.
