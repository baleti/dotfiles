# HANDOFF c8x-rvtjudge2 (2026-11-17, stopped at account cap)

## Committed on host2 (~/src/rvt-ballet, nothing pushed)
- 81d925d judge1 classify_extra(): transient first-open path needs a usable Revit-made twin; tests/test_judge1_classify.py (5 tests)
- 0e01ee9 RVT_JUDGE1_TWIN_FORCE=1: run the twin on a PASS too (evidence only)
- 7ddd231 tests/test_rotate_connected_refused.py
- rotate_connected_refusal() in rvtballet/save.py: refuses rotate of ANY element with MEP connector links. It is in HEAD inside another agent's commit a16b5f8 (shared working tree); not mine by message.
- Verified: 26 judge tests + 7 guard tests passed. A broader rotate/move-guard run (25 passes, no failure) never printed its summary: it was stuck on test_wall_rotate_fields_consistent.py (3600 s timeout, wall rotate, unrelated to the guard); pytest pid 3477052/3477055 on host2 may still be running, kill if so.

## Findings
- b3 x2 + b4 x3 + b5: no writer damage on 2020-2023 move/mark/rotate of family instances; twin == output on 2021 move/rot, 2022 move, 2023 move, mark 2020. The 2021 sample control is noisy, verdicts alternate on identical bytes (rot 2021 4 PASS / 2 FAIL).
- REAL DEFECT (research writer, 2022 and 2023): rotate of 731025 (connected to 4 MEP) makes PipingSystem 730260 Volume 89.98 -> 0; Revit's own rotate does not. The shipped product refuses 2022/2023 files, so it did not ship that; the guard now covers 2024-2026 (1506 HVAC 2024 FamilyInstances with 3-6 links were rotatable before).
- host2 /tmp was 100 % full (2294 leaked tmp* dirs deleted with the user's approval); leak will recur until tests clean up mkdtemp dirs.

## In flight on host2 (unattended, waiting for a lane lock when I stopped)
- ~/c8x-judge/b8/run1.log (rotate 1379283, 4 links) and run2.log (1382194 3 links, 1377544 6 links): PRE-guard product outputs (copy in ~/c8x-judge/preguard = a16b5f8^), HVAC 2024, judged with TWIN_FORCE. Decision rule: FAIL or twin != output => the guard is needed in 2024 (keep); PASS with twin == output => guard is conservative, re-measure the threshold (it refuses ~1500 safe-looking rotates). Read TWINFORCE/EXPLAIN lines in wd1/, wd2/ verdicts.

## Dashboard
Recorded: family instance move 2020; string parameter 2022+2023. Withheld on purpose: number parameter (SEV-1), 2021 cells (noise), rotate 2020 (item missing from matrix.json). Nothing recorded for the rotate-connected finding yet.

## Open for the orchestrator
c8x-rvtjudge2-DECISIONS.md (5 points), STATUS-FOR-USER c8x-rvtjudge2-STATUS-FOR-USER.md (needs the b8 result added), REPORT-c8x-rvtjudge2-b3-b4.md. Queue: c3x-c8x-rvtjudge2-queue.md (open: 29 verdicts, 25 status refresh).
