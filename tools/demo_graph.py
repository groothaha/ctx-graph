"""Demo graph with made-up conversations — for screenshots, the README GIF and UI checks.

    python3 tools/demo_graph.py <empty dir> [--lang en|ko]

Creates
  <dir>/home   a fake HOME whose ~/.claude/projects holds the demo transcripts (so the sidebar lists only these)
  <dir>/data   a CtxGraph data folder (CTXGRAPH_HOME) with the graph
  <dir>/send-frontend.json   hook input for "the user sends a message in Frontend" (pipe it into `ctxgraph.py hook`)

Graph: Backend API → Frontend ← Design review, Frontend → Release notes.
Backend API has v3 ready (only the changes will go in with Frontend's next message); the rest is up to date.
Run the app with:  HOME=<dir>/home CFFIXED_USER_HOME=<dir>/home CTXGRAPH_HOME=<dir>/data
"""
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEXT = {
    "en": {
        "api": ("Backend API", [("U", "Move the login endpoint to v2 and switch tokens to httpOnly cookies"),
                                ("A", "Done — /v2/auth/login now sets an httpOnly cookie and errors return { code, message }.")]),
        "design": ("Design review", [("U", "Review the login screen mockups"), ("A", "Buttons at 36px, error text in gray with an icon.")]),
        "web": ("Frontend", [("U", "Switch the product list to infinite scroll"), ("A", "Done, using IntersectionObserver.")]),
        "notes": ("Release notes", [("U", "Draft the release notes for this sprint"), ("A", "Here's a first draft.")]),
        "flaky": ("Fix flaky checkout test", [("U", "The checkout test fails one run in ten"), ("A", "It races the payment mock; fixed.")]),
        "pay": ("Refactor payment module", [("U", "Split payment.ts into smaller files"), ("A", "Split into 4 modules.")]),
        "docs": ("Write onboarding docs", [("U", "Write a getting-started guide"), ("A", "Draft is in docs/start.md.")]),
        "api_sum": "## Decisions\n- Login moved to /v2/auth/login — tokens are httpOnly cookies now\n- Errors use one shape: { code, message }\n"
                   "- Rate limit: 20 requests/min per IP\n- Password reset comes next",
        "api_delta": "- Login moved to /v2/auth/login — tokens are httpOnly cookies now\n- Errors use one shape: { code, message }\n"
                     "- Rate limit: 20 requests/min per IP",
        "design_sum": "- Buttons: 36px tall, 8px corner radius\n- Error text is gray with an icon, not red\n"
                      "- Login screen: email first, social sign-in below",
        "web_sum": "- Product list uses infinite scroll (IntersectionObserver)\n- Login screen is next",
        "space2": "Docs",
        "prompt": "Hook up the login screen to the new API",
    },
    "ko": {
        "api": ("Backend API", [("U", "로그인 API 를 v2 로 옮기고 토큰은 httpOnly 쿠키로"),
                                ("A", "옮겼어요 — /v2/auth/login 이 httpOnly 쿠키를 주고, 오류는 { code, message } 로 와요.")]),
        "design": ("디자인 리뷰", [("U", "로그인 화면 시안 리뷰"), ("A", "버튼 높이 36, 오류 문구는 회색 + 아이콘으로 가죠.")]),
        "web": ("프런트엔드", [("U", "상품 목록을 무한 스크롤로 바꿔줘"), ("A", "바꿨어요. IntersectionObserver 를 써요.")]),
        "notes": ("릴리스 노트", [("U", "이번 스프린트 릴리스 노트 초안"), ("A", "초안을 썼어요.")]),
        "flaky": ("결제 테스트 가끔 실패", [("U", "결제 테스트가 열 번에 한 번 실패해"), ("A", "결제 모의 객체와 경쟁 상태였어요. 고쳤어요.")]),
        "pay": ("결제 모듈 정리", [("U", "payment.ts 를 작은 파일로 나눠줘"), ("A", "모듈 4개로 나눴어요.")]),
        "docs": ("온보딩 문서 쓰기", [("U", "시작하기 문서를 써줘"), ("A", "docs/start.md 에 초안을 썼어요.")]),
        "api_sum": "## 정한 것\n- 로그인 API 를 /v2/auth/login 으로 옮김 — 토큰은 httpOnly 쿠키\n- 실패 응답은 { code, message } 형식으로 통일\n"
                   "- 레이트 리밋: 같은 IP 분당 20회\n- 비밀번호 재설정은 다음 단계",
        "api_delta": "- 로그인 API 를 /v2/auth/login 으로 옮김 — 토큰은 httpOnly 쿠키\n- 실패 응답은 { code, message } 형식으로 통일\n"
                     "- 레이트 리밋: 같은 IP 분당 20회",
        "design_sum": "- 버튼 높이 36 · 모서리 8 로 통일\n- 오류 문구는 빨강 대신 회색 + 아이콘\n- 로그인 화면은 이메일 먼저, 소셜은 아래로",
        "web_sum": "- 상품 목록은 무한 스크롤 (IntersectionObserver)\n- 다음은 로그인 화면",
        "space2": "문서",
        "prompt": "로그인 화면에 새 API 붙여줘",
    },
}
IDS = {k: f"d0a1b2c3-0000-4000-8000-0000000000{i:02d}" for i, k in enumerate(
    ["api", "design", "web", "notes", "flaky", "pay", "docs"], start=1)}
CWD = {"api": "shop/api", "design": "shop/design", "web": "shop/web", "notes": "shop",
       "flaky": "shop/web", "pay": "shop/api", "docs": "shop/docs"}
AGE = {"api": 180, "design": 3600, "web": 720, "notes": 1500, "flaky": 5400, "pay": 26000, "docs": 90000}


def main() -> None:
    out = Path(sys.argv[1]).resolve()
    lang = sys.argv[sys.argv.index("--lang") + 1] if "--lang" in sys.argv else "en"
    t = TEXT[lang]
    home, data = out / "home", out / "data"
    home.mkdir(parents=True, exist_ok=True)
    now = time.time()
    paths = {}
    for key, sid in IDS.items():
        cwd = str(home / CWD[key])
        Path(cwd).mkdir(parents=True, exist_ok=True)
        proj = home / ".claude" / "projects" / re.sub(r"[^A-Za-z0-9]", "-", cwd)
        proj.mkdir(parents=True, exist_ok=True)
        p = proj / f"{sid}.jsonl"
        title, turns = t[key]
        mtime = now - AGE[key]
        lines = [json.dumps({"type": "ai-title", "aiTitle": title, "sessionId": sid}, ensure_ascii=False, separators=(",", ":"))]
        for i, (r, text) in enumerate(turns):
            ts = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(mtime - 300 + i * 60))
            d = ({"type": "user", "message": {"role": "user", "content": text}, "origin": {"kind": "human"}} if r == "U" else
                 {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}})
            d.update(timestamp=ts, cwd=cwd, sessionId=sid)
            lines.append(json.dumps(d, ensure_ascii=False, separators=(",", ":")))
        p.write_text("\n".join(lines) + "\n")
        os.utime(p, (mtime, mtime))
        paths[key] = p

    env = {**{k: v for k, v in os.environ.items() if not k.startswith(("CLAUDE", "CTXGRAPH"))},
           "HOME": str(home), "CTXGRAPH_HOME": str(data), "CTXGRAPH_LANG": lang}
    script = os.environ.get("CTXGRAPH_SCRIPT") or str(ROOT / "bin" / "ctxgraph.py")
    subprocess.run([sys.executable, "-I", script, "init"], env=env, check=True)
    subprocess.run([sys.executable, "-I", script, "scan"], env=env, check=True, capture_output=True)

    con = sqlite3.connect(str(data / "graph.sqlite"))
    pos = {"api": (330, 190), "design": (330, 420), "web": (700, 300), "notes": (700, 520), "docs": (400, 300)}
    summ = {"api": (t["api_sum"], t["api_delta"], 3, 200), "design": (t["design_sum"], None, 2, 3700),
            "web": (t["web_sum"], None, 1, 800)}
    for key in ("api", "design", "web", "notes", "docs"):
        s, d, v, age = summ.get(key, (None, None, 0, None))
        size = paths[key].stat().st_size if v else 0
        con.execute("INSERT OR REPLACE INTO nodes(session_id, transcript_path, cwd, x, y, summary, delta, summary_version,"
                    " summary_at, summary_src_size, summary_src_at, added_at, space) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (IDS[key], str(paths[key]), str(home / CWD[key]), *pos[key], s, d, v,
                     now - age + 20 if age else None, size, now - age if age else None, now - 9000,
                     "docs" if key == "docs" else "main"))
        con.execute("INSERT OR REPLACE INTO placements(session_id, space, x, y, added_at) VALUES(?,?,?,?,?)",
                    (IDS[key], "docs" if key == "docs" else "main", *pos[key], now - 9000))
    con.execute("INSERT OR IGNORE INTO spaces(id, name, sort, created_at) VALUES('docs', ?, 1, ?)", (t["space2"], now - 9000))
    for a, b in (("api", "web"), ("design", "web"), ("web", "notes")):
        con.execute("INSERT OR IGNORE INTO links(src, dst, created_at) VALUES(?,?,?)", (IDS[a], IDS[b], now - 8000))
    for tgt, src, v, ago, src_age in (("web", "design", 2, 3000, 3700), ("web", "api", 2, 4000, 4200), ("notes", "web", 1, 600, 800)):
        con.execute("INSERT OR REPLACE INTO injections(target, source, version, at, src_at) VALUES(?,?,?,?,?)",
                    (IDS[tgt], IDS[src], v, now - ago, now - src_age))
    con.commit()
    con.close()
    (out / "send-frontend.json").write_text(json.dumps(
        {"hook_event_name": "UserPromptSubmit", "session_id": IDS["web"], "prompt": t["prompt"],
         "transcript_path": str(paths["web"]), "cwd": str(home / CWD["web"])}, ensure_ascii=False))
    print(f"demo ({lang}) → {out}\n  HOME={home} CFFIXED_USER_HOME={home} CTXGRAPH_HOME={data}")


if __name__ == "__main__":
    main()
