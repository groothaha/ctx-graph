"""Turn recorded frames (test action rec:) into the README demo GIF/MP4: adds a cursor and captions.

    python3 tools/compose_demo.py <frames dir> <out base> --lang en|ko [--hover x,y] [--off x,y]

The frame timeline matches the test-action script in docs/DEVELOPMENT.md (10 fps):
hover at frame 13, cursor leaves at 65, the message is sent at ~97.
"""
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

CAPTIONS = {
    "en": [(0, 12, "Each line carries one Claude Code conversation's context into another"),
           (13, 66, "Hover a line to see what will flow next"),
           (72, 999, "Send a message in Frontend → just the changes flow in")],
    "ko": [(0, 12, "선 = 한 대화의 맥락이 다른 대화로 흘러가는 길"),
           (13, 66, "선에 마우스를 올리면 다음에 흘러갈 내용이 보여요"),
           (72, 999, "프런트엔드에서 메시지를 보내면 → 바뀐 부분만 흘러 들어가요")],
}
CURSOR = [(0, 0), (0, 17), (4, 13), (7, 20), (10, 19), (7, 12), (12, 12)]


def ease(k: float) -> float:
    return 2 * k * k if k < 0.5 else 1 - (-2 * k + 2) ** 2 / 2


def cursor_at(i: int, hover, off, rest):
    path = [(0, rest), (6, rest), (13, hover), (62, hover), (67, off), (999, off)]
    for (fa, a), (fb, b) in zip(path, path[1:]):
        if fa <= i <= fb:
            k = ease((i - fa) / max(1, fb - fa))
            return (a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k)
    return off


def main() -> None:
    src, out = Path(sys.argv[1]), Path(sys.argv[2])
    lang = sys.argv[sys.argv.index("--lang") + 1] if "--lang" in sys.argv else "en"
    pt = lambda flag, d: tuple(map(float, sys.argv[sys.argv.index(flag) + 1].split(","))) if flag in sys.argv else d
    hover, off, rest = pt("--hover", (689, 236)), pt("--off", (470, 610)), (560, 560)
    font = ImageFont.truetype("/System/Library/Fonts/AppleSDGothicNeo.ttc", 19)
    frames = sorted(src.glob("f*.png"))
    tmp = out.parent / (out.name + "-frames")
    tmp.mkdir(parents=True, exist_ok=True)
    for i, f in enumerate(frames):
        im = Image.open(f).convert("RGBA")
        d = ImageDraw.Draw(im, "RGBA")
        if i < 75:                                     # 커서는 엿보기 장면까지만
            x, y = cursor_at(i, hover, off, rest)
            d.polygon([(x + px, y + py) for px, py in CURSOR], fill=(255, 255, 255, 255), outline=(0, 0, 0, 255))
        text = next((t for a, b, t in CAPTIONS[lang] if a <= i <= b), None)
        if text:
            w = d.textlength(text, font=font)
            W, H = im.size
            cx = (280 + W) / 2                         # 사이드바(280pt) 오른쪽, 그래프 칸 가운데 — 확대 버튼과 안 겹치게
            box = (cx - w / 2 - 16, H - 58, cx + w / 2 + 16, H - 22)
            d.rounded_rectangle(box, radius=10, fill=(12, 13, 17, 215))
            d.text((cx - w / 2, H - 52), text, font=font, fill=(242, 242, 244, 255))
        im.convert("RGB").save(tmp / f"c{i:04d}.png")
    last = len(frames) - 1
    for k in range(1, 16):                             # 끝 장면을 1.5초 더
        (tmp / f"c{last + k:04d}.png").write_bytes((tmp / f"c{last:04d}.png").read_bytes())
    pattern = str(tmp / "c%04d.png")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "10", "-i", pattern,
                    "-vf", "scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];"
                           "[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle",
                    "-loop", "0", str(out) + ".gif"], check=True)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "10", "-i", pattern,
                    "-vf", "scale=1100:-2:flags=lanczos,fps=30", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                    "-crf", "20", "-movflags", "+faststart", str(out) + ".mp4"], check=True)
    print(out.with_suffix(".gif"), out.with_suffix(".mp4"))


if __name__ == "__main__":
    main()
