# Deploy dwg-ballet with the Rust scene fast path on host3 (staged by c8-perf, 2026-10-27)
Staged copy: ~/dwg-ballet-staged (git archive of host2 ~/dwg-viewer branch start-page e8685e9+, plus dwgfast.abi3.so and dwgscene_fast.abi3.so from host2, Linux x86_64).
Verified on host3 (capped 2 GB, niced): tools/smoke.py on AC1021_10 -> SMOKE OK, fast path module loads.
To deploy (owner c8-native / orchestrator; the install is the user's daily driver, so do it when the viewer is not in use):
  rsync -a --delete --exclude='__pycache__' ~/dwg-ballet-staged/ ~/.local/share/dwg-ballet/     (check first that the install has no local-only files: diff -rq)
Rollback: the pure-Python path needs no .so (DWG_NO_FAST=1 disables the native code at runtime).

diff -rq (2026-10-27): the install differs from the staged copy ONLY in my changes (build.py, cache.py, clip.py, flat.py, server.py, .gitignore, new fastflat.py, spawnpool.py, dwgscene_fast_src/, and the two .so files); there are no local-only files in the install, so rsync without --delete risk is nil and --delete is safe.

## Note from c8x-regress (2026-11-04): the staged copy is stale for SAVE safety
~/dwg-ballet-staged is an old archive of host2 start-page (it lacks e.g. the objs_prefix fix, host2's AC1015/AC1018+ output guards, memguard, check_name). None of my fixes are in host2 start-page yet; they live only on ~/src/dwg-viewer-regress branch c3x-regress (43 commits on top of origin/start-page: handle_map_damage, HANDSEED never lowered, honest rescue-restore message, test guards + synthetic tests). Before enabling overwrite on host3: re-archive start-page (with these commits), put savegate c8x-regress/merge3 on the import path, then run the 99-test regress set (see HANDOFF-c8x-regress.md).
