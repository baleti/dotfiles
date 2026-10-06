#!/bin/sh
# launches the face worker with the CUDA 12 pip runtime libs on LD_LIBRARY_PATH
SP=$HOME/indexer/venv/lib/python3.13/site-packages/nvidia
LD_LIBRARY_PATH=$(ls -d $SP/*/lib | paste -sd:) exec $HOME/indexer/venv/bin/python $HOME/indexer/worker.py
