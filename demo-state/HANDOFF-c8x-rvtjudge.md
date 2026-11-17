# HANDOFF c8x-rvtjudge (2026-11-17, stopped at account cap)

## Committed (host2, nothing pushed)
- ~/rvt-research 98e12eb: write-lab guest.py `_ids32` (Revit 2020-2023 jobs compile); b912c0e test_guest_ids32.py (campaign/).
- ~/src/rvt-ballet 83e7425, c5dffbd, d1b8a61: rvt_judge1 Revit-made TWIN check (apply same API edit in Revit to the unedited file); every id differing outside the allowed list must be proven: Revit-derived dependent (hash equals twin) or transient first-open (settled hash equals control and twin; type/category/family flaps in the unedited control); twin edit has warnings-deleting preprocessor, dialog override in twin phase only, 420 s timeout, 2 tries; a timed-out twin never gives a PASS. 21 offline tests pass. Twin/transient rule VM-validated on b2 (2020 num, 2022 mark); the d1b8a61 hang fix and tighter class test NOT yet VM-validated.
- rvt_suite.py already judges via judge1 + skips cells with same writer commit + sample sha (8313945, earlier).

## Results (identical output bytes, separate batches)
STABLE: move 2022 (recorded, new cell), move 2023, mark 2020 (already on dashboard). UNSTABLE (curtain-mullion hash flap in Revit): move 2020, move 2021, mark 2021, rotate 2020. Not recorded yet: set_num 2020 and mark 2022 (passed once under the twin rule).
Decision open for orchestrator: dashboard PASS records "family instance move 2021" and "string parameter 2021" (c4x-rvteditopus 11-15) do not reproduce (y3 PASS, b2 FAIL); not overwritten.
Dashboard 160->156: latest-wins; real corrections (delete dangling refs, SEV-1 number parameter retraction, window cascade, wall auto-join).
Lane cost: mean wait 1820 s vs hold 306 s (lockhold.tsv); Revit start not dominant; persistent Revit mode parked. lane3 was started by me via lanectl (still up).

## In flight on host2
~/c8x-judge/b3: 11 cases (num 2020-23, mark 2021-23, move 2020-21, rot 2020-21), two sequential batches, logs run1.log, run2.log, verdicts in wd1/ wd2/. Record only cells PASSing in both (rvt-edit-record), note any needing the transient rule. launch.sh runs unattended; it was still waiting for a lane lock at stop.

## Rules learned
Never edit judge1.cs/.py while a judge1 batch of yours is running (old py + new cs gave an invalid rep1). Reports: ~/demo-state/REPORT-judge1-flap-and-twin.md, c3x-progress.md, queue c3x-c8x-rvtjudge-queue.md (items 9-17 open: record b3 stable cells, 2021 twin hang re-test).

## Update 2026-11-17 (c8x-rvtjudge2)
- b3 run1+run2 and b4 x3 finished on host2 lane3 (report: REPORT-c8x-rvtjudge2-b3-b4.md). No writer damage found; 2021 sample control is noisy so 2021 verdicts alternate on identical bytes (rot 2021 3 PASS / 2 FAIL; mark/move 2021 6/1; move 2020 5/0).
- rvt-ballet 81d925d: classify_extra(), transient path requires a twin, tests/test_judge1_classify.py (26 tests pass).
- Recorded: family instance move 2020, string parameter 2022+2023. Not recorded on purpose: set_num (number parameter row is FAIL by SEV-1), 2021 cells, rotate 2020 (item missing in matrix.json). Decisions pending: c8x-rvtjudge2-DECISIONS.md.
