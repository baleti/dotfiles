#!/usr/bin/env python3
"""Make cached 256px JPEG thumbnails for remote photos (rclone cat -> resize).
usage: thumb.py REMOTE [REMOTE ...]   (already-cached thumbs are skipped)"""
import hashlib, os, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cv2, numpy as np
import config
THUMBS = os.path.join(config.DATA_DIR, "thumbs")
def path_for(remote):
    return os.path.join(THUMBS, hashlib.sha1(remote.encode()).hexdigest()[:16] + ".jpg")
def main():
    os.makedirs(THUMBS, exist_ok=True)
    for remote in sys.argv[1:]:
        dst = path_for(remote)
        if os.path.exists(dst): continue
        data = subprocess.run(["rclone", "cat", remote], capture_output=True).stdout
        img = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
        if img is None: continue
        h, w = img.shape[:2]; s = 256 / max(h, w)
        img = cv2.resize(img, (max(1, round(w * s)), max(1, round(h * s))), interpolation=cv2.INTER_AREA)
        cv2.imwrite(dst, img, [cv2.IMWRITE_JPEG_QUALITY, 85])
if __name__ == "__main__":
    main()
