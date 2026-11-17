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
