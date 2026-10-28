#!/bin/sh
# host3: pull the Recoll indexes built on host1 (cad_index_host1.py) into ~/.cache/indexes/{revit,dwg}/recoll (atomic swap per index)
set -e
for k in revit dwg; do
  d=$HOME/.cache/indexes/$k/recoll; mkdir -p "$d"
  rsync -a --delete host1:.cache/indexes/$k/recoll/xapiandb/ "$d/xapiandb.new/"
  rsync -a host1:.cache/indexes/$k/recoll/recoll.conf host1:.cache/indexes/$k/recoll/mimemap host1:.cache/indexes/$k/recoll/mimeconf "$d/"
  rm -rf "$d/xapiandb.old"; [ -d "$d/xapiandb" ] && mv "$d/xapiandb" "$d/xapiandb.old"; mv "$d/xapiandb.new" "$d/xapiandb"; rm -rf "$d/xapiandb.old"
done
