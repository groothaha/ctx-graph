#!/usr/bin/env python3
"""en.py → en.lproj/Localizable.strings (ko 는 키가 곧 한국어라 빈 표).
인자로 컴파일러가 뽑은 .stringsdata 폴더를 주면 빠진 번역·형식 지정자 불일치도 검사한다:
  mkdir -p /tmp/strings && swift build -c release --build-path /tmp/b -Xswiftc -emit-localized-strings \\
      -Xswiftc -emit-localized-strings-path -Xswiftc /tmp/strings
  python3 build_strings.py /tmp/strings
"""
import json, pathlib, re, sys
HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from en import EN, EXPLICIT, PLURALS

SPEC = re.compile(r"%(?:\d+\$)?(?:@|lld|ld|d|lu|llu|lf|f|g|lg)")
HANGUL = re.compile(r"[\uac00-\ud7a3]")

def esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

bad = [k for k, v in EN.items() if sorted(SPEC.findall(k)) != sorted(SPEC.findall(v))]
bad += [k for k in PLURALS if k not in EN]
if bad:
    sys.exit("형식 지정자가 다름: " + "; ".join(bad))
if len(sys.argv) > 1:
    src = {p.name for p in (HERE.parent / "Sources" / "CtxGraph").glob("*.swift")}
    keys = set()
    for f in pathlib.Path(sys.argv[1]).glob("*.stringsdata"):
        d = json.loads(f.read_text())
        if pathlib.Path(d["source"]).name in src:
            for t in d["tables"].values():
                keys |= {e["key"] for e in t}
    if not keys:
        sys.exit(f"{sys.argv[1]} 에 .stringsdata 가 없어요 (swift build 가 실패했거나 폴더가 없었어요 — 먼저 mkdir -p)")
    missing = sorted(k for k in keys if HANGUL.search(k) and k not in EN)
    unused = sorted(k for k in EN if k not in keys)
    print(f"keys {len(keys)} · 번역 {len(EN)} · 빠짐 {len(missing)} · 안 쓰임 {len(unused)}")
    for k in missing:
        print("  빠짐:", k)
    if missing:
        sys.exit(1)
for lang in ("en", "ko"):
    d = HERE / f"{lang}.lproj"
    d.mkdir(exist_ok=True)
    table = dict(EN) if lang == "en" else {}
    table.update({k: (ko if lang == "ko" else en) for k, (ko, en) in EXPLICIT.items()})
    body = "".join(f'"{esc(k)}" = "{esc(v)}";\n' for k, v in sorted(table.items()))
    if lang == "en":
        from xml.sax.saxutils import escape as xesc
        items = []
        for k, (one, other) in sorted(PLURALS.items()):
            spec = "lld"
            pre = k.split("%lld")[0]
            fmt = ("%@ · " if pre.startswith("%@") else "") + "%#@n@"
            if pre.startswith("%@"):
                one, other = one.split("%@ · ", 1)[1], other.split("%@ · ", 1)[1]
            items.append(f"<key>{xesc(k)}</key><dict><key>NSStringLocalizedFormatKey</key><string>{xesc(fmt)}</string>"
                         f"<key>n</key><dict><key>NSStringFormatSpecTypeKey</key><string>NSStringPluralRuleType</string>"
                         f"<key>NSStringFormatValueTypeKey</key><string>{spec}</string>"
                         f"<key>one</key><string>{xesc(one)}</string><key>other</key><string>{xesc(other)}</string></dict></dict>")
        (d / "Localizable.stringsdict").write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
            '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>' + "".join(items) + "</dict></plist>\n")
    (d / "Localizable.strings").write_text("/* CtxGraph — build_strings.py 가 만듦 */\n" + body)
    usage = ("Controls Terminal to continue a conversation there." if lang == "en"
             else "대화를 터미널에서 이어서 열 때 Terminal 을 제어합니다.")
    (d / "InfoPlist.strings").write_text(f'"NSAppleEventsUsageDescription" = "{esc(usage)}";\n')
print("ok")
