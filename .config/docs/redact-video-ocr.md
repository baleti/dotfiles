# redact-video-ocr

`~/bin/redact-video-ocr` — standalone Python CLI that blurs sensitive
on-screen text out of a video automatically, driven by OCR rather than by
manually reviewing footage frame by frame. Built after a screen-recording
demo turned out to have live, unintended data visible on screen that needed
blurring before the recording could be published (e.g. on this docs site).
Reusable for any future recording with the same problem.

## Why OCR instead of eyeballing frames

The obvious way to redact a handful of moving, reflowing bits of text in a
video is to extract frames, look at each one, and hand-tune blur
coordinates until they line up. That does not scale: it turns into a
frame-by-frame trial-and-error loop, and every frame you *look at* to
verify alignment is expensive when the thing doing the looking is an LLM's
vision channel rather than a script.

`redact-video-ocr` replaces the "look at the frame" step with Tesseract
OCR. Nothing about the pipeline requires a human or a model to inspect
individual frames — it is plain, repeatable, and just as usable for a
30-second clip as for a 30-minute one.

## How it works

1. OpenCV (`cv2.VideoCapture`) reads frames one at a time, in memory — no
   frames are dumped to disk as intermediate PNGs.
2. Each frame is upscaled (`--scale`, default 3x) before OCR, since small
   UI/terminal-style text at native 1080p is often below the size Tesseract
   reads reliably.
3. `pytesseract.image_to_data` runs with **two page-segmentation modes**
   merged (`--psm`, default `3,11`): mode 3 (fully automatic layout) is
   better at dense, tabular text; mode 11 (sparse text) is better at short,
   scattered UI labels. Neither mode alone catches everything a screen
   recording tends to contain, so both run and their hits are merged.
4. OCR word boxes on the same line are grouped and matched against a
   stems list (see below) with three rules, since real on-screen text is
   noisy in three different directions:
   - the stem is a clean prefix of the OCR text,
   - the stem is embedded inside a longer garbled OCR token (Tesseract
     often fuses adjacent glyphs/decorations into one run-on word), or
   - the OCR text is itself a short, *truncated* prefix of the stem — the
     direction that matters when on-screen text gets cut off with an
     ellipsis (e.g. a name truncated to its first few letters because a
     panel is narrow). Matching only "stem is a prefix of the text" misses
     this entirely; it has to also check "text is a prefix of the stem".
   - adjacent OCR words on a line are also tried as 2-4 word windows, so a
     stem phrase that Tesseract splits into multiple words still matches.
5. Matched regions get a Gaussian blur applied directly to the frame
   (kernel size scales with the box), then frames are piped straight into
   an `ffmpeg` subprocess for the final encode. No blurred/unblurred frame
   ever touches disk as an intermediate file either.

### The stems file

`--words` points at a plain text file: one word or phrase per line,
case-insensitive, `#` starts a comment, and a trailing `!` marks a stem
whole-word-only (useful for a short, common-ish stem that would otherwise
also match as a prefix of an unrelated word). This file is specific to
whatever is being redacted in a given video — the redaction tool itself
has no built-in list of what "sensitive" means.

### `--debug-dir`

Writes every frame with red boxes drawn around what would be blurred
(without actually blurring), so the detection can be reviewed before
committing to a run. Cheap insurance against both under- and
over-redaction, and doesn't require re-running OCR to check coverage.

## Requirements

A dedicated venv, since the system Python here is externally managed:

```sh
python3 -m venv ~/.cache/video-redact-venv
~/.cache/video-redact-venv/bin/pip install opencv-python-headless pytesseract
```

Plus the `tesseract` binary and `ffmpeg` on `PATH`. The script's shebang
points directly at the venv's interpreter, so once the venv exists it runs
as a plain executable:

```sh
redact-video-ocr input.mp4 output.mp4 --words stems.txt
```

## Known limitation

Text the source application itself renders as visually de-emphasized —
dim/low-contrast styling, especially combined with a strikethrough — can
still evade OCR even after upscaling, contrast normalization, and gamma
correction. None of those recovered it in testing. There's no fix wired
into the tool for this yet, so **always do a final small spot-check** (a
handful of frames spread across the whole timeline, not a frame-by-frame
loop) on the actual output before treating a redaction as complete,
specifically looking for any text the source app styles as muted/faded/
struck-through.
