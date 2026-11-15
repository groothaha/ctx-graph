import json, pathlib, re, sys
L = pathlib.Path(sys.argv[1]); mode = sys.argv[2]
exec(open(L / "scan.py").read().split("keys = set()")[0])     # literals()
H = re.compile(r'[가-힣]')
orig = pathlib.Path.home() / "ctx-graph/app/Sources/CtxGraph"
marked = L / "mark/app/Sources/CtxGraph"
if mode == "mark":
    index = []
    for f in sorted(orig.glob("*.swift")):
        t = f.read_text(); ops = []
        for s, e, raw, nested in literals(t):
            if H.search(raw):
                n = len(index); index.append({"file": f.name, "start": s, "end": e, "raw": raw})
                ops.append((e - 1, f"⟦{n}⟧"))
        for pos, ins in sorted(ops, key=lambda o: -o[0]):
            t = t[:pos] + ins + t[pos:]
        (marked / f.name).write_text(t)
    json.dump(index, open(L / "mark_index.json", "w"), ensure_ascii=False)
    print("marked", len(index))
else:
    index = json.load(open(L / "mark_index.json"))
    found = set()
    for f in (L / "mark/strings").glob("*.stringsdata"):
        for t in json.loads(f.read_text())["tables"].values():
            for e in t:
                found |= {int(x) for x in re.findall(r"⟦(\d+)⟧", e["key"])}
    miss = [x for i, x in enumerate(index) if i not in found]
    json.dump(miss, open(L / "missing_occ.json", "w"), ensure_ascii=False, indent=0)
    print("occurrences", len(index), "localized", len(found), "missing", len(miss))
    for x in miss:
        line = (orig / x["file"]).read_text()[:x["start"]].count("\n") + 1
        print(f'  {x["file"]}:{line}  {x["raw"][:70]}')
