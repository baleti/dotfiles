#!/bin/sh
# Throw-away CLIP container on host1: tar of images on stdin -> JSON lines on stdout. Same GPU plumbing as ai1-imagechat.container.
# Runs on GPU 1 (the imagechat one); if its VRAM is full the worker falls back to the CPU provider by itself.
N=/home/user1/ai1-native; L=/usr/lib/x86_64-linux-gnu/nvidia/current; V=550.163.01
exec podman run --rm -i --userns=keep-id --read-only --cap-drop=ALL --security-opt no-new-privileges --tmpfs /tmp \
  --memory=3g --memory-swap=3g --pids-limit=256 --network=none \
  -v $N:/ai1:ro \
  --device /dev/nvidia0 --device /dev/nvidia1 --device /dev/nvidiactl --device /dev/nvidia-uvm --device /dev/nvidia-uvm-tools \
  -v $L/libcuda.so.$V:/lib/x86_64-linux-gnu/libcuda.so.1:ro -v $L/libnvidia-ml.so.$V:/lib/x86_64-linux-gnu/libnvidia-ml.so.1:ro \
  -v $L/libnvidia-ptxjitcompiler.so.$V:/lib/x86_64-linux-gnu/libnvidia-ptxjitcompiler.so.1:ro -v $L/libnvidia-cfg.so.$V:/lib/x86_64-linux-gnu/libnvidia-cfg.so.1:ro \
  -e HOME=/tmp -e PYTHONDONTWRITEBYTECODE=1 -e CUDA_VISIBLE_DEVICES=GPU-34fa59f3-c981-252b-54b4-8bae0813adfe \
  -e LD_LIBRARY_PATH="$(ls -d $N/clip-venv/lib/python3.13/site-packages/nvidia/*/lib | sed "s#$N#/ai1#" | paste -sd:)" \
  localhost/ai1-runtime:latest /ai1/clip-venv/bin/python /ai1/src/clip-worker/clip_worker_pod.py
