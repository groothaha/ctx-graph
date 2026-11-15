"""Swift 소스의 한글 문자열 리터럴을 찾고, 컴파일러가 뽑은 번역 키(stringsdata)에 잡혔는지 본다."""
import json, re, sys, pathlib
HANGUL = re.compile(r'[가-힣]')
SRC = pathlib.Path(sys.argv[1]); STR = pathlib.Path(sys.argv[2])

def literals(text):
    """(start, end, raw_inner, nested) — 일반 "..." 리터럴만 (\"\"\" 는 건너뜀). 보간 안의 리터럴도."""
    out, i, n = [], 0, len(text)
    def parse_string(i, nested):
        # text[i] == '"'
        start = i; i += 1; buf_start = i
        while i < n:
            c = text[i]
            if c == '\\':
                if i + 1 < n and text[i+1] == '(':
                    i += 2; depth = 1
                    while i < n and depth:
                        c2 = text[i]
                        if c2 == '"':
                            i = parse_string(i, True); continue
                        if c2 == '(': depth += 1
                        elif c2 == ')': depth -= 1
                        i += 1
                    continue
                i += 2; continue
            if c == '"':
                out.append((start, i + 1, text[buf_start:i], nested))
                return i + 1
            if c == '\n':
                return i
            i += 1
        return i
    while i < n:
        if text.startswith('//', i):
            j = text.find('\n', i); i = n if j < 0 else j; continue
        if text.startswith('/*', i):
            j = text.find('*/', i); i = n if j < 0 else j + 2; continue
        if text.startswith('"""', i):
            j = text.find('"""', i + 3); i = n if j < 0 else j + 3; continue
        if text[i] == '"':
            i = parse_string(i, False); continue
        i += 1
    return out

def to_pattern(raw):
    """리터럴 안쪽 → 키 정규식 (보간은 %@ %lld %lf 등)"""
    parts, i, n = [], 0, len(raw)
    lit = []
    def flush():
        if lit: parts.append(re.escape(''.join(lit))); lit.clear()
    while i < n:
        c = raw[i]
        if c == '\\' and i + 1 < n:
            d = raw[i+1]
            if d == '(':
                flush(); i += 2; depth = 1; inq = False
                while i < n and depth:
                    if raw[i] == '"': inq = not inq
                    elif not inq and raw[i] == '(': depth += 1
                    elif not inq and raw[i] == ')': depth -= 1
                    i += 1
                parts.append(r'%(?:\d+\$)?(?:@|lld|ld|d|lu|llu|lf|f|g|lg)')
                continue
            lit.append({'n': '\n', 't': '\t', '"': '"', '\\': '\\', "'": "'", '0': '\0'}.get(d, d)); i += 2; continue
        if c == '%':
            lit.append('%%'); i += 1; continue      # 키에서는 % 가 %% 로 이스케이프됨 (보간 있을 때)
        lit.append(c); i += 1
    flush()
    return ''.join(parts)

keys = set()
for f in STR.glob('*.stringsdata'):
    d = json.loads(f.read_text())
    for t in d.get('tables', {}).values():
        for e in t:
            keys.add(e['key'])
covered, missing = 0, []
for f in sorted(SRC.glob('*.swift')):
    text = f.read_text()
    for s, e, raw, nested in literals(text):
        if not HANGUL.search(raw): continue
        pat = to_pattern(raw)
        pat2 = pat.replace('%%', '%')      # 보간 없는 키는 % 를 그대로 둠
        ok = any(re.fullmatch(pat, k) or re.fullmatch(pat2, k) for k in keys)
        line = text.count('\n', 0, s) + 1
        if ok: covered += 1
        else: missing.append((f.name, line, s, e, raw))
print(f"covered {covered}, missing {len(missing)}", file=sys.stderr)
json.dump([{"file": m[0], "line": m[1], "start": m[2], "end": m[3], "raw": m[4]} for m in missing],
          sys.stdout, ensure_ascii=False, indent=0)
