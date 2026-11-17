# c8x-rvtjudge2 queue (2026-11-17, host3 -> host2 over ssh). Goal: inline save never corrupts; real-app VM oracle judges.
1. DONE b3 run2 compared with run1
2. DONE recorded move 2020 + string 2022/2023 (set_num withheld: SEV-1)
3. DONE see progress: mullion first-open recompute; follow-up: byte-level mullion record diff output vs original
4. DONE via b4 x3
5. DONE partly: twin ran to completion on 2021 4 of 4 times (num x2, rot x2) with the d1b8a61 judge; the exact hang case (2021 move twin) was not needed in b3/b4 (PASS without twin), so that specific hang stays untested
6. DONE no count change except 2 new year rows
7. DONE HANDOFF-c8x-rvtjudge.md updated
8. Report to orchestrator: dashboard records 2021 move/string param do not reproduce (decision)
9. DONE b4 x3 (see progress)
10. DONE finding + refactored patch and 5 tests ready (apply on host2 after b3 ends)
11. DONE lane3 up, waits 200-394 s per batch
12. DONE no new test possible; evidence appended to NEEDS-FROM-REVIT-LANE.md (2025 = no port on lane2/3)
13. DONE as tests/test_judge1_classify.py
14. PARTIAL ledger checked: 3 num cells (2020-22) PASS twice, same out sha; 2023 pending
15. DONE REPORT-c8x-rvtjudge2-b3-b4.md
## Round 2 (2026-11-17)
16. DONE twin on 2021 move completed (no hang), output == twin on all ids
17. DONE twin == output (see progress)
18. DONE twin == output on 2022 and 2023 move
19. DONE c8x-rvtjudge2-STATUS-FOR-USER.md
20. DONE 11 of 38 (year,sha) split PASS/FAIL, see progress
21. DONE deladd24 splits explained by judge-version changes (timestamps vs git log); wall_comove FAIL readback 1 of 3 at 01:53 not explained (PASS at 06:18, 5619 elements, 3/3)
## Round 3 (2026-11-17)
22. DONE wall_comove PASS 3/3 in both reruns (cumulative 4 PASS / 1 FAIL; the FAIL was a single early readback gap, not reproducible)
23. STARTED b5 run3 (host2 ~/c8x-judge/b5/run3.log): rot 2022, rot 2023, mark 2020, mark 2023 with TWIN_FORCE=1
24. DONE deladd24 PASS again (2 PASS in a row with the current judge; 19142 elements, only allowed ids differ)
25. Update STATUS-FOR-USER with 22-24
26. INVESTIGATE 2022 rotate FAIL (PipingSystem 730260 volume -> 0): class/connectors of 731025 (offline), does rotate have the connected-MEP guard, compare with move guard 342c408
27. Propose refusal of connected-MEP rotate (patch + test, host2 rvt-ballet), then re-judge 2022 rot: must refuse (no output) or pass with twin == output
28. DONE 1506 FamilyInstances with 3-6 MEP links in 2024 HVAC (Snowdon 42) were rotatable before the guard now refused; e.g. 1379283 (4 links), 1382194 (3), 1377544 (6)
29. STARTED b8: pre-guard product copy (~/c8x-judge/preguard = a16b5f8^) rotate 1379283 30 deg -> judged with TWIN_FORCE (host2 ~/c8x-judge/b8/run1.log)
