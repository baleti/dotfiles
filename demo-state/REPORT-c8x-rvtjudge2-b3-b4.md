# judge1 repeat batches b3 (x2) and b4 (x3), host2 lane3, 2026-11-17 (c8x-rvtjudge2)
Same output bytes in every batch (sha per cell), real Revit 2020-2023 VM oracle, Revit-made twin rule, control noise floor.

| cell | output sha | PASS / FAIL (b3 x2 + b4 x3, plus earlier y3/b2 where known) |
|---|---|---|
| move 2020 | b1ec03dcadf7 | 5 / 0 in b3+b4 (flapped in earlier y3/b2) |
| mark 2021 | 4afb3eb33fe8 | 6 / 1 (b3 x2 PASS, b4 x3 PASS; FAIL = b2 output-only unstable id) |
| move 2021 | a8bc3fa67bb5 | 6 / 1 (FAIL = b2) |
| rotate 2021 | 6997d2102c79 | 3 / 2 (FAIL b3 run1+run2: id 574552 mullion unstable only in the output; PASS b4 x3 via control noise) |
| set_num 2020-23, mark 2022-23, rot 2020 | various | 2 / 0 each (b3 only) |

Findings
1. No run shows damage from our writer. Offline: only the edited element (403379) changes in the 2021 rotate output; the mullion record 574552 is byte-identical to the original (136 fields, 0 diffs).
2. The 2021 sample's Revit control is noisy (a different element flaps per run: 573581, 574552, 573553). Verdicts on identical bytes alternate depending on which element flaps. A single-run PASS/FAIL on 2021 is not evidence.
3. Rule hole closed: the transient first-open path required no twin; now it does (rvt-ballet 81d925d, 5 tests). 
4. Dashboard: recorded move 2020 (family instance) and string parameter 2022/2023. Not recorded: set_num (SEV-1 row), 2021 cells (noisy), rotate 2020 (item missing in matrix.json).
5. Honest limit: the FAIL on 2021 rotate was produced with the pre-81d925d judge; the b4 PASSes with the patched judge came through the control-noise rule, not the twin rule.
Open decisions: c8x-rvtjudge2-DECISIONS.md

## Addendum b5 (TWIN_FORCE=1, evidence only, 4 cells)
2021 move, 2021 rotate, 2022 move, 2023 move: all PASS and the Revit-made twin (same API edit applied inside Revit to the unedited file) equals our output on every id outside the allowed list (TWINFORCE: []). The 2021 move twin, which hung 3 of 3 before the d1b8a61 fix, completed (230 s lock). Knob: rvt-ballet 0e01ee9.
