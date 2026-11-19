# What the Revit oracle proves about inline .rvt saves (c8x-rvtjudge2, 2026-11-17)

## Proven (real Revit 2020-2023 in the VM, repeated batches, identical output bytes)
- Our move and rotate of a family instance gives the same result as Revit doing the same edit itself: in 4 cells (2021 move, 2021 rotate, 2022 move, 2023 move) the Revit-made twin equals our output on every one of about 21,900 elements outside the edited one.
- Offline, only the edited element's record changes (2021 rotate: 1 of 27,587 elements; the curtain mullion that Revit flags has a byte-identical record).
- The Revit-made twin step no longer hangs (2021 move twin finished in 230 s; it timed out 3 of 3 before the fix).
- Stable repeated PASS on identical bytes: move 2020 (5 of 6 verdicts in the ledger), set number 2020-2023 on a view parameter, mark 2022 and 2023, rotate 2020.

## Not proven / limits
- 2021 samples: Revit's own control is noisy (a different element flaps each run), so verdicts on identical bytes alternate (rotate 2021: 4 PASS / 2 FAIL). This is oracle noise, not damage found, but a single run proves nothing there.
- 2025: no Revit 2025 port on lane2/lane3, so there is no verdict at all for 2025 (requested from the lane owner).
- Numeric parameters on floors and walls: the dashboard row is FAIL (SEV-1: the parameter reads back but derived geometry stays stale). My number-parameter passes edit a view Detail Level only and say nothing about that.
- Judge verdict history on the same bytes flipped because the judge itself changed during the day (transfer check, ADD tolerance, twin and noise rules). One 2024 wall case (readback 1 of 3 once) is unexplained.

## Decisions waiting for you
See c8x-rvtjudge2-DECISIONS.md (flaky 2021 dashboard rows, mullion first-open rule, rotate item missing in matrix).

## Where things are
Report REPORT-c8x-rvtjudge2-b3-b4.md; judge fix rvt-ballet 81d925d (twin required), 0e01ee9 (twin evidence knob), host2 only, nothing pushed.

## Update 2026-11-17 (c8x-rvtjudge3)
- Pre-guard MEP rotate outputs (HVAC 2024, 3 links 4/3/6): all PASS the judge, but 1 of 3 differs from Revit's own rotate (a duct system value we leave stale). The guard stays.
- 2021 mark PASS; 2021 move FAIL: a curtain-wall mullion changes on the first open of the output (not the writer layout: the same-layout Mark edit passes). Unrecorded; needs your decision whether "second open equals control" may count.
- 2022/2023 mark PASS (differences are Revit-derived and equal the Revit-made twin). 2026 in-place-saved Mark PASS (22 MB Autodesk sample).
- Rotate: 2020 PASS (recorded, new matrix item "family instance rotate"); 2022/2023 FAIL = the known piping-system Volume 0 defect, caught by the judge (permanent regression files).
- 2025: product refuses by policy (writable years 2024, 2026). 2026 workshared files refused in place by the gate.
- Infrastructure: lane2 wedged twice (Revit never ready); judge1 now has a lane-hold watchdog (exit 3 INFRA, lane marked degraded). Lane2 needs a restart by the lane owner.

## Update 2 2026-11-17 late (c8x-rvtjudge3)
Judge (Revit VM, lane3) results on Autodesk samples, product or research writer outputs:
- PASS: 2024 and 2026 in-place Mark edits of every shape tried (400/2000/4096 chars, unicode, CRLF, spaces, markup chars, last element, 3 chained saves); 2020-2023 Mark/move/rotate(2020) and unicode Mark; 2024 x2 and 2026 x1 product in-place DELETES of connected HVAC terminals (judge twin now covers delete; Revit recomputes the MEP system, our file has no stale values).
- FAIL (kept): 2021 move/rotate/some marks = mullion 574523 first-open flap, which also happens on UNEDITED byte copies (1 of 3): Revit/sample noise, not the writer; 2022/2023 rotate of the MEP-connected 731025 = known Volume 0 defect (judge catches it); 1-byte flip of an output passes the Revit judge (semantic layer only: the byte layer is the product gate).
- Offline safety, 2024/2026 (host2): kill -9 during save (58 kills, never a partial file), restore byte-identical (3-save chains, original stays pinned after 25 saves), damaged/truncated/zero/text inputs refused (CLI and server), stale source refused (content hash), concurrent saves serialised, disk full and backup-full refused before replacing, odd paths and 251-char names fine, read-only file refused by the server (the research CLI overwrites and chmods 644: sev 3), raw gate is element-granular (move amount and same-element params caught only by the product read-back).
- Needs your decision (NEEDS-FROM-ORCHESTRATOR.md): judge rules 49 (identical-copy noise floor) and 51 (Serious-Error reopen). lane2 needs a restart.
