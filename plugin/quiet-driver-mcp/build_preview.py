"""Build the plugin preview image from real captures.

Run from the plugin directory:  python3 build_preview.py
"""
from PIL import Image, ImageDraw
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SHOTS = "/tmp/quiet-driver/agent-probe-agent"


def newest_shot():
    if not os.path.isdir(SHOTS):
        return None
    files = sorted(f for f in os.listdir(SHOTS) if f.endswith(".png"))
    return os.path.join(SHOTS, files[-1]) if files else None


def main():
    W, H = 960, 540
    canvas = Image.new("RGB", (W, H), "#0d1526")
    d = ImageDraw.Draw(canvas)

    d.rounded_rectangle([30, 60, 470, 500], 10, fill="#132038", outline="#3f6fb5", width=2)
    d.text((50, 78), "the bound app, in the background", fill="#7fd1c4")
    shot = newest_shot()
    if shot and os.path.exists(shot):
        im = Image.open(shot).convert("RGB")
        im.thumbnail((400, 380))
        canvas.paste(im, (50, 105))

    d.rounded_rectangle([500, 60, 930, 500], 10, fill="#111b2e", outline="#3f6fb5", width=2)
    d.text((520, 78), "pointer and focus never move", fill="#8aa0bf")
    d.line([(520, 130), (900, 130)], fill="#263a5c", width=2)
    labels = [
        "frontmost: unchanged",
        "pointer: unchanged",
        "window order: unchanged",
        "focus events caused by driver: 0",
    ]
    for i, label in enumerate(labels):
        y = 158 + i * 46
        d.ellipse([522, y + 2, 534, y + 14], fill="#7fd1c4")
        d.text((548, y), label, fill="#c9d8ec")
    d.text((520, 370), "background mode", fill="#54749e")
    d.text((520, 392), "focused mode only on request", fill="#54749e")

    d.rectangle([0, H - 38, W, H], fill="#0a1120")
    d.text((30, H - 30), "Quiet Driver - background computer use", fill="#54749e")

    out = os.path.join(HERE, "docs", "preview.png")
    canvas.save(out)
    print("preview written:", out, os.path.getsize(out), "bytes")


if __name__ == "__main__":
    main()
