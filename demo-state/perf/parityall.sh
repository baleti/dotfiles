#!/bin/sh
# full corpus parity, native vs python flatten, one file at a time (big ones included); writes demo-state/perf/parity_all.txt
cd $HOME/dwg-ballet-staged
: > $HOME/demo-state/perf/parity_all.txt
for f in $(ls -S $HOME/dwg-research/corpus/*.dwg | tail -n +7); do
  PYTHONPATH=. systemd-run --user --scope -q -p MemoryMax=3G -p MemorySwapMax=0 nice -n 19 timeout 1500 python3 tools/fastparity.py $f 2>&1 | tail -1 | cut -c1-200 >> $HOME/demo-state/perf/parity_all.txt
done
echo DONE >> $HOME/demo-state/perf/parity_all.txt
