"""테스트 공용: 가짜 HOME 과 가짜 `claude` 로 ctxgraph.py 를 따로 돌린다.

- 사용자의 실제 ~/.claude, graph.sqlite, Claude 로그인은 건드리지 않는다 (HOME 을 임시 폴더로).
- `claude` 는 tests 의 가짜 스크립트: 요약 요청(-p)에 정해진 답을 하고, 받은 인자·환경을 기록한다.
- 시험할 스크립트는 CTXGRAPH_SCRIPT 로 바꿀 수 있다 (기본: 저장소의 bin/ctxgraph.py).
"""
from __future__ import annotations

import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = Path(os.environ.get("CTXGRAPH_SCRIPT") or ROOT / "bin" / "ctxgraph.py").resolve()

# 요약 요청이면 <summary>/<delta> 를 돌려주는 가짜 claude. 호출마다 calls.jsonl 에 한 줄.
FAKE_CLAUDE = r'''
import json, os, sys
from pathlib import Path
d = Path(os.environ["FAKE_CLAUDE_DIR"])
args = sys.argv[1:]
if args[:1] == ["--version"]:
    print("2.1.99 (Claude Code)"); sys.exit(0)
if args[:2] == ["agents", "--json"]:
    print("[]"); sys.exit(0)
prompt = sys.stdin.read() if "-p" in args else ""
n_file = d / "count"
n = int(n_file.read_text()) + 1 if n_file.exists() else 1
n_file.write_text(str(n))
with open(d / "calls.jsonl", "a") as fh:
    fh.write(json.dumps({"args": args, "prompt": prompt,
                         "env": sorted(k for k in os.environ if k.startswith(("CLAUDE", "CTXGRAPH", "ANTHROPIC")))}) + "\n")
if os.environ.get("FAKE_CLAUDE_FAIL") or (d / "fail").exists():
    print("boom", file=sys.stderr); sys.exit(1)
print(f"<summary>SUMMARY {n}</summary>\n<delta>DELTA {n}</delta>")
'''

T0 = 1794528000.0           # 2026-11-13 00:00:00 UTC — 기록 파일 시각을 고정해 출력이 늘 같게


def compact(d: dict) -> str:
    """Claude Code 가 쓰는 것처럼 공백 없는 JSON 한 줄"""
    return json.dumps(d, ensure_ascii=False, separators=(",", ":"))


class Sandbox:
    def __init__(self, lang: str = "ko"):
        self.dir = Path(tempfile.mkdtemp(prefix="ctxgraph-test-")).resolve()
        self.home = self.dir / "home"
        self.claude_dir = self.home / ".claude"
        self.projects = self.claude_dir / "projects"
        self.projects.mkdir(parents=True)
        self.app_dir = self.home / "Library" / "Application Support" / "CtxGraph"
        self.db_path = self.app_dir / "graph.sqlite"
        # 스크립트는 샌드박스 안 사본을 돌린다: 백그라운드 요약 작업의 명령줄에 샌드박스 경로가 들어가서
        # 끝날 때까지 기다릴 수 있고(pgrep), 훅 명령의 경로도 샌드박스 것이 된다
        self.bin = self.dir / "bin"
        self.bin.mkdir()
        for f in [SCRIPT, *SCRIPT.parent.glob("ctx-skill*.md")]:
            shutil.copy2(f, self.bin / f.name)
        self.script = self.bin / SCRIPT.name
        self.fake = self.dir / "fakeclaude"
        self.fake.mkdir()
        (self.fake / "fake_claude.py").write_text(FAKE_CLAUDE)
        claude = self.fake / "claude"
        claude.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{self.fake / "fake_claude.py"}" "$@"\n')
        claude.chmod(0o755)
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("CLAUDE", "CTXGRAPH", "ANTHROPIC", "PYTHON")) and k not in ("TERM_PROGRAM", "AI_AGENT")}
        env.update(HOME=str(self.home), PATH=f"{self.fake}:/usr/bin:/bin", CTXGRAPH_LANG=lang,
                   TZ="UTC", LANG="C", FAKE_CLAUDE_DIR=str(self.fake))
        self.env = env

    def close(self) -> None:
        self.wait_jobs()
        shutil.rmtree(self.dir, ignore_errors=True)

    # ── 실행 ──
    def run(self, *args: str, input: str | None = None, check: bool = True, env: dict | None = None,
            script: Path | None = None) -> subprocess.CompletedProcess:
        r = subprocess.run([sys.executable, "-I", str(script or self.script), *args], input=input,
                           capture_output=True, text=True, env={**self.env, **(env or {})}, timeout=60)
        if check and r.returncode != 0:
            raise AssertionError(f"ctxgraph {' '.join(args)} → exit {r.returncode}\n{r.stdout}\n{r.stderr}")
        return r

    def hook(self, event: str, sid: str | None, raw: str | None = None, **extra) -> dict | None:
        """훅을 Claude Code 처럼 부른다. 출력 JSON(없으면 None). 훅은 언제나 exit 0 이어야 한다."""
        data = {"hook_event_name": event, **extra}
        if sid:
            data.setdefault("session_id", sid)
            p = self.transcript_path(sid)
            if p:
                data.setdefault("transcript_path", str(p))
        r = self.run("hook", input=raw if raw is not None else json.dumps(data), check=False)
        assert r.returncode == 0, f"hook exit {r.returncode}: {r.stderr}"
        return json.loads(r.stdout) if r.stdout.strip() else None

    def context(self, sid: str) -> str | None:
        out = self.hook("UserPromptSubmit", sid, prompt="hi", cwd="/tmp")
        return out["hookSpecificOutput"]["additionalContext"] if out else None

    # ── 대화 기록 ──
    def transcript(self, sid: str, cwd: str, title: str, turns: list[tuple[str, str]], mtime: float = T0) -> Path:
        proj = self.projects / re.sub(r"[^A-Za-z0-9]", "-", cwd)
        proj.mkdir(parents=True, exist_ok=True)
        p = proj / f"{sid}.jsonl"
        lines = [compact({"type": "ai-title", "aiTitle": title, "sessionId": sid})] if not p.exists() else []
        lines += [self._line(sid, cwd, role, text, i) for i, (role, text) in enumerate(turns)]
        with open(p, "a") as fh:
            fh.write("\n".join(lines) + "\n")
        os.utime(p, (mtime, mtime))
        return p

    def append(self, sid: str, turns: list[tuple[str, str]], mtime: float = T0 + 600) -> None:
        p = self.transcript_path(sid)
        cwd = json.loads(p.read_text().splitlines()[1])["cwd"]
        with open(p, "a") as fh:
            fh.write("\n".join(self._line(sid, cwd, r, t, 100 + i) for i, (r, t) in enumerate(turns)) + "\n")
        os.utime(p, (mtime, mtime))

    @staticmethod
    def _line(sid: str, cwd: str, role: str, text: str, i: int) -> str:
        ts = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(T0 - 3600 + i * 60))
        if role == "U":
            return compact({"type": "user", "message": {"role": "user", "content": text}, "timestamp": ts,
                            "cwd": cwd, "sessionId": sid, "origin": {"kind": "human"}})
        return compact({"type": "assistant", "message": {"role": "assistant",
                        "content": [{"type": "text", "text": text}]}, "timestamp": ts, "cwd": cwd, "sessionId": sid})

    def transcript_path(self, sid: str) -> Path | None:
        hits = list(self.projects.glob(f"*/{sid}.jsonl"))
        return hits[0] if hits else None

    # ── DB ──
    def db(self) -> sqlite3.Connection:
        con = sqlite3.connect(str(self.db_path), timeout=5)
        con.row_factory = sqlite3.Row
        return con

    def q(self, sql: str, *args):
        con = self.db()
        try:
            return con.execute(sql, args).fetchall()
        finally:
            con.close()

    def x(self, sql: str, *args) -> None:
        con = self.db()
        try:
            con.execute(sql, args)
            con.commit()
        finally:
            con.close()

    def dump(self) -> list[str]:
        """DB 전체 내용 (바뀌었는지 비교용)"""
        con = self.db()
        try:
            return list(con.iterdump()) + [f"user_version={con.execute('PRAGMA user_version').fetchone()[0]}"]
        finally:
            con.close()

    # ── 가짜 claude ──
    def calls(self) -> list[dict]:
        f = self.fake / "calls.jsonl"
        return [json.loads(x) for x in f.read_text().splitlines()] if f.exists() else []

    def wait_jobs(self, timeout: float = 20) -> None:
        """백그라운드 요약 작업(summarize-job·summarize)이 끝날 때까지"""
        end = time.time() + timeout
        while time.time() < end:
            r = subprocess.run(["pgrep", "-f", str(self.dir)], capture_output=True, text=True)
            if not r.stdout.strip():
                return
            time.sleep(0.2)
        raise AssertionError("background jobs did not finish")

    def normalize(self, text: str) -> str:
        return text.replace(str(self.dir), "<SANDBOX>")


# 기본 두 대화: A(알파) → B(베타)
A = "aaaaaaaa-1111-4111-8111-111111111111"
B = "bbbbbbbb-2222-4222-8222-222222222222"
C = "cccccccc-3333-4333-8333-333333333333"


def two_conversations(sb: Sandbox) -> None:
    sb.transcript(A, "/tmp/alpha", "Alpha work", [("U", "알파 기능을 만들자"), ("A", "좋아요, 알파부터 시작할게요.")])
    sb.transcript(B, "/tmp/beta", "Beta work", [("U", "베타 문서를 정리하자"), ("A", "베타 문서를 열었어요.")])
    sb.run("scan")
    sb.run("add", A)
    sb.run("add", B)
