#!/usr/bin/env python3
"""Make an exact-WxH first-frame image from a source image, keeping aspect ratio.

Why: the Wan2.2 i2v pipeline derives the OUTPUT video resolution from the INPUT
image's aspect ratio (scaled to ~max_area), NOT from the request's `size` field.
So to get e.g. 1280x720 (16:9) output, feed a 1280x720 first-frame image. This
helper resizes any source image to an exact WxH while keeping aspect ratio.

Modes:
  cover   (default)  resize to FILL the target, then center-crop  -> exact WxH, no bars
  contain            resize to FIT inside the target, then pad     -> exact WxH, with bars

Usage:
  python3 make_i2v_image.py --src i2v_input.JPG --size 1280x720 --out i2v_1280x720.jpg
  python3 make_i2v_image.py --src in.jpg --size 1280x720 --mode contain --out out.jpg
"""
import argparse

from PIL import Image, ImageOps


def parse_size(s: str):
    for sep in ("x", "X", "*", "×"):
        if sep in s:
            w, h = s.split(sep, 1)
            return int(w), int(h)
    raise argparse.ArgumentTypeError(f"bad --size {s!r}; expected WxH e.g. 1280x720")


def main():
    ap = argparse.ArgumentParser(description="keep-ratio resize an image to an exact WxH")
    ap.add_argument("--src", required=True, help="source image path")
    ap.add_argument("--size", required=True, help="target WxH, e.g. 1280x720")
    ap.add_argument("--out", required=True, help="output image path")
    ap.add_argument("--mode", choices=["cover", "contain"], default="cover",
                    help="cover = fill + center-crop (no bars); contain = fit + pad (bars)")
    ap.add_argument("--pad-color", default="0,0,0", help="contain pad colour R,G,B (default 0,0,0)")
    args = ap.parse_args()

    W, H = parse_size(args.size)
    img = Image.open(args.src).convert("RGB")
    if args.mode == "cover":
        out = ImageOps.fit(img, (W, H), method=Image.LANCZOS, centering=(0.5, 0.5))
    else:
        color = tuple(int(c) for c in args.pad_color.split(","))
        out = ImageOps.pad(img, (W, H), method=Image.LANCZOS, color=color, centering=(0.5, 0.5))
    out.save(args.out, quality=95)
    print(f"{args.src} {img.size[0]}x{img.size[1]} -> {args.out} "
          f"{out.size[0]}x{out.size[1]} (mode={args.mode})")


if __name__ == "__main__":
    main()
