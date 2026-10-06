#!/bin/sh
SP=$HOME/indexer/venv/lib/python3.13/site-packages/nvidia
LD_LIBRARY_PATH=$(ls -d $SP/*/lib | paste -sd:) exec $HOME/indexer/venv/bin/python $HOME/indexer/clip_worker.py
