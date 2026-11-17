# Decisions needed from the orchestrator (c8x-rvtjudge2, 2026-11-17)
1. Dashboard PASS rows "family instance move 2021" / "string parameter 2021" (c4x-rvteditopus 11-15): do not reproduce (y3 PASS, b2 FAIL, b3 PASS x2). Same bytes flap across batches (curtain mullion first-open hash). Keep, retract, or mark "flaky"? Not overwritten by me.
2. 2021 rotate: reproducible FAIL (b3 x2). Element 574552 is a mullion; its stored record is byte-identical to the original; only the rotated element 403379 changed in our output. First open of output gives hash 0fa1eb08, second open and the Revit-made twin give 1e738e69 (= control). Revit recompute on first open; rule refuses it. Accept as "transient first-open" for mullions or keep FAIL? I kept FAIL.
3. Item "rotate family instance" is not in matrix.json category 1 (ledger has older rows for it). Rotate 2020 passes 2 of 2 in b3 but is unrecorded. Add item or RVT_EDIT_FORCE?
4. "number parameter" stays FAIL (SEV-1 stale derived geometry). My set_num 2020-2023 passes edit a view Detail Level only; not recorded so as not to hide the SEV-1.
5. judge1 now requires a twin for the transient rule (rvt-ballet 81d925d).
