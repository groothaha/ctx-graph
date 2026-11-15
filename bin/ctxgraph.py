#!/usr/bin/env python3
"""CtxGraph — Claude Code 대화를 노드로, 선을 '맥락 공유'로 다루는 그래프의 백엔드.

서버 없음. CtxGraph.app 과 Claude Code 훅이 SQLite 파일 하나(graph.sqlite)를 같이 쓴다.

  연결은 방향이 있다. S → T 는 'S 의 맥락이 T 로 들어간다'. 양쪽 모두 있으면 서로 공유.
  - 나가는 연결이 있는 S 의 한 턴이 끝나면(Stop 훅) S 요약 작업을 예약한다. 작업은 S 가
    잠잠해지고 쿨다운이 지나면 Haiku(claude -p)로 요약을 갱신한다 (이전 요약 + 새로 진행된 부분).
  - T 에서 메시지를 보낼 때(UserPromptSubmit 훅) 들어오는 연결의 S 요약을 additionalContext 로 넣는다.
    처음엔 전체 요약, 그 뒤엔 바뀐 버전만 (한 버전 차이면 변경점, 그 이상이면 전체).
  - 재개·압축(SessionStart resume/compact) 때는 다시 전체 요약부터 넣는다.

명령
  hook                         훅 진입점 (stdin JSON, 실패해도 항상 exit 0)
  hooks-status [--settings P]  Claude Code 훅·/ctx 스킬 설치 상태 (JSON)
  preview <sid|current>        다음 메시지에 들어갈 맥락 미리보기 (JSON, 기록 안 함)
  usage                        요약 횟수 (오늘·7일·30일, 실패, 모델별 — JSON)
  install-hooks [--settings P] [--no-skill]   훅을 ~/.claude/settings.json 에 넣기 (백업 후, 있으면 경로만 고침)
  uninstall-hooks [--settings P]              우리 훅만 빼기 (백업 후). 스킬은 우리가 만든 것만 지움
  init                         스키마 생성
  scan [--json] [--q 검색어] [--limit N]   대화 목록 캐시 갱신
  add <sid|current> [--x X --y Y]
  remove <sid|current>
  link <a> <b> [--both]        a → b (a 의 맥락을 b 에 넣음). --both 면 양방향
  unlink <a> <b> [--both]      a → b 끊기. --both 면 양쪽 다
                               (a·b: 세션 ID, ID 앞부분, 'current', 또는 제목 검색어)
  status [sid|current]
  summarize <sid> [--force]
  summarize-job <sid>          (내부용) 쿨다운·잠잠해질 때까지 기다렸다 요약
  models                       모델 프로필 목록 (JSON)
  launch-env <model_id>        그 모델로 Claude Code 를 띄울 env·인자 (JSON, 앱 터미널용)
  import-orc [--key]           ~/.config/openrouter/or.zsh 의 OR_MODELS 별칭을 프로필로 가져오기
                               (--key: ~/.config/openrouter/key 도 keys.json 으로 복사)
  test-model <model_id>        짧은 요청으로 모델·키 확인
  notify [메시지]              앱 터미널 안에서: 이 탭에 알림 (파란 테두리·macOS 알림). 예: 학습 끝나면 ctxgraph notify 끝
  places                       파일 위치 목록 (JSON)
  scope <sid> [--all | 위치ID…] 이 대화의 수정 범위 보기/바꾸기 (--all = 제한 없음)

작업 폴더(정리용): 대화마다 '고른 위치 안에서만 파일을 만들고 고친다' 로 정할 수 있다 (nodes.write_limited + node_places).
  - UserPromptSubmit 에서 작업 폴더가 바뀌었으면 Claude 에게 한 번 알려 준다 (새 파일은 그 안에).
  - PreToolUse 훅이 Edit·Write 같은 파일 도구가 폴더 밖을 고치려 하면 막고 '폴더 안에 만들라' 고 돌려보낸다.
    ~/.claude(메모리·계획)와 임시 폴더는 정리 대상이 아니라 늘 허용.
  - 셸 명령은 기본으로 막지 않는다. 엄격 모드(nodes.write_strict)를 켠 대화만 앱 터미널에서 sandbox-exec 로 감싼다.

모델 프로필(models 테이블): provider = subscription(Claude 구독) | openrouter | anthropic(API 키) | custom(Anthropic 호환 URL).
API 키는 keys.json (0600) 에 둔다. 요약 모델은 settings.summary_model, 새 대화 기본은 settings.default_model.
"""
from __future__ import annotations

import fcntl
import json
import zlib
import os
import re
import shutil
import tempfile
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

if sys.version_info < (3, 9):
    sys.exit("CtxGraph needs Python 3.9 or newer (python3 --version)")

HOME = Path.home()

# ── 언어: 앱이 CTXGRAPH_LANG(ko·en)으로 넘기고 settings.lang 에 남긴다. 훅은 settings 를 따른다 ──
_LANG: str | None = None


def init_lang(con=None) -> str:
    global _LANG
    env = os.environ.get("CTXGRAPH_LANG")
    if env:
        _LANG = "ko" if env.lower().startswith("ko") else "en"
        if con is not None:
            try:
                cur = con.execute("SELECT value FROM settings WHERE key='lang'").fetchone()
                if not cur or cur[0] != _LANG:
                    con.execute("INSERT OR REPLACE INTO settings(key, value) VALUES('lang', ?)", (_LANG,))
            except sqlite3.Error:
                pass
        return _LANG
    if con is not None:
        try:
            cur = con.execute("SELECT value FROM settings WHERE key='lang'").fetchone()
            if cur and cur[0] in ("ko", "en"):
                _LANG = cur[0]
                return _LANG
        except sqlite3.Error:
            pass
    if _LANG is None:
        _LANG = "ko" if os.environ.get("LANG", "").lower().startswith("ko") else "en"
    return _LANG


def tr(ko: str, en: str) -> str:
    """앱 언어에 맞는 문구"""
    return ko if (_LANG or init_lang()) == "ko" else en
PROJECTS = HOME / ".claude" / "projects"
# CTXGRAPH_HOME: 시험용으로 다른 데이터 폴더를 쓸 때 (훅은 항상 기본 폴더)
APP_DIR = Path(os.environ["CTXGRAPH_HOME"]) if os.environ.get("CTXGRAPH_HOME") else HOME / "Library" / "Application Support" / "CtxGraph"
DB_PATH = APP_DIR / "graph.sqlite"
WORK_DIR = APP_DIR / "work"
LOCK_DIR = APP_DIR / "locks"
LOG_PATH = APP_DIR / "ctxgraph.log"
KEYS_PATH = APP_DIR / "keys.json"
ORC_PATH = HOME / ".config" / "openrouter" / "or.zsh"
ORC_KEY_PATH = HOME / ".config" / "openrouter" / "key"
OPENROUTER_BASE = "https://openrouter.ai/api"

VERSION = "0.1.1"           # 앱 Info.plist 의 CFBundleShortVersionString 과 같게 (tests/test_schema.py)

# graph.sqlite 형식 번호 (PRAGMA user_version). 형식을 바꿀 때는 MIGRATIONS 에 단계를 더하고
# 앱의 Schema.version (app/Sources/CtxGraph/Backend.swift) 도 같이 올린다 — tests/test_schema.py 가 확인함
SCHEMA_VERSION = 3

SUMMARY_MODEL = "haiku"
COOLDOWN = 120          # 같은 대화를 다시 요약하기까지 최소 간격(초)
QUIET = 20              # 대화 기록이 이만큼 조용해야 요약 시작(초)
JOB_MAX_WAIT = 1800     # 예약 작업이 기다리는 최대 시간(초) — 넘으면 그냥 요약
SUMMARY_TIMEOUT = 300
TRANSCRIPT_BUDGET = 60_000   # 요약기에 넘기는 대화 원문 최대 글자 수
INJECT_BUDGET = 9_000        # 한 번에 주입하는 맥락 최대 글자 수

SCHEMA = """
CREATE TABLE IF NOT EXISTS nodes(
  session_id       TEXT PRIMARY KEY,
  transcript_path  TEXT NOT NULL,
  cwd              TEXT,
  label            TEXT,
  x                REAL,
  y                REAL,
  added_at         REAL NOT NULL,
  summary          TEXT,
  delta            TEXT,
  summary_version  INTEGER NOT NULL DEFAULT 0,
  summary_at       REAL,
  summary_src_size INTEGER NOT NULL DEFAULT 0,
  summary_error    TEXT,
  job_started_at   REAL,
  summarizing_at   REAL,
  summary_src_at   REAL
);
CREATE TABLE IF NOT EXISTS links(
  src        TEXT NOT NULL,
  dst        TEXT NOT NULL,
  created_at REAL NOT NULL,
  PRIMARY KEY(src, dst),
  CHECK(src <> dst)
);
CREATE INDEX IF NOT EXISTS links_dst ON links(dst);
CREATE TABLE IF NOT EXISTS injections(
  target  TEXT NOT NULL,
  source  TEXT NOT NULL,
  version INTEGER NOT NULL,
  at      REAL NOT NULL,
  src_at  REAL,
  PRIMARY KEY(target, source)
);
CREATE TABLE IF NOT EXISTS sessions(
  path          TEXT PRIMARY KEY,
  session_id    TEXT NOT NULL,
  cwd           TEXT,
  agent_name    TEXT,
  ai_title      TEXT,
  first_prompt  TEXT,
  last_prompt   TEXT,
  n_prompts     INTEGER NOT NULL DEFAULT 0,
  mtime         REAL NOT NULL,
  size          INTEGER NOT NULL,
  parsed_offset INTEGER NOT NULL DEFAULT 0,
  live_status   TEXT,
  live_name     TEXT
);
CREATE INDEX IF NOT EXISTS sessions_sid ON sessions(session_id);
CREATE TABLE IF NOT EXISTS models(
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  provider    TEXT NOT NULL,
  model       TEXT,
  small_model TEXT,
  base_url    TEXT,
  sort        INTEGER NOT NULL DEFAULT 100
);
CREATE TABLE IF NOT EXISTS settings(
  key   TEXT PRIMARY KEY,
  value TEXT
);
CREATE INDEX IF NOT EXISTS sessions_mtime ON sessions(mtime);
CREATE TABLE IF NOT EXISTS places(
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  name       TEXT,
  path       TEXT NOT NULL UNIQUE,
  sort       INTEGER NOT NULL DEFAULT 0,
  created_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS term_events(
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  tab     TEXT NOT NULL,
  kind    TEXT NOT NULL,
  message TEXT,
  at      REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS node_places(
  session_id TEXT NOT NULL,
  place_id   INTEGER NOT NULL,
  PRIMARY KEY(session_id, place_id)
);
CREATE TABLE IF NOT EXISTS spaces(
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  sort       INTEGER NOT NULL DEFAULT 0,
  created_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS labels(
  session_id TEXT PRIMARY KEY,
  label      TEXT NOT NULL,
  set_at     REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS placements(
  session_id TEXT NOT NULL,
  space      TEXT NOT NULL,
  x          REAL,
  y          REAL,
  added_at   REAL NOT NULL,
  PRIMARY KEY(session_id, space)
);
"""


# ── 공통 ────────────────────────────────────────────────────────────────

def log(msg: str) -> None:
    try:
        APP_DIR.mkdir(parents=True, exist_ok=True)
        with open(LOG_PATH, "a") as fh:
            fh.write(time.strftime("%m-%d %H:%M:%S ") + msg.rstrip() + "\n")
    except OSError:
        pass


class NewerSchema(RuntimeError):
    """DB 가 이 스크립트보다 새 형식 (앱을 예전 버전으로 되돌린 경우 등)"""
    def __init__(self, version: int):
        self.version = version
        super().__init__(tr(f"이 데이터(graph.sqlite)는 더 새 CtxGraph 가 만든 형식이에요 (데이터 v{version}, 이 버전 v{SCHEMA_VERSION}). "
                            "CtxGraph 를 업데이트해 주세요 — 그동안 데이터는 고치지 않아요.",
                            f"This data (graph.sqlite) was made by a newer CtxGraph (data v{version}, this version v{SCHEMA_VERSION}). "
                            "Please update CtxGraph — until then the data is left untouched."))


def schema_version(con) -> int:
    return con.execute("PRAGMA user_version").fetchone()[0]


def set_wal(con: sqlite3.Connection, wait: float = 10.0) -> None:
    """WAL 로 바꾼다. 처음 바꾸는 순간(새 DB·옛 DB)엔 SQLite 가 busy_timeout 을 쓰지 않고 바로
    'database is locked' 를 낼 때가 있다 — 훅 여러 개가 같은 순간 처음 열면 (CI 에서 8개 중 1개).
    WAL 은 파일에 남는 설정이라 누군가 한 번 바꾸면 그 뒤로는 아무 일도 안 하므로, 잠깐씩 쉬며 다시 해 본다."""
    deadline = time.monotonic() + wait
    delay = 0.01 + (os.getpid() % 7) * 0.003      # 프로세스마다 조금씩 어긋나게
    while True:
        try:
            con.execute("PRAGMA journal_mode=WAL")
            return
        except sqlite3.OperationalError as e:
            if "locked" not in str(e) or time.monotonic() + delay > deadline:
                raise
            time.sleep(delay)
            delay = min(delay * 2, 0.25)


def connect(create: bool = True) -> sqlite3.Connection | None:
    if not create and not DB_PATH.exists():
        return None
    APP_DIR.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(str(DB_PATH), timeout=5, isolation_level=None)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA busy_timeout=5000")
    v = schema_version(con)
    if v > SCHEMA_VERSION:              # 더 새 CtxGraph 가 만든 DB — 모르는 형식에 쓰지 않는다
        con.close()
        raise NewerSchema(v)
    try:
        set_wal(con)
        con.executescript(SCHEMA)
        init_lang(con)
        migrate(con)
    except BaseException:
        con.close()
        raise
    return con


# 0.1 의 무방향 edges(a<b) 테이블 → 방향 있는 links (기존 연결은 양방향으로).
# 그 뒤 edges 는 '쌍' 을 보여 주는 호환 뷰가 된다: 아직 재시작 안 한 옛 앱이 계속 동작하도록.
EDGES_COMPAT = """
CREATE VIEW IF NOT EXISTS edges AS
  SELECT CASE WHEN src < dst THEN src ELSE dst END AS a,
         CASE WHEN src < dst THEN dst ELSE src END AS b,
         MIN(created_at) AS created_at
  FROM links GROUP BY 1, 2;
CREATE TRIGGER IF NOT EXISTS edges_ins INSTEAD OF INSERT ON edges BEGIN
  INSERT OR IGNORE INTO links(src, dst, created_at) VALUES(NEW.a, NEW.b, NEW.created_at);
  INSERT OR IGNORE INTO links(src, dst, created_at) VALUES(NEW.b, NEW.a, NEW.created_at);
END;
CREATE TRIGGER IF NOT EXISTS edges_del INSTEAD OF DELETE ON edges BEGIN
  DELETE FROM links WHERE (src = OLD.a AND dst = OLD.b) OR (src = OLD.b AND dst = OLD.a);
END;
"""


# 형식 단계: (번호, 함수). 함수는 BEGIN IMMEDIATE 안에서 돌고, 끝나면 user_version 이 그 번호가 된다.
# 예) MIGRATIONS = [(3, lambda con: con.execute("ALTER TABLE nodes ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0"))]
def _v2_placements(con) -> None:
    """v2: 대화 하나를 여러 작업 공간에 놓을 수 있게 — 공간별 위치를 placements 로.
    nodes.space·x·y 는 남겨 두지만 더는 읽지 않는다."""
    con.execute("INSERT OR IGNORE INTO placements(session_id, space, x, y, added_at)"
                " SELECT session_id, COALESCE(space, ?), x, y, added_at FROM nodes", (DEFAULT_SPACE,))


def _v3_labels(con) -> None:
    """v3: 사용자가 붙인 대화 이름을 노드가 아니라 대화에 — 그래프에 없는 대화에도 이름을 붙이고, 뺐다 넣어도 남게."""
    con.execute("INSERT OR IGNORE INTO labels(session_id, label, set_at)"
                " SELECT session_id, label, ? FROM nodes WHERE label IS NOT NULL AND TRIM(label)<>''"
                " AND label NOT IN ('새 대화', 'New Conversation')", (time.time(),))   # 예전 앱이 자리 표시 제목을 이름으로 저장한 것
    con.execute("UPDATE nodes SET label=NULL")


MIGRATIONS: list = [(2, _v2_placements), (3, _v3_labels)]


def migrate(con) -> None:
    v = schema_version(con)
    if v < 1:
        _migrate_legacy(con)                 # 번호를 매기기 전(0.x) DB·새 DB → v1
        con.execute("PRAGMA user_version=1")
    for version, step in MIGRATIONS:
        if v < version:
            _migrate_step(con, version, step)
    seed_defaults(con)


def _migrate_step(con, version: int, step) -> None:
    con.execute("BEGIN IMMEDIATE")           # 훅 여러 개가 동시에 열어도 한 번만
    try:
        if schema_version(con) < version:
            step(con)
            con.execute(f"PRAGMA user_version={int(version)}")
            log(f"migrated graph.sqlite → v{version}")
        con.execute("COMMIT")
    except BaseException:
        con.execute("ROLLBACK")
        raise


def _migrate_legacy(con) -> None:
    """v1 기준선: 0.x 동안 '없으면 추가' 로 늘어난 열·표를 채운다. 여러 프로세스가 같이 돌려도 같은 결과."""
    kind = con.execute("SELECT type FROM sqlite_master WHERE name='edges'").fetchone()
    if kind and kind[0] == "table":
        con.execute("BEGIN IMMEDIATE")
        try:
            again = con.execute("SELECT type FROM sqlite_master WHERE name='edges'").fetchone()
            if again and again[0] == "table":
                con.execute("INSERT OR IGNORE INTO links SELECT a, b, created_at FROM edges")
                con.execute("INSERT OR IGNORE INTO links SELECT b, a, created_at FROM edges")
                con.execute("DROP TABLE edges")
            con.execute("COMMIT")
        except Exception:
            con.execute("ROLLBACK")
            raise
        log("migrated edges → links (기존 연결은 양방향)")
    if not kind or kind[0] == "table":
        con.executescript(EDGES_COMPAT)
    cols = {r[1] for r in con.execute("PRAGMA table_info(nodes)")}
    if "model_id" not in cols:
        try:
            con.execute("ALTER TABLE nodes ADD COLUMN model_id TEXT")   # 이 대화를 마지막으로 연 모델
        except sqlite3.OperationalError:
            pass                                                        # 다른 프로세스가 먼저 추가
    if "write_limited" not in cols:
        try:
            con.execute("ALTER TABLE nodes ADD COLUMN write_limited INTEGER NOT NULL DEFAULT 0")  # 1 = 고른 위치 안만 수정
        except sqlite3.OperationalError:
            pass
    if "write_strict" not in cols:
        try:
            con.execute("ALTER TABLE nodes ADD COLUMN write_strict INTEGER NOT NULL DEFAULT 0")   # 1 = 셸 명령도 샌드박스로
        except sqlite3.OperationalError:
            pass
    if "space" not in cols:
        try:
            con.execute("ALTER TABLE nodes ADD COLUMN space TEXT")   # 작업 공간 (NULL = 기본)
        except sqlite3.OperationalError:
            pass
    if "summary_src_at" not in cols:
        try:
            con.execute("ALTER TABLE nodes ADD COLUMN summary_src_at REAL")   # 요약이 담은 마지막 메시지 시각
            for r in con.execute("SELECT session_id, transcript_path, summary_src_size FROM nodes"
                                 " WHERE summary_version>0").fetchall():
                ts = last_timestamp(Path(r[1] or "/nonexistent"), r[2])
                if ts:
                    con.execute("UPDATE nodes SET summary_src_at=? WHERE session_id=?", (ts, r[0]))
        except sqlite3.OperationalError:
            pass
    if not con.execute("SELECT 1 FROM sqlite_master WHERE name='summary_runs'").fetchone():
        try:
            con.execute("CREATE TABLE summary_runs(at REAL NOT NULL, sid TEXT, model TEXT, ok INTEGER NOT NULL,"
                        " secs REAL, in_chars INTEGER, out_chars INTEGER, incremental INTEGER)")
            con.execute("CREATE INDEX summary_runs_at ON summary_runs(at)")
            backfill_summary_runs(con)
        except sqlite3.OperationalError:
            pass                                                        # 다른 프로세스가 먼저 만듦
    icols = {r[1] for r in con.execute("PRAGMA table_info(injections)")}
    if "src_at" not in icols:
        try:
            con.execute("ALTER TABLE injections ADD COLUMN src_at REAL")       # 받은 요약이 담은 마지막 시각
            con.execute("UPDATE injections SET src_at=(SELECT n.summary_src_at FROM nodes n WHERE"
                        " n.session_id=injections.source AND n.summary_version=injections.version)")
        except sqlite3.OperationalError:
            pass


def seed_defaults(con) -> None:
    """기본 작업 공간·모델·설정 (지워져도 다시 생김)"""
    con.execute("INSERT OR IGNORE INTO spaces(id, name, sort, created_at) VALUES(?,?,0,?)",
                (DEFAULT_SPACE, tr("기본", "Main"), time.time()))
    for row in builtin_models():
        con.execute("INSERT OR IGNORE INTO models(id, name, provider, model, small_model, base_url, sort)"
                    " VALUES(?,?,?,?,?,?,?)", row)
    for k, v in DEFAULT_SETTINGS.items():
        con.execute("INSERT OR IGNORE INTO settings(key, value) VALUES(?,?)", (k, v))


def builtin_models() -> list[tuple]:
    sub = tr("구독", "subscription")
    return [
        ("claude", tr("Claude (구독 · 기본 모델)", "Claude (subscription · default model)"), "subscription", None, None, None, 0),
        ("claude-opus", f"Claude Opus ({sub})", "subscription", "opus", None, None, 1),
        ("claude-sonnet", f"Claude Sonnet ({sub})", "subscription", "sonnet", None, None, 2),
        ("claude-haiku", f"Claude Haiku ({sub})", "subscription", "haiku", None, None, 3),
    ]
DEFAULT_SPACE = "main"      # 작업 공간: 그래프 노드 묶음 + 앱의 터미널 탭·분할 배치 (앱에서 바꿈)
DEFAULT_SETTINGS = {
    "current_space": DEFAULT_SPACE,
    "summary_model": "claude-haiku",
    "default_model": "claude",
    "or_small": "deepseek/deepseek-v4.1-flash-1017",   # OpenRouter 대화의 haiku·서브에이전트 자리 (orc 와 같음)
    "or_vision": "z-ai/glm-5.3-flash",                 # 텍스트 전용 모델에 이미지가 오면 넘길 모델 (orc 와 같음)
    "custom_base_url": "",
}


def one_line(s: str | None, n: int) -> str:
    s = re.sub(r"\s+", " ", s or "").strip()
    return s if len(s) <= n else s[: n - 1] + "…"


def short_path(p: str | None) -> str:
    if not p:
        return "?"
    h = str(HOME)
    return "~" + p[len(h):] if p == h or p.startswith(h + "/") else p


def find_transcript(sid: str) -> Path | None:
    hits = [p for p in PROJECTS.glob(f"*/{sid}.jsonl") if "CtxGraph" not in p.parent.name]
    return max(hits, key=lambda p: p.stat().st_mtime) if hits else None


def node(con, sid):
    return con.execute("SELECT * FROM nodes WHERE session_id=?", (sid,)).fetchone()


def sources_of(con, sid) -> list[str]:
    """sid 로 맥락이 들어오는 대화들 (src → sid)."""
    return [r[0] for r in con.execute("SELECT src FROM links WHERE dst=? ORDER BY created_at", (sid,))]


def targets_of(con, sid) -> list[str]:
    """sid 의 맥락을 받는 대화들 (sid → dst)."""
    return [r[0] for r in con.execute("SELECT dst FROM links WHERE src=? ORDER BY created_at", (sid,))]


def title_of(con, sid: str, label: str | None = None) -> str:
    """대화 이름: 사용자가 붙인 이름(labels) → Claude Code 의 /rename → 자동 제목 → 첫 메시지"""
    if label:
        return label
    r = con.execute("SELECT label FROM labels WHERE session_id=?", (sid,)).fetchone()
    if r and r[0]:
        return r[0]
    r = con.execute(
        "SELECT agent_name, ai_title, first_prompt FROM sessions WHERE session_id=? "
        "ORDER BY mtime DESC LIMIT 1", (sid,)).fetchone()
    if r:
        if r["agent_name"]:
            return r["agent_name"]
        if r["ai_title"]:
            return r["ai_title"]
        if r["first_prompt"]:
            return one_line(r["first_prompt"], 60)
    return sid[:8]


# ── 대화 기록(jsonl) 읽기 ───────────────────────────────────────────────

def human_text(d: dict) -> str | None:
    """사람이 직접 친 프롬프트면 그 텍스트, 아니면 None (도구 결과·메타·명령 출력 제외)."""
    if d.get("type") != "user" or d.get("isMeta") or d.get("isSidechain"):
        return None
    origin = d.get("origin")
    if isinstance(origin, dict) and origin.get("kind") not in (None, "human"):
        return None
    c = (d.get("message") or {}).get("content")
    if isinstance(c, list):
        if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
            return None
        c = "\n".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
    if not isinstance(c, str):
        return None
    s = c.strip()
    if not s or s.startswith("<"):        # <command-name>, <local-command-caveat> 등
        return None
    return s


def assistant_texts(d: dict) -> list[str]:
    if d.get("type") != "assistant" or d.get("isSidechain"):
        return []
    c = (d.get("message") or {}).get("content")
    if not isinstance(c, list):
        return []
    return [b["text"].strip() for b in c
            if isinstance(b, dict) and b.get("type") == "text" and (b.get("text") or "").strip()]


def _line_at(buf: bytes, pos: int) -> dict | None:
    start = buf.rfind(b"\n", 0, pos) + 1
    end = buf.find(b"\n", pos)
    if end < 0:
        return None
    try:
        return json.loads(buf[start:end])
    except ValueError:
        return None


def _last_field(buf: bytes, marker: bytes, field: str) -> str | None:
    pos = buf.rfind(marker)
    while pos >= 0:
        d = _line_at(buf, pos)
        if d and d.get(field):
            return str(d[field])
        pos = buf.rfind(marker, 0, pos)
    return None


def _human_prompts(buf: bytes, reverse: bool, limit: int = 400):
    marker = b'"type":"user"'
    pos = buf.rfind(marker) if reverse else buf.find(marker)
    tries = 0
    while pos >= 0 and tries < limit:
        tries += 1
        d = _line_at(buf, pos)
        t = human_text(d) if d else None
        if t:
            yield t
        pos = buf.rfind(marker, 0, pos) if reverse else buf.find(marker, pos + 1)


def parse_meta(path: Path, prev: dict | None) -> dict:
    """파일 전체(또는 이전 파싱 지점 이후)만 읽어 제목·첫/마지막 프롬프트·턴 수를 갱신."""
    meta = dict(prev) if prev else {
        "cwd": None, "agent_name": None, "ai_title": None,
        "first_prompt": None, "last_prompt": None, "n_prompts": 0, "parsed_offset": 0,
    }
    start = meta["parsed_offset"] or 0
    with open(path, "rb") as fh:
        fh.seek(start)
        buf = fh.read()
    cut = buf.rfind(b"\n") + 1          # 끝의 미완성 줄은 다음 번에
    buf = buf[:cut]
    if not buf:
        return meta
    if not meta["cwd"]:
        i = buf.find(b'"cwd":"')
        if i >= 0:
            d = _line_at(buf, i)
            if d:
                meta["cwd"] = d.get("cwd")
    meta["agent_name"] = _last_field(buf, b'"type":"agent-name"', "agentName") or meta["agent_name"]
    meta["ai_title"] = _last_field(buf, b'"type":"ai-title"', "aiTitle") or meta["ai_title"]
    if not meta["first_prompt"]:
        meta["first_prompt"] = next(_human_prompts(buf, reverse=False), None)
    meta["last_prompt"] = next(_human_prompts(buf, reverse=True), None) or meta["last_prompt"]
    meta["n_prompts"] = (meta["n_prompts"] or 0) + buf.count(b'"kind":"human"')
    meta["parsed_offset"] = start + cut
    return meta


def read_messages(path: Path, start: int = 0) -> tuple[list[tuple[str, str]], int]:
    """start 바이트 이후의 (U|A, 텍스트) 목록과, 끝까지 읽은 완성된 줄의 끝 위치."""
    msgs: list[tuple[str, str]] = []
    with open(path, "rb") as fh:
        fh.seek(start)
        buf = fh.read()
    cut = buf.rfind(b"\n") + 1
    for line in buf[:cut].splitlines():
        if b'"type":"user"' in line and b'"tool_result"' not in line:
            try:
                t = human_text(json.loads(line))
            except ValueError:
                continue
            if t:
                msgs.append(("U", t))
        elif b'"type":"assistant"' in line and b'"type":"text"' in line:
            try:
                for t in assistant_texts(json.loads(line)):
                    msgs.append(("A", t))
            except ValueError:
                continue
    return msgs, start + cut


def last_timestamp(path: Path, end: int) -> float | None:
    """end 바이트 앞의 마지막 기록 줄 시각 — 요약이 대화의 어느 시점까지 담았는지 (앱이 시간차 표시에 씀)."""
    from datetime import datetime
    try:
        with open(path, "rb") as fh:
            start = max(0, end - 262_144)
            fh.seek(start)
            buf = fh.read(max(0, end - start))
    except OSError:
        return None
    for line in reversed(buf.splitlines()):
        i = line.rfind(b'"timestamp":"')
        if i < 0:
            continue
        j = line.find(b'"', i + 13)
        try:
            return datetime.fromisoformat(line[i + 13:j].decode().replace("Z", "+00:00")).timestamp()
        except ValueError:
            continue
    return None


def render_messages(msgs: list[tuple[str, str]], budget: int) -> str:
    def clip(t: str, n: int) -> str:
        return t if len(t) <= n else t[: n // 2] + tr("\n…(중략)…\n", "\n…(trimmed)…\n") + t[-n // 2:]

    parts = [f"[{r}] {clip(t, 2500 if r == 'U' else 3500)}" for r, t in msgs]
    if sum(len(p) + 2 for p in parts) <= budget:
        return "\n\n".join(parts)
    head, used = [], 0
    for p in parts[:3]:
        if used + len(p) > budget * 0.15:
            break
        head.append(p)
        used += len(p) + 2
    tail: list[str] = []
    for p in reversed(parts[len(head):]):
        if used + len(p) + 2 > budget:
            break
        tail.append(p)
        used += len(p) + 2
    tail.reverse()
    omitted = len(parts) - len(head) - len(tail)
    return "\n\n".join(head + [tr(f"… (중간 메시지 {omitted}개 생략) …", f"… ({omitted} messages omitted) …")] + tail)


# ── 대화 목록 스캔 ──────────────────────────────────────────────────────

def iter_transcripts():
    if not PROJECTS.is_dir():
        return
    for proj in PROJECTS.iterdir():
        if proj.is_dir() and "CtxGraph" not in proj.name:
            yield from proj.glob("*.jsonl")


def live_sessions() -> dict[str, dict]:
    claude = claude_bin()
    if not claude:
        return {}
    try:
        r = subprocess.run([claude, "agents", "--json"], capture_output=True, text=True,
                           timeout=6, env=clean_env())
        return {s["sessionId"]: s for s in json.loads(r.stdout or "[]") if s.get("sessionId")}
    except (OSError, ValueError, subprocess.SubprocessError):
        return {}


def scan(con) -> int:
    cached = {r["path"]: dict(r) for r in con.execute("SELECT * FROM sessions")}
    seen, changed = set(), 0
    for f in iter_transcripts():
        p = str(f)
        seen.add(p)
        try:
            st = f.stat()
        except OSError:
            continue
        old = cached.get(p)
        if old and old["mtime"] == st.st_mtime and old["size"] == st.st_size:
            continue
        prev = old if old and st.st_size >= old["parsed_offset"] else None
        try:
            m = parse_meta(f, prev)
        except OSError:
            continue
        con.execute(
            "INSERT OR REPLACE INTO sessions(path, session_id, cwd, agent_name, ai_title, first_prompt,"
            " last_prompt, n_prompts, mtime, size, parsed_offset) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
            (p, f.stem, m["cwd"], m["agent_name"], m["ai_title"],
             one_line(m["first_prompt"], 400) if m["first_prompt"] else None,
             one_line(m["last_prompt"], 400) if m["last_prompt"] else None,
             m["n_prompts"], st.st_mtime, st.st_size, m["parsed_offset"]))
        changed += 1
    for p in set(cached) - seen:
        con.execute("DELETE FROM sessions WHERE path=?", (p,))
    live = live_sessions()
    con.execute("UPDATE sessions SET live_status=NULL, live_name=NULL WHERE live_status IS NOT NULL")
    for sid, s in live.items():
        con.execute("UPDATE sessions SET live_status=?, live_name=? WHERE session_id=?",
                    (s.get("status") or "idle", s.get("name"), sid))
    # 노드의 transcript 경로가 바뀌었으면(폴더 이동 등) 따라간다
    for n in con.execute("SELECT session_id, transcript_path FROM nodes").fetchall():
        if not Path(n["transcript_path"] or "/nonexistent").is_file():
            t = find_transcript(n["session_id"])
            if t:
                con.execute("UPDATE nodes SET transcript_path=? WHERE session_id=?", (str(t), n["session_id"]))
    set_health(con, "health_scan", scan_health(con))
    return changed


# ── 요약 ────────────────────────────────────────────────────────────────

SUMMARY_SYSTEM_KO = (
    "너는 Claude Code 대화 기록을, 그 대화와 연결된 다른 대화가 이어받을 '맥락 요약'으로 압축하는 요약기다. "
    "도구를 쓰지 말고 지정한 태그 형식의 텍스트만 출력한다. 기록에 없는 내용은 지어내지 않는다."
)
SUMMARY_SYSTEM_EN = (
    "You compress a Claude Code conversation transcript into a 'context summary' that other, linked "
    "conversations will pick up. Use no tools and output only text in the requested tag format. "
    "Never invent anything that isn't in the transcript."
)


def summary_system() -> str:
    return tr(SUMMARY_SYSTEM_KO, SUMMARY_SYSTEM_EN)


def claude_bin() -> str | None:
    path = os.pathsep.join([os.environ.get("PATH", ""), str(HOME / ".local" / "bin"),
                            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
    return shutil.which("claude", path=path)


def clean_env() -> dict:
    env = {k: v for k, v in os.environ.items()
           if not k.startswith("CLAUDE") and k not in ("AI_AGENT",)}
    env["CTXGRAPH_INTERNAL"] = "1"     # 요약용 claude -p 안에서 우리 훅이 다시 돌지 않게
    env["PATH"] = os.pathsep.join([env.get("PATH", ""), str(HOME / ".local" / "bin"),
                                   "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
    return env


# ── 모델·키 ──────────────────────────────────────────────────────────────

def setting(con, key: str) -> str:
    r = con.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
    return (r[0] if r and r[0] is not None else DEFAULT_SETTINGS.get(key, "")) or ""


def model_row(con, mid: str | None):
    if mid:
        r = con.execute("SELECT * FROM models WHERE id=?", (mid,)).fetchone()
        if r:
            return r
    return con.execute("SELECT * FROM models WHERE id='claude'").fetchone()


def load_keys() -> dict:
    try:
        return json.loads(KEYS_PATH.read_text())
    except (OSError, ValueError):
        return {}


def save_keys(keys: dict) -> None:
    APP_DIR.mkdir(parents=True, exist_ok=True)
    tmp = KEYS_PATH.with_suffix(".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        json.dump(keys, fh)
    os.replace(tmp, KEYS_PATH)
    os.chmod(KEYS_PATH, 0o600)


def endpoint(con, m) -> tuple[str, str, dict]:
    """API 키 방식 프로필 → (base_url, key, 인증 헤더). 키가 없으면 RuntimeError."""
    keys = load_keys()
    prov = m["provider"]
    if prov == "openrouter":
        key = keys.get("openrouter", "")
        base = OPENROUTER_BASE
        headers = {"authorization": f"Bearer {key}"}
    elif prov == "anthropic":
        key = keys.get("anthropic", "")
        base = "https://api.anthropic.com"
        headers = {"x-api-key": key}
    elif prov == "custom":
        key = keys.get("custom", "")
        base = (m["base_url"] or setting(con, "custom_base_url")).rstrip("/")
        if not base:
            raise RuntimeError(tr("사용자 지정 엔드포인트 URL 이 비어 있음 (설정 → API 키)", "Custom endpoint URL is empty (Settings → API Keys)"))
        headers = {"authorization": f"Bearer {key}", "x-api-key": key}
    else:
        raise RuntimeError(tr(f"API 방식이 아닌 프로필: {prov}", f"Not an API profile: {prov}"))
    if not key:
        raise RuntimeError(tr(f"{ {'openrouter': 'OpenRouter', 'anthropic': 'Anthropic', 'custom': '사용자 지정'}[prov] } API 키가 없음 (설정 → API 키)",
                                 f"No { {'openrouter': 'OpenRouter', 'anthropic': 'Anthropic', 'custom': 'custom'}[prov]} API key (Settings → API Keys)"))
    return base, key, headers


# ── 수정 범위 ───────────────────────────────────────────────────────────

SCOPE_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
SCOPE_SOURCE = "__scope__"          # injections 에서 '범위 안내를 마지막으로 넣은 버전' 을 기록하는 자리
# 샌드박스 안에서도 Claude Code·훅이 동작하도록 늘 쓰기를 허용하는 곳 (사용자 파일이 아닌 설정·캐시·임시)
SANDBOX_SYSTEM_DIRS = [".claude", ".local/share/claude", ".local/state/claude", ".cache", ".npm",
                       "Library/Caches", "Library/Keychains"]


def write_scope(con, sid: str):
    """None = 제한 없음. 아니면 [(위치 id, 이름, 실제 경로)] — 비어 있으면 어떤 파일도 못 고친다."""
    r = con.execute("SELECT write_limited FROM nodes WHERE session_id=?", (sid,)).fetchone()
    if not r or not r[0]:
        return None
    rows = con.execute("SELECT p.id, p.name, p.path FROM node_places np JOIN places p ON p.id = np.place_id"
                       " WHERE np.session_id=? ORDER BY p.sort, p.id", (sid,)).fetchall()
    return [(row[0], row[1] or os.path.basename(row[2].rstrip("/")) or row[2], os.path.realpath(row[2]))
            for row in rows]


def scope_key(scope) -> str:
    """범위를 나타내는 값 (all | p:정렬된 id). 안내를 다시 할지 판단할 때 쓴다."""
    return "all" if scope is None else "p:" + ",".join(str(i) for i in sorted(x[0] for x in scope))


def sandbox_scope(con, sid: str):
    """엄격 모드(셸 명령도 막기)일 때만 범위, 아니면 None"""
    scope = write_scope(con, sid)
    if scope is None:
        return None
    r = con.execute("SELECT write_strict FROM nodes WHERE session_id=?", (sid,)).fetchone()
    return scope if r and r[0] else None


def sandbox_key(scope) -> str:
    """실행 중인 Claude 에 적용된 샌드박스 (none | p:id…). 앱이 '다시 열어야 적용' 을 판단 (Swift 도 같은 규칙)"""
    return "none" if scope is None else scope_key(scope)


def always_writable() -> list[str]:
    """정리 대상이 아니라 늘 허용하는 곳: Claude 자신의 메모리·계획(~/.claude), 임시 폴더"""
    dirs = [os.path.join(str(HOME), ".claude"), "/private/tmp", "/private/var/folders", tempfile.gettempdir()]
    return [os.path.realpath(d) for d in dirs]


def path_inside(path: str, roots: list[str]) -> bool:
    rp = os.path.realpath(path).lower()      # macOS 기본 볼륨은 대소문자 구분 없음
    for r in roots:
        r = r.rstrip("/").lower()
        if rp == r or rp.startswith(r + "/"):
            return True
    return False


def _sb_str(p: str) -> str:
    return '"' + p.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _sb_rx(p: str) -> str:
    return "".join("\\" + c if c in ".^$|()[]{}*+?\\" else c for c in p)


def sandbox_profile(scope) -> str:
    """sandbox-exec 프로필: 쓰기는 고른 위치 + Claude Code 가 꼭 쓰는 곳만. 읽기·네트워크는 그대로."""
    home = os.path.realpath(str(HOME))
    allow = [f"  (subpath {_sb_str(p)})  ; {name}" for _, name, p in scope]
    sysdirs = [os.path.join(home, d) for d in SANDBOX_SYSTEM_DIRS]
    sysdirs += [os.path.realpath(str(APP_DIR)), "/private/tmp", "/private/var/folders", "/dev"]
    allow += [f"  (subpath {_sb_str(p)})" for p in sysdirs]
    allow.append(f'  (regex #"^{_sb_rx(home)}/\\.claude\\.json")')
    return "\n".join([
        ";; CtxGraph 가 만든 수정 범위 (앱 터미널에서 대화를 열 때마다 다시 만듦)",
        "(version 1)",
        "(allow default)",
        "(deny file-write*)",
        "(allow file-write*",
        *allow,
        ")",
        ";; ps·top 은 setuid 라 샌드박스 안에서 실행이 막히므로 샌드박스 밖에서 (읽기만 하는 도구)",
        '(allow process-exec (literal "/bin/ps") (literal "/usr/bin/top") (with no-sandbox))',
        "",
    ])


def scope_notice(con, sid: str, record: bool = True) -> str | None:
    """범위가 바뀌었을 때만 Claude 에게 한 번 알린다 (재개·압축 뒤에도 다시). record=False 면 미리보기 (안 씀)."""
    scope = write_scope(con, sid)
    key = scope_key(scope)
    ver = zlib.crc32(key.encode())
    row = con.execute("SELECT version FROM injections WHERE target=? AND source=?", (sid, SCOPE_SOURCE)).fetchone()
    if scope is None:
        if row is None:
            return None
        if record:
            con.execute("DELETE FROM injections WHERE target=? AND source=?", (sid, SCOPE_SOURCE))
        return tr("[CtxGraph 작업 폴더] 사용자가 이 대화의 작업 폴더 지정을 풀었습니다. 이제 파일 위치 제한이 없습니다.",
                  "[CtxGraph work folder] The user removed this conversation's work folder. There is no file location restriction anymore.")
    if row is not None and row[0] == ver:
        return None
    if record:
        con.execute("INSERT OR REPLACE INTO injections(target, source, version, at) VALUES(?,?,?,?)",
                    (sid, SCOPE_SOURCE, ver, time.time()))
    places = "\n".join(f"- {name}: {p}" for _, name, p in scope) or tr("- (없음 — 파일을 만들거나 고치지 말 것)",
                                                                       "- (none — do not create or edit files)")
    return tr("[CtxGraph 작업 폴더] 사용자가 파일 정리를 위해 이 대화의 작업 폴더를 정했습니다. "
              "이 대화에서 만들거나 고치는 파일(코드·스크립트·데이터·결과물·메모)은 아래 폴더 안에 두세요. "
              "셸 명령으로 파일을 만들 때도 마찬가지이고, 필요하면 그 안에 하위 폴더를 만들어 정리하세요. "
              "다른 곳의 파일은 읽기만 하세요. 잠깐 쓰고 버릴 파일은 /tmp 를 써도 됩니다. "
              "폴더 밖의 기존 파일을 꼭 고쳐야 하면 먼저 사용자에게 물어보세요.\n",
              "[CtxGraph work folder] To keep files organized, the user set work folders for this conversation. "
              "Put the files this conversation creates or edits (code, scripts, data, outputs, notes) inside the folders below. "
              "The same goes for files created with shell commands; make subfolders inside them if useful. "
              "Only read files elsewhere. Throwaway files may go in /tmp. "
              "If you really must edit an existing file outside these folders, ask the user first.\n") + places


def pretool_check(data: dict) -> None:
    """PreToolUse: 범위 밖 파일 도구 사용을 막는다. 모든 대화의 파일 편집마다 불리므로 가볍게 (스키마·마이그레이션 없이)."""
    if data.get("tool_name") not in SCOPE_TOOLS or not DB_PATH.exists():
        return
    sid = data.get("session_id")
    ti = data.get("tool_input") or {}
    path = ti.get("file_path") or ti.get("notebook_path") or ti.get("path")
    if not sid or not isinstance(path, str) or not path:
        return
    con = sqlite3.connect(str(DB_PATH), timeout=3)
    try:
        if schema_version(con) > SCHEMA_VERSION:
            return
        scope = write_scope(con, sid)
    except sqlite3.Error:
        return                                  # 아직 마이그레이션 전 DB 등 → 막지 않음
    finally:
        con.close()
    if scope is None:
        return
    if not os.path.isabs(path):
        path = os.path.join(data.get("cwd") or os.getcwd(), path)
    if path_inside(path, [p for _, _, p in scope] + always_writable()):
        return
    places = "\n".join(f"- {name}: {p}" for _, name, p in scope) or tr("- (없음)", "- (none)")
    reason = tr(f"정리 규칙: 이 대화의 파일은 작업 폴더 안에만 둡니다. 그래서 이 위치는 쓰지 않았습니다: {path}\n"
                f"작업 폴더:\n{places}\n"
                "새 파일이면 작업 폴더 안의 알맞은 곳에 다시 만드세요. 폴더 밖의 기존 파일을 꼭 고쳐야 하면 "
                "사용자에게 물어보세요 (CtxGraph 앱에서 작업 폴더를 추가할 수 있음).",
                f"Organizing rule: this conversation keeps its files inside its work folders, so this location was not written: {path}\n"
                f"Work folders:\n{places}\n"
                "If it's a new file, create it again in a suitable place inside a work folder. If you really must edit an "
                "existing file outside them, ask the user (work folders can be added in the CtxGraph app).")
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                             "permissionDecisionReason": reason}}, ensure_ascii=False))
    log(f"scope: 막음 {sid[:8]} {data.get('tool_name')} {path}")


def launch_env(con, mid: str | None) -> dict:
    """앱 터미널에서 이 모델로 Claude Code 를 띄울 때 쓸 env·인자. orc(or.zsh) 와 같은 방식."""
    m = model_row(con, mid)
    prov = m["provider"]
    if prov == "subscription":
        return {"id": m["id"], "name": m["name"], "env": {},
                "args": ["--model", m["model"]] if m["model"] else []}
    base, key, _ = endpoint(con, m)
    main = m["model"]
    if not main:
        raise RuntimeError(tr(f"프로필 {m['name']} 에 모델 이름이 없음", f"Profile {m['name']} has no model name"))
    small = m["small_model"] or (setting(con, "or_small") if prov == "openrouter" else "") or main
    if prov == "anthropic":
        env = {"ANTHROPIC_API_KEY": key, "ANTHROPIC_MODEL": main,
               "ANTHROPIC_DEFAULT_HAIKU_MODEL": small, "CLAUDE_CODE_SUBAGENT_MODEL": small}
    else:
        env = {
            "ANTHROPIC_BASE_URL": base,
            "ANTHROPIC_AUTH_TOKEN": key,
            "ANTHROPIC_API_KEY": "",
            "ANTHROPIC_MODEL": main,
            "ANTHROPIC_DEFAULT_OPUS_MODEL": main,
            "ANTHROPIC_DEFAULT_SONNET_MODEL": main,
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": small,
            "CLAUDE_CODE_SUBAGENT_MODEL": small,
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            # 비 Anthropic 모델은 턴별 effort 를 400 으로 거절 (orc 10/24)
            "CLAUDE_CODE_MODEL_CAPABILITIES": "-per_turn_effort",
            "API_TIMEOUT_MS": "600000",
        }
        vision = setting(con, "or_vision")
        if prov == "openrouter" and vision:
            env["CLAUDE_CODE_EXTRA_BODY"] = json.dumps({"models": [vision]})
    return {"id": m["id"], "name": m["name"], "env": env, "args": []}


def http_messages(con, m, system: str, prompt: str, max_tokens: int = 12000, timeout: int = 240) -> str:
    """Anthropic Messages 형식으로 직접 호출 (OpenRouter·Anthropic·호환 엔드포인트 공통)."""
    base, _, auth = endpoint(con, m)
    body = json.dumps({"model": m["model"], "max_tokens": max_tokens, "system": system,
                       "messages": [{"role": "user", "content": prompt}]}).encode()
    req = urllib.request.Request(f"{base}/v1/messages", data=body, method="POST", headers={
        "content-type": "application/json", "anthropic-version": "2023-06-01",
        "user-agent": f"CtxGraph/{VERSION}", **auth})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            d = json.load(r)
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{m['name']} HTTP {e.code}: {e.read().decode('utf-8', 'replace')[:300]}") from None
    except urllib.error.URLError as e:
        raise RuntimeError(tr(f"{m['name']} 연결 실패: {e.reason}", f"{m['name']} connection failed: {e.reason}")) from None
    text = "".join(b.get("text", "") for b in d.get("content", []) if b.get("type") == "text")
    if not text:
        why = tr("추론에 토큰을 다 씀", "used all tokens on reasoning") if d.get("stop_reason") == "max_tokens" else tr("텍스트 없음", "no text")
        raise RuntimeError(tr(f"{m['name']} 빈 응답", f"{m['name']} empty response") + f" ({why}, stop_reason={d.get('stop_reason')})")
    return text


def call_model(prompt: str, con=None) -> str:
    con = con or connect()
    m = model_row(con, setting(con, "summary_model"))
    if m["provider"] != "subscription":
        return http_messages(con, m, summary_system(), prompt)
    claude = claude_bin()
    if not claude:
        raise RuntimeError(tr("claude 실행 파일을 찾지 못함", "claude executable not found"))
    WORK_DIR.mkdir(parents=True, exist_ok=True)
    cmd = [claude, "-p", "--model", m["model"] or SUMMARY_MODEL, "--no-session-persistence",
           "--setting-sources", "project", "--tools", "", "--system-prompt", summary_system()]
    r = subprocess.run(cmd, input=prompt, capture_output=True, text=True,
                       timeout=SUMMARY_TIMEOUT, cwd=str(WORK_DIR), env=clean_env())
    if r.returncode != 0:
        raise RuntimeError(tr("claude -p 실패", "claude -p failed") + f"({r.returncode}): {(r.stderr or r.stdout).strip()[:300]}")
    return r.stdout


def build_summary_prompt(title: str, cwd: str, prev: str | None, convo: str) -> str:
    if tr("ko", "en") == "en":
        if prev:
            intro = ("Below are this conversation's previous summary and what happened since. "
                     "Update the previous summary with the new content: replace reversed decisions with the new ones, "
                     "and move finished work into 'Current state'.\n\n"
                     f"<previous_summary>\n{prev}\n</previous_summary>\n\n<new_messages>\n{convo}\n</new_messages>")
        else:
            intro = f"Below is this conversation's transcript.\n\n<transcript>\n{convo}\n</transcript>"
        return (f"Conversation title: {title}\nWorking folder: {cwd}\n[U]=user, [A]=Claude\n\n{intro}\n\n"
                "Output in English, exactly in this format.\n"
                "<summary>\n"
                "- Goal: what this conversation is trying to do\n"
                "- Decisions & conclusions: what has been settled so far (include supporting numbers)\n"
                "- Current state: how far it has got\n"
                "- Open work & questions:\n"
                "- Key files, paths, commands:\n"
                "</summary>\n"
                "<delta>2–4 lines on what changed since the previous summary. Leave empty if there was no previous summary or nothing changed</delta>\n"
                "Rules: summary under 1500 characters. Write 'none' for items with nothing to report. Facts only, no guessing.")
    if prev:
        intro = ("아래는 이 대화의 이전 요약과, 그 이후 새로 진행된 부분이다. "
                 "이전 요약을 새 내용으로 갱신해라. 뒤집힌 결정은 새 결정으로 바꾸고, 끝난 일은 '현재 상태'로 옮겨라.\n\n"
                 f"<previous_summary>\n{prev}\n</previous_summary>\n\n<new_messages>\n{convo}\n</new_messages>")
    else:
        intro = f"아래는 이 대화의 기록이다.\n\n<transcript>\n{convo}\n</transcript>"
    return (f"대화 제목: {title}\n작업 폴더: {cwd}\n[U]=사용자, [A]=Claude\n\n{intro}\n\n"
            "다음 형식 그대로 한국어로 출력해라.\n"
            "<summary>\n"
            "- 목표: 이 대화가 하려는 일\n"
            "- 결정·결론: 지금까지 정해진 것 (근거 수치가 있으면 포함)\n"
            "- 현재 상태: 어디까지 됐는지\n"
            "- 남은 일·열린 질문:\n"
            "- 중요한 파일·경로·명령:\n"
            "</summary>\n"
            "<delta>이전 요약 대비 새로 바뀐 점 2~4줄. 이전 요약이 없거나 바뀐 게 없으면 비워 둘 것</delta>\n"
            "규칙: summary 는 1500자 이내. 해당 내용이 없는 항목은 '없음'. 사실만 쓰고 추측하지 말 것.")


def _tag(text: str, name: str) -> str | None:
    m = re.search(rf"<{name}>(.*?)</{name}>", text, re.S)
    return m.group(1).strip() if m else None


def backfill_summary_runs(con) -> None:
    """summary_runs 가 생기기 전의 요약 기록을 로그(ctxgraph.log)에서 옮겨 온다 (연도는 로그에 없어 올해로)."""
    try:
        lines = LOG_PATH.read_text(errors="replace").splitlines()
    except OSError:
        return
    year, now = time.localtime().tm_year, time.time()
    for ln in lines:
        m = re.match(r"(\d\d-\d\d \d\d:\d\d:\d\d) (summarized (\w+) v\d+ \(\d+ msgs, (\w+)(?:, ([^)]+))?\)"
                     r"|summarize failed (\w+):)", ln)
        if not m:
            continue
        try:
            at = time.mktime(time.strptime(f"{year}-{m.group(1)}", "%Y-%m-%d %H:%M:%S"))
        except ValueError:
            continue
        if at > now + 86400:
            at = time.mktime(time.strptime(f"{year - 1}-{m.group(1)}", "%Y-%m-%d %H:%M:%S"))
        ok = m.group(3) is not None
        con.execute("INSERT INTO summary_runs(at, sid, model, ok, incremental) VALUES(?,?,?,?,?)",
                    (at, m.group(3) or m.group(6), (m.group(5) or "claude-haiku") if ok else None, 1 if ok else 0,
                     (1 if m.group(4) == "incr" else 0) if ok else None))


def record_run(con, sid: str, ok: bool, t0: float, prompt: str, out: str | None, incremental: bool) -> None:
    try:
        con.execute("INSERT INTO summary_runs(at, sid, model, ok, secs, in_chars, out_chars, incremental)"
                    " VALUES(?,?,?,?,?,?,?,?)",
                    (time.time(), sid, setting(con, "summary_model"), 1 if ok else 0, time.time() - t0,
                     len(prompt), len(out or ""), 1 if incremental else 0))
    except sqlite3.Error as e:
        log(f"record_run error: {e!r}")


def usage(con) -> dict:
    now = time.time()
    lt = time.localtime(now)
    day0 = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1))
    out = {"today": 0, "week": 0, "month": 0, "failed_week": 0, "by_model": {}, "last_at": None,
           "summary_model": setting(con, "summary_model")}
    for r in con.execute("SELECT at, ok, model FROM summary_runs WHERE at > ? ORDER BY at", (now - 30 * 86400,)):
        out["month"] += 1
        if r["at"] >= now - 7 * 86400:
            out["week"] += 1
            if not r["ok"]:
                out["failed_week"] += 1
            k = r["model"] or "?"
            out["by_model"][k] = out["by_model"].get(k, 0) + 1
        if r["at"] >= day0:
            out["today"] += 1
        out["last_at"] = r["at"]
    return out


def summarize(con, sid: str, force: bool = False) -> bool:
    n = node(con, sid)
    if not n:
        raise SystemExit(f"노드가 아님: {sid}")
    LOCK_DIR.mkdir(parents=True, exist_ok=True)
    with open(LOCK_DIR / f"{sid}.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)          # 같은 대화를 동시에 두 번 요약하지 않게
        n = node(con, sid)
        path = Path(n["transcript_path"] or "/nonexistent")
        if not path.is_file():
            t = find_transcript(sid)
            if not t:
                con.execute("UPDATE nodes SET summary_error=? WHERE session_id=?", (tr("대화 기록 파일 없음", "transcript file not found"), sid))
                return False
            path = t
            con.execute("UPDATE nodes SET transcript_path=? WHERE session_id=?", (str(t), sid))
        size = path.stat().st_size
        if not force and n["summary_version"] and size <= n["summary_src_size"]:
            return False
        incremental = bool(n["summary"]) and not force and n["summary_src_size"] <= size
        msgs, end = read_messages(path, n["summary_src_size"] if incremental else 0)
        if incremental and not msgs:      # 새로 붙은 줄에 대화 내용이 없음 → 요약은 그대로 최신
            con.execute("UPDATE nodes SET summary_src_size=?, summary_src_at=COALESCE(?, summary_src_at)"
                        " WHERE session_id=?", (end, last_timestamp(path, end), sid))
            return False
        if not msgs:
            con.execute("UPDATE nodes SET summary_error=? WHERE session_id=?", (tr("요약할 메시지가 없음", "no messages to summarize"), sid))
            return False
        title = title_of(con, sid)
        prompt = build_summary_prompt(title, short_path(n["cwd"]),
                                      n["summary"] if incremental else None,
                                      render_messages(msgs, TRANSCRIPT_BUDGET))
        con.execute("UPDATE nodes SET summarizing_at=? WHERE session_id=?", (time.time(), sid))
        t0, out = time.time(), None
        try:
            out = call_model(prompt, con)
            summary = _tag(out, "summary")
            if not summary:
                raise RuntimeError(tr("형식이 맞지 않는 출력", "malformed output") + f": {one_line(out, 200)}")
            delta = _tag(out, "delta") or None
            if not n["summary"]:
                delta = None
            con.execute(
                "UPDATE nodes SET summary=?, delta=?, summary_version=summary_version+1, summary_at=?,"
                " summary_src_size=?, summary_src_at=?, summary_error=NULL, summarizing_at=NULL WHERE session_id=?",
                (summary, delta, time.time(), end, last_timestamp(path, end), sid))
            log(f"summarized {sid[:8]} v{n['summary_version'] + 1} ({len(msgs)} msgs, {'incr' if incremental else 'full'},"
                f" {setting(con, 'summary_model')})")
            record_run(con, sid, True, t0, prompt, out, incremental)
            return True
        except Exception as e:  # noqa: BLE001 — 실패는 앱에 표시
            con.execute("UPDATE nodes SET summary_error=?, summarizing_at=NULL WHERE session_id=?",
                        (str(e)[:500], sid))
            log(f"summarize failed {sid[:8]}: {e}")
            record_run(con, sid, False, t0, prompt, out, incremental)
            return False


def summarize_job(sid: str) -> None:
    con = connect()
    try:
        t0 = time.time()
        while time.time() - t0 < JOB_MAX_WAIT:
            n = node(con, sid)
            if not n:
                return
            try:
                mtime = os.stat(n["transcript_path"]).st_mtime
            except OSError:
                break
            now = time.time()
            if now - mtime >= QUIET and now - (n["summary_at"] or 0) >= COOLDOWN:
                break
            time.sleep(5)
        summarize(con, sid)
    finally:
        con.execute("UPDATE nodes SET job_started_at=NULL WHERE session_id=?", (sid,))


def schedule_summary(con, sid: str) -> None:
    """Stop 훅: 맥락을 보내는(나가는 연결이 있는) 노드이고 기록이 늘었으면 백그라운드 요약 작업을 하나만 띄운다."""
    n = node(con, sid)
    if not n or not targets_of(con, sid):
        return
    try:
        size = os.stat(n["transcript_path"]).st_size
    except OSError:
        return
    if size <= n["summary_src_size"]:
        return
    now = time.time()
    cur = con.execute(
        "UPDATE nodes SET job_started_at=? WHERE session_id=? AND (job_started_at IS NULL OR job_started_at < ?)",
        (now, sid, now - JOB_MAX_WAIT - 600))
    if cur.rowcount == 0:
        return                       # 이미 예약된 작업이 최신 기록까지 요약한다
    APP_DIR.mkdir(parents=True, exist_ok=True)
    with open(LOG_PATH, "a") as logf:
        subprocess.Popen([sys.executable, "-I", os.path.abspath(__file__), "summarize-job", sid],
                         stdin=subprocess.DEVNULL, stdout=logf, stderr=logf,
                         start_new_session=True, close_fds=True)


def spawn_summarize(sid: str) -> None:
    """앱·CLI 에서 연결을 만들 때: 요약이 없는 노드를 바로 백그라운드로 요약."""
    APP_DIR.mkdir(parents=True, exist_ok=True)
    with open(LOG_PATH, "a") as logf:
        subprocess.Popen([sys.executable, "-I", os.path.abspath(__file__), "summarize", sid],
                         stdin=subprocess.DEVNULL, stdout=logf, stderr=logf,
                         start_new_session=True, close_fds=True)


# ── 주입 ────────────────────────────────────────────────────────────────

INJECT_HEADER_EN = (
    "[Context graph] In the CtxGraph app, the user linked other conversations so their context flows into this one. "
    "Below are their latest summaries. Use them when relevant to the current request; for more detail, "
    "read the transcript (jsonl) file shown. Don't repeat this block back to the user."
)
INJECT_HEADER = (
    "[맥락 그래프] 사용자가 CtxGraph 앱에서 다른 대화의 맥락이 이 대화로 들어오도록 연결해 두었습니다. "
    "아래는 그 대화의 최신 요약입니다. 지금 요청과 관련 있을 때 활용하고, 더 자세한 원문이 필요하면 "
    "표시된 transcript(jsonl) 파일을 읽으세요. 이 블록 자체를 사용자에게 되풀이하지는 마세요."
)


def _fmt_time(ts: float | None) -> str:
    return time.strftime("%m-%d %H:%M", time.localtime(ts)) if ts else "?"


def plan_injection(con, sid: str) -> tuple[list[dict], list[str]]:
    """다음 메시지에 들어갈 것 (DB 에 쓰지 않음): 들어오는 연결마다 {src, title, version, mode, block}
    mode = full | delta | same(이미 받음, 안 들어감) | none(요약 없음). 그리고 끊긴 연결의 src 목록."""
    prev = {r["source"]: r["version"]
            for r in con.execute("SELECT source, version FROM injections WHERE target=? AND source<>?",
                                 (sid, SCOPE_SOURCE))}
    items: list[dict] = []
    for nid in sources_of(con, sid):
        n = node(con, nid)
        if not n:
            continue
        title = title_of(con, nid)
        v, last = n["summary_version"], prev.pop(nid, None)
        item = {"src": nid, "title": title, "version": v, "received": last, "block": None,
                "src_at": n["summary_src_at"] or n["summary_at"]}
        if not v:
            item["mode"] = "none"
        elif last == v:
            item["mode"] = "same"
        else:
            try:
                mtime = os.stat(n["transcript_path"]).st_mtime
            except OSError:
                mtime = None
            if last is not None and last == v - 1 and n["delta"]:
                item["mode"] = "delta"
                item["block"] = tr(f"## «{title}» 업데이트 (요약 v{v}, 마지막 활동 {_fmt_time(mtime)})\n{n['delta']}",
                                    f"## «{title}» update (summary v{v}, last active {_fmt_time(mtime)})\n{n['delta']}")
            else:
                item["mode"] = "full"
                item["block"] = (tr(f"## «{title}»\n- 폴더: {short_path(n['cwd'])} · 마지막 활동: {_fmt_time(mtime)} · 요약 v{v}\n",
                                    f"## «{title}»\n- folder: {short_path(n['cwd'])} · last active: {_fmt_time(mtime)} · summary v{v}\n")
                                 + f"- transcript: {n['transcript_path']}\n{n['summary']}")
        items.append(item)
    return items, list(prev)


def compose_injection(con, items: list[dict], gone: list[str]) -> str | None:
    blocks = [i["block"] for i in items if i["block"]]
    for g_id in gone:                      # 들어오던 연결이 끊긴 대화
        g = node(con, g_id)
        t = title_of(con, g_id)
        blocks.append(tr(f"## «{t}» 연결 해제됨\n"
                         "이 대화의 맥락은 더 이상 갱신되지 않습니다. 앞서 받은 요약은 오래된 정보일 수 있습니다.",
                         f"## «{t}» unlinked\n"
                         "This conversation's context will no longer be updated. The summary received earlier may be out of date."))
    if not blocks:
        return None
    body = "\n\n".join(blocks)
    if len(body) > INJECT_BUDGET:
        body = body[:INJECT_BUDGET] + tr("\n…(길어서 잘림 — 필요하면 transcript 를 직접 읽으세요)", "\n…(truncated — read the transcript directly if needed)")
    return tr(INJECT_HEADER, INJECT_HEADER_EN) + "\n\n" + body


def build_injection(con, sid: str) -> str | None:
    """UserPromptSubmit: 넣을 맥락을 만들고, 무엇을 넣었는지 injections 에 기록"""
    items, gone = plan_injection(con, sid)
    now = time.time()
    for i in items:
        if i["block"]:
            con.execute("INSERT OR REPLACE INTO injections(target, source, version, at, src_at) VALUES(?,?,?,?,?)",
                        (sid, i["src"], i["version"], now, i["src_at"]))
    for g_id in gone:
        con.execute("DELETE FROM injections WHERE target=? AND source=?", (sid, g_id))
    return compose_injection(con, items, gone)


def preview_injection(con, sid: str) -> dict:
    items, gone = plan_injection(con, sid)
    text = "\n\n".join(x for x in (scope_notice(con, sid, record=False), compose_injection(con, items, gone)) if x) or None
    return {"text": text, "chars": len(text or ""), "budget": INJECT_BUDGET,
            "items": [{k: i[k] for k in ("src", "title", "version", "received", "mode")} for i in items],
            "gone": [title_of(con, g, None) for g in gone]}


def last_assistant_line(tp: str | None) -> str | None:
    """대화 기록 끝에서 마지막 Claude 답의 첫 줄 (알림 미리보기용)"""
    if not tp:
        return None
    try:
        with open(tp, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - 262_144))
            buf = fh.read()
    except OSError:
        return None
    for raw in reversed(buf.splitlines()):
        if b'"assistant"' not in raw:
            continue
        try:
            texts = assistant_texts(json.loads(raw))
        except ValueError:
            continue
        if texts:
            line = next((x for x in texts[-1].splitlines() if x.strip()), "")
            return one_line(line.lstrip("#*- ").strip(), 160)
    return None


def add_term_event(con, tab: str, kind: str, message: str | None) -> None:
    con.execute("INSERT INTO term_events(tab, kind, message, at) VALUES(?,?,?,?)", (tab, kind, message, time.time()))
    con.execute("DELETE FROM term_events WHERE id < (SELECT MAX(id) - 500 FROM term_events)")


def record_term_event(con, data: dict) -> None:
    """앱 터미널 탭에서 돈 Claude 가 한 턴을 끝냈거나(Stop) 입력을 기다리면(Notification) 앱에 알린다."""
    tab = os.environ.get("CTXGRAPH_TAB")
    if not tab and os.environ.get("TERM_PROGRAM") == "CtxGraph":
        tab = data.get("session_id")          # 이 기능 전에 띄운 탭 (탭 ID = 세션 ID)
    if not tab:
        return
    if data.get("hook_event_name") == "Notification":
        add_term_event(con, tab, "input", one_line(data.get("message") or tr("입력을 기다려요", "Waiting for your input"), 160))
    else:
        msg = data.get("last_assistant_message")
        msg = one_line(msg, 160) if isinstance(msg, str) and msg.strip() else last_assistant_line(data.get("transcript_path"))
        add_term_event(con, tab, "done", msg or tr("응답을 마쳤어요", "Finished responding"))


def set_health(con, key: str, msg: str | None) -> None:
    """앱이 보여 줄 고장 알림 (settings.health_*). 바뀔 때만 쓴다."""
    try:
        cur = con.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
        if (cur[0] if cur else "") != (msg or ""):
            con.execute("INSERT OR REPLACE INTO settings(key, value) VALUES(?,?)", (key, msg or ""))
    except sqlite3.Error:
        pass


def check_hook_payload(con, data) -> None:
    """Claude Code 가 훅에 넘기는 형식이 바뀌면 조용히 안 되는 대신 앱에 알린다"""
    ev = data.get("hook_event_name") if isinstance(data, dict) else None
    if not ev:
        set_health(con, "health_hook", tr("훅 입력에 hook_event_name 이 없어요 — Claude Code 훅 형식이 바뀐 것 같아요",
                                          "Hook input has no hook_event_name — the Claude Code hook format may have changed"))
    elif ev in ("UserPromptSubmit", "Stop", "SessionStart") and not data.get("session_id"):
        set_health(con, "health_hook", tr(f"{ev} 훅 입력에 session_id 가 없어요 — Claude Code 훅 형식이 바뀐 것 같아요",
                                          f"{ev} hook input has no session_id — the Claude Code hook format may have changed"))
    elif ev == "UserPromptSubmit":
        set_health(con, "health_hook", None)


def scan_health(con) -> str | None:
    """최근 대화 기록들에서 대화 내용을 거의 못 찾으면 형식이 바뀐 것"""
    rows = con.execute("SELECT n_prompts, first_prompt FROM sessions WHERE size > 4096"
                       " ORDER BY mtime DESC LIMIT 40").fetchall()
    bad = sum(1 for r in rows if not r["n_prompts"] and not r["first_prompt"])
    if len(rows) >= 5 and bad >= 0.8 * len(rows):
        return tr(f"최근 대화 기록 {len(rows)}개 중 {bad}개에서 대화 내용을 못 찾았어요 — "
                  "Claude Code 기록 형식이 바뀐 것 같아요. CtxGraph 업데이트를 확인해 주세요",
                  f"No conversation content found in {bad} of the {len(rows)} most recent transcripts — "
                  "the Claude Code transcript format may have changed. Check for a CtxGraph update")
    return None


def handle_hook() -> None:
    if os.environ.get("CTXGRAPH_INTERNAL"):
        return
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    if data.get("hook_event_name") == "PreToolUse":
        pretool_check(data)
        return
    try:
        con = connect(create=False)
    except NewerSchema as e:
        log(f"hook: DB v{e.version} > v{SCHEMA_VERSION} — 건너뜀")
        return
    if con is None:
        return
    sid = data.get("session_id")
    event = data.get("hook_event_name")
    check_hook_payload(con, data)
    if event in ("Stop", "Notification"):
        try:
            record_term_event(con, data)
        except sqlite3.Error as e:
            log(f"term event error: {e!r}")
        if event == "Notification":
            return
    if not sid or not node(con, sid):
        return
    tp = data.get("transcript_path")
    if tp and os.path.exists(tp):
        con.execute("UPDATE nodes SET transcript_path=? WHERE session_id=? AND transcript_path<>?", (tp, sid, tp))
    if event == "UserPromptSubmit":
        parts = [x for x in (scope_notice(con, sid), build_injection(con, sid)) if x]
        ctx = "\n\n".join(parts)
        if ctx:
            print(json.dumps({"hookSpecificOutput": {
                "hookEventName": "UserPromptSubmit", "additionalContext": ctx}}, ensure_ascii=False))
    elif event == "SessionStart":
        if data.get("source") in ("resume", "compact"):
            con.execute("DELETE FROM injections WHERE target=?", (sid,))
    elif event == "Stop":
        schedule_summary(con, sid)


# ── CLI ─────────────────────────────────────────────────────────────────

def resolve(con, key: str, allow_sessions: bool = True) -> str:
    """세션 ID·ID 앞부분·'current'·제목 검색어 → 세션 ID. 모호하면 후보를 보여 주고 종료."""
    if key == "current":
        sid = os.environ.get("CLAUDE_CODE_SESSION_ID")
        if not sid:
            raise SystemExit(tr("CLAUDE_CODE_SESSION_ID 가 없음 — Claude Code 대화 안에서 실행해야 함",
                               "CLAUDE_CODE_SESSION_ID is not set — run this inside a Claude Code conversation"))
        return sid
    if re.fullmatch(r"[0-9a-f-]{36}", key):
        return key
    if re.fullmatch(r"[0-9a-f]{4,}", key):
        rows = con.execute("SELECT DISTINCT session_id FROM sessions WHERE session_id LIKE ?", (key + "%",)).fetchall()
        if len(rows) == 1:
            return rows[0]["session_id"]
    q = f"%{key}%"
    nodes = [r["session_id"] for r in con.execute("SELECT session_id FROM nodes").fetchall()
             if key.lower() in title_of(con, r["session_id"]).lower()]
    if len(nodes) == 1:
        return nodes[0]
    cands = nodes
    if not cands and allow_sessions:
        cands = [r["session_id"] for r in con.execute(
            "SELECT session_id FROM sessions WHERE agent_name LIKE ? OR ai_title LIKE ? OR first_prompt LIKE ?"
            " OR session_id IN (SELECT session_id FROM labels WHERE label LIKE ?)"
            " ORDER BY mtime DESC LIMIT 10", (q, q, q, q))]
        if len(cands) == 1:
            return cands[0]
    if not cands:
        raise SystemExit(tr(f"'{key}' 에 맞는 대화를 찾지 못함", f"No conversation matches '{key}'"))
    lines = [tr(f"'{key}' 후보가 여러 개 — 세션 ID 앞부분으로 다시 지정:", f"'{key}' matches several conversations — specify a session ID prefix:")]
    for c in cands[:10]:
        lines.append(f"  {c[:8]}  {title_of(con, c)}")
    raise SystemExit("\n".join(lines))


def add_node(con, sid: str, x: float | None = None, y: float | None = None) -> bool:
    if node(con, sid):
        return False
    path = find_transcript(sid)
    if not path:
        raise SystemExit(tr(f"대화 기록을 찾지 못함: {sid}", f"Transcript not found: {sid}"))
    r = con.execute("SELECT cwd FROM sessions WHERE session_id=?", (sid,)).fetchone()
    cwd = r["cwd"] if r else parse_meta(path, None)["cwd"]
    space = current_space(con)
    if x is None or y is None:
        k = con.execute("SELECT COUNT(*) FROM placements WHERE space=?", (space,)).fetchone()[0]
        x, y = 260 + (k % 4) * 300, 160 + (k // 4) * 170
    now = time.time()
    con.execute("INSERT INTO nodes(session_id, transcript_path, cwd, added_at) VALUES(?,?,?,?)",
                (sid, str(path), cwd, now))
    con.execute("INSERT OR IGNORE INTO placements(session_id, space, x, y, added_at) VALUES(?,?,?,?,?)",
                (sid, space, x, y, now))
    return True


def spaces_of(con, sid: str) -> list[str]:
    """이 대화가 놓인 작업 공간들 (놓은 순서)"""
    return [r[0] for r in con.execute("SELECT space FROM placements WHERE session_id=? ORDER BY added_at", (sid,))]


def current_space(con) -> str:
    """앱에서 지금 보고 있는 작업 공간 (없어졌으면 기본)."""
    sp = setting(con, "current_space") or DEFAULT_SPACE
    if not con.execute("SELECT 1 FROM spaces WHERE id=?", (sp,)).fetchone():
        return DEFAULT_SPACE
    return sp


def space_name(con, sp: str | None) -> str:
    r = con.execute("SELECT name FROM spaces WHERE id=?", (sp or DEFAULT_SPACE,)).fetchone()
    return r[0] if r else tr("기본", "Main")


def link(con, src: str, dst: str, both: bool = False) -> bool:
    if src == dst:
        raise SystemExit(tr("같은 대화끼리는 연결할 수 없음", "Can't link a conversation to itself"))
    for s in (src, dst):
        add_node(con, s)
    now, new = time.time(), 0
    for s, d in ([(src, dst), (dst, src)] if both else [(src, dst)]):
        new += con.execute("INSERT OR IGNORE INTO links(src, dst, created_at) VALUES(?,?,?)",
                           (s, d, now)).rowcount
        if not node(con, s)["summary_version"]:      # 맥락을 보내는 쪽만 요약이 필요
            spawn_summarize(s)
    return new > 0


def arrow(con, a: str, b: str) -> str:
    ab = con.execute("SELECT 1 FROM links WHERE src=? AND dst=?", (a, b)).fetchone()
    ba = con.execute("SELECT 1 FROM links WHERE src=? AND dst=?", (b, a)).fetchone()
    sym = "⇄" if ab and ba else "→" if ab else "←" if ba else tr("(연결 없음)", "(not linked)")
    return f"«{title_of(con, a)}» {sym} «{title_of(con, b)}»"


def print_status(con, sid: str) -> None:
    n = node(con, sid)
    if not n:
        print(tr(f"이 대화({sid[:8]})는 아직 그래프에 없음. /ctx add 로 추가.", f"This conversation ({sid[:8]}) isn't in the graph yet. Add it with /ctx add."))
        return
    print(f"«{title_of(con, sid)}»  ({sid[:8]})  " + tr("요약", "summary") + f" v{n['summary_version']}"
          + tr("  · 작업 공간", "  · workspace") + " " + ", ".join(f"«{space_name(con, sp)}»" for sp in spaces_of(con, sid) or [DEFAULT_SPACE])
          + (f"  ⚠ {n['summary_error']}" if n["summary_error"] else ""))
    srcs, dsts = sources_of(con, sid), targets_of(con, sid)
    if not srcs and not dsts:
        print(tr("연결된 대화 없음", "No linked conversations"))
    for nid in srcs:
        m = node(con, nid)
        inj = con.execute("SELECT version FROM injections WHERE target=? AND source=?", (sid, nid)).fetchone()
        state = tr("요약", "summary") + f" v{m['summary_version']}" if m["summary_version"] else tr("요약 준비 중", "summary in progress")
        got = tr("받은 버전", "received") + f" v{inj['version']}" if inj else tr("아직 안 받음", "not received yet")
        mark = "⇄" if nid in dsts else "←"
        print(f"  {mark} " + tr("받음", "from") + f": «{title_of(con, nid)}» ({nid[:8]}) · {state} · {got}")
    for nid in dsts:
        if nid in srcs:
            continue
        m = node(con, nid)
        print("  → " + tr("보냄", "to") + f": «{title_of(con, nid)}» ({nid[:8]})")


# ── Claude Code 훅·/ctx 스킬 설치 ──────────────────────────────────────

HOOK_EVENTS = [            # (이벤트, matcher)
    ("UserPromptSubmit", None),
    ("SessionStart", None),
    ("Stop", None),
    ("Notification", None),
    ("PreToolUse", "Edit|Write|MultiEdit|NotebookEdit"),
]
HOOK_MARK = "ctxgraph.py hook"
SKILL_MARK = "<!-- ctxgraph:managed -->"


def claude_dir() -> Path:
    return Path(os.environ.get("CLAUDE_CONFIG_DIR") or HOME / ".claude")


def claude_settings_path(args: list[str]) -> Path:
    if "--settings" in args and args.index("--settings") + 1 < len(args):
        return Path(args[args.index("--settings") + 1]).expanduser()
    return claude_dir() / "settings.json"


def hook_command() -> str:
    import shlex
    return f"python3 -I {shlex.quote(os.path.abspath(__file__))} hook"


# 우리 훅 명령: …/ctxgraph.py hook — 경로에 공백이 있으면 따옴표로 감싸이므로 (배포판의 Application Support) 따옴표도 허용
_HOOK_RE = re.compile(r"ctxgraph\.py['\"]?\s+hook(?:\s|$)")


def _our_hook(h) -> bool:
    return isinstance(h, dict) and bool(_HOOK_RE.search(str(h.get("command", ""))))


def _read_settings(path: Path) -> dict:
    if not path.exists():
        return {}
    data = json.loads(path.read_text() or "{}")
    if not isinstance(data, dict):
        raise ValueError(tr("settings.json 이 객체가 아님", "settings.json is not an object"))
    return data


def _write_settings(path: Path, data: dict) -> str | None:
    """백업을 남기고 원자적으로 쓴다. 백업 경로를 돌려준다."""
    backup = None
    if path.exists():
        stamp = time.strftime('%Y%m%d-%H%M%S')
        backup = path.with_name(f"{path.name}.bak-ctxgraph-{stamp}")
        k = 2
        while backup.exists():
            backup = path.with_name(f"{path.name}.bak-ctxgraph-{stamp}-{k}")
            k += 1
        shutil.copy2(path, backup)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".ctxgraph-tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    os.replace(tmp, path)
    return str(backup) if backup else None


def _skill_path() -> Path:
    return claude_dir() / "skills" / "ctx" / "SKILL.md"


def skill_state() -> str:
    p = _skill_path()
    if not p.exists():
        return "none"
    try:
        return "managed" if SKILL_MARK in p.read_text() else "custom"
    except OSError:
        return "custom"


def _skill_text() -> str | None:
    tpl = Path(__file__).with_name(tr("ctx-skill.md", "ctx-skill.en.md"))
    if not tpl.exists():
        tpl = Path(__file__).with_name("ctx-skill.md")
    try:
        text = tpl.read_text()
    except OSError:
        return None
    import shlex
    cli = f"python3 -I {shlex.quote(os.path.abspath(__file__))}"
    return text.replace("{{CLI}}", cli).replace("{{MARK}}", SKILL_MARK)


def hooks_status(path: Path) -> dict:
    claude = claude_bin()
    version = None
    if claude:
        try:
            r = subprocess.run([claude, "--version"], capture_output=True, text=True, timeout=5, env=clean_env())
            version = (r.stdout.strip().split() or [None])[0]
        except (OSError, subprocess.SubprocessError):
            pass
    out = {"settings": str(path), "command": hook_command(), "claude": claude, "claude_version": version,
           "skill": skill_state(), "installed": False, "partial": False, "stale": False, "error": None}
    try:
        hooks = (_read_settings(path).get("hooks") or {})
    except (OSError, ValueError) as e:
        out["error"] = tr("settings.json 을 읽을 수 없어요", "Can't read settings.json") + f": {e}"
        return out
    have = []
    for ev, _ in HOOK_EVENTS:
        found = [h for g in hooks.get(ev) or [] if isinstance(g, dict) for h in g.get("hooks") or [] if _our_hook(h)]
        have.append(bool(found))
        if any(h.get("command") != out["command"] for h in found):
            out["stale"] = True
    out["installed"] = all(have)
    out["partial"] = any(have) and not all(have)
    return out


def install_hooks(path: Path, skill: bool = True) -> str:
    try:
        data = _read_settings(path)
    except (OSError, ValueError) as e:
        return tr(f"실패: settings.json 을 읽을 수 없어요 ({e}) — 고치지 않았어요",
                  f"Failed: can't read settings.json ({e}) — nothing was changed")
    before = json.dumps(data, sort_keys=True)
    hooks = data.setdefault("hooks", {})
    cmd = hook_command()
    for ev, matcher in HOOK_EVENTS:
        groups = hooks.setdefault(ev, [])
        found = False
        for g in groups:
            for h in (g.get("hooks") or []) if isinstance(g, dict) else []:
                if _our_hook(h):
                    h["command"] = cmd          # 앱을 옮겨 경로가 바뀌었으면 고친다
                    found = True
        if not found:
            g = {"hooks": [{"type": "command", "command": cmd, "timeout": 5}]}
            groups.append({"matcher": matcher, **g} if matcher else g)
    msgs = []
    if json.dumps(data, sort_keys=True) != before:
        backup = _write_settings(path, data)
        msgs.append(tr("훅을 넣었어요", "Hooks installed") + (tr(f" (백업: {backup})", f" (backup: {backup})") if backup else ""))
    else:
        msgs.append(tr("훅은 이미 들어 있어요", "Hooks are already installed"))
    if skill:
        st, text = skill_state(), _skill_text()
        if text is None:
            msgs.append(tr("/ctx 스킬 파일이 없어 건너뜀", "/ctx skill template missing, skipped"))
        elif st == "custom":
            msgs.append(tr("/ctx 스킬은 직접 만든 것이 있어 그대로 둠", "kept your own /ctx skill"))
        else:
            sp = _skill_path()
            sp.parent.mkdir(parents=True, exist_ok=True)
            sp.write_text(text)
            msgs.append(tr("/ctx 스킬을 넣었어요", "/ctx skill installed"))
    return " · ".join(msgs)


def uninstall_hooks(path: Path) -> str:
    try:
        data = _read_settings(path)
    except (OSError, ValueError) as e:
        return tr(f"실패: settings.json 을 읽을 수 없어요 ({e}) — 고치지 않았어요",
                  f"Failed: can't read settings.json ({e}) — nothing was changed")
    hooks = data.get("hooks") or {}
    removed = 0
    for ev in list(hooks):
        groups = hooks.get(ev)
        if not isinstance(groups, list):
            continue
        kept = []
        for g in groups:
            if isinstance(g, dict) and isinstance(g.get("hooks"), list):
                n = len(g["hooks"])
                g["hooks"] = [h for h in g["hooks"] if not _our_hook(h)]
                removed += n - len(g["hooks"])
                if not g["hooks"]:
                    continue
            kept.append(g)
        if kept:
            hooks[ev] = kept
        else:
            del hooks[ev]
    msgs = []
    if removed:
        if not hooks:
            data.pop("hooks", None)
        backup = _write_settings(path, data)
        msgs.append(tr(f"훅 {removed}개를 뺐어요", f"Removed {removed} hooks") + (tr(f" (백업: {backup})", f" (backup: {backup})") if backup else ""))
    else:
        msgs.append(tr("뺄 훅이 없어요", "No hooks to remove"))
    if skill_state() == "managed":
        _skill_path().unlink()
        msgs.append(tr("/ctx 스킬을 지웠어요", "/ctx skill removed"))
    return " · ".join(msgs)


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 0
    cmd, args = argv[0], argv[1:]
    if cmd == "hook":
        try:
            handle_hook()
        except Exception as e:  # noqa: BLE001 — 훅은 절대 대화를 막지 않는다
            log(f"hook error: {e!r}")
        return 0
    if cmd in ("hooks-status", "install-hooks", "uninstall-hooks"):
        path = claude_settings_path(args)
        if cmd == "install-hooks":
            print(install_hooks(path, skill="--no-skill" not in args))
        elif cmd == "uninstall-hooks":
            print(uninstall_hooks(path))
        else:
            print(json.dumps(hooks_status(path), ensure_ascii=False))
        return 0
    try:
        con = connect()
    except NewerSchema as e:
        print(str(e), file=sys.stderr)
        return 3
    if cmd == "init":
        return 0
    if cmd == "scan":
        changed = scan(con)
        if "--json" in args:
            q = args[args.index("--q") + 1] if "--q" in args else None
            limit = int(args[args.index("--limit") + 1]) if "--limit" in args else 50
            sql, params = "SELECT * FROM sessions", []
            if q:
                sql += (" WHERE agent_name LIKE ? OR ai_title LIKE ? OR first_prompt LIKE ? OR session_id LIKE ?"
                        " OR session_id IN (SELECT session_id FROM labels WHERE label LIKE ?)")
                params = [f"%{q}%"] * 3 + [f"{q}%", f"%{q}%"]
            rows = con.execute(sql + " ORDER BY mtime DESC LIMIT ?", params + [limit]).fetchall()
            print(json.dumps([{"session_id": r["session_id"], "title": title_of(con, r["session_id"]),
                               "cwd": r["cwd"], "mtime": r["mtime"], "live": r["live_status"]}
                              for r in rows], ensure_ascii=False, indent=1))
        else:
            total = con.execute("SELECT COUNT(*) FROM sessions").fetchone()[0]
            print(tr(f"대화 {total}개 (갱신 {changed}개)", f"{total} conversations ({changed} updated)"))
        return 0
    if cmd == "add":
        if not args:
            raise SystemExit(tr("사용법", "usage") + ": add <sid|current>")
        scan_if_needed(con)
        sid = resolve(con, args[0])
        x = float(args[args.index("--x") + 1]) if "--x" in args else None
        y = float(args[args.index("--y") + 1]) if "--y" in args else None
        added = add_node(con, sid, x, y)
        print((tr("추가함", "added") if added else tr("이미 있음", "already there")) + f": «{title_of(con, sid)}» ({sid[:8]})")
        return 0
    if cmd == "remove":
        sid = resolve(con, args[0], allow_sessions=False)
        con.execute("DELETE FROM links WHERE src=? OR dst=?", (sid, sid))
        con.execute("DELETE FROM injections WHERE target=? OR source=?", (sid, sid))
        con.execute("DELETE FROM placements WHERE session_id=?", (sid,))
        con.execute("DELETE FROM nodes WHERE session_id=?", (sid,))
        print(tr("그래프에서 뺌", "removed from graph") + f": {sid[:8]}")
        return 0
    if cmd in ("link", "unlink"):
        both = "--both" in args
        pos = [x for x in args if x != "--both"]
        if len(pos) != 2:
            raise SystemExit(tr("사용법", "usage") + f": {cmd} <a> <b> [--both]")
        scan_if_needed(con)
        a, b = resolve(con, pos[0]), resolve(con, pos[1])
        if cmd == "link":
            new = link(con, a, b, both)
            print((tr("연결함", "linked") if new else tr("이미 연결돼 있음", "already linked")) + f": {arrow(con, a, b)}")
        else:
            n = con.execute("DELETE FROM links WHERE src=? AND dst=?", (a, b)).rowcount
            if both:
                n += con.execute("DELETE FROM links WHERE src=? AND dst=?", (b, a)).rowcount
            print((tr("끊음", "unlinked") if n else tr("그 방향으로 연결돼 있지 않았음", "wasn't linked in that direction")) + tr(" → 지금: ", " → now: ") + f"{arrow(con, a, b)}")
        return 0
    if cmd == "preview":
        sid = resolve(con, args[0] if args else "current")
        print(json.dumps(preview_injection(con, sid), ensure_ascii=False))
        return 0
    if cmd == "usage":
        print(json.dumps(usage(con), ensure_ascii=False))
        return 0
    if cmd == "status":
        print_status(con, resolve(con, args[0] if args else "current"))
        return 0
    if cmd == "summarize":
        sid = resolve(con, args[0], allow_sessions=False)
        ok = summarize(con, sid, force="--force" in args)
        n = node(con, sid)
        print(f"v{n['summary_version']}" + ("" if ok else tr(" (변경 없음/실패: ", " (unchanged/failed: ") + f"{n['summary_error'] or '-'})"))
        return 0
    if cmd == "summarize-job":
        summarize_job(args[0])
        return 0
    if cmd == "models":
        rows = con.execute("SELECT * FROM models ORDER BY sort, name").fetchall()
        keys = load_keys()
        print(json.dumps({
            "models": [dict(r) for r in rows],
            "settings": {r[0]: r[1] for r in con.execute("SELECT key, value FROM settings")},
            "keys": {k: bool(v) for k, v in keys.items()},
        }, ensure_ascii=False, indent=1))
        return 0
    if cmd == "launch-env":
        try:
            pos = [x for i, x in enumerate(args) if x != "--session" and (i == 0 or args[i - 1] != "--session")]
            out = launch_env(con, pos[0] if pos else None)
            if "--session" in args:
                sid = args[args.index("--session") + 1]
                scope = sandbox_scope(con, sid)
                out["scope"] = sandbox_key(scope)
                if scope is not None:           # 엄격 모드: Claude 를 sandbox-exec 로 감싸 셸 명령까지 막는다
                    d = APP_DIR / "sandbox"
                    d.mkdir(parents=True, exist_ok=True)
                    prof = d / f"{sid}.sb"
                    prof.write_text(sandbox_profile(scope))
                    out["wrap"] = ["/usr/bin/sandbox-exec", "-f", str(prof)]
            print(json.dumps(out, ensure_ascii=False))
        except RuntimeError as e:
            print(json.dumps({"error": str(e)}, ensure_ascii=False))
            return 2
        return 0
    if cmd == "notify":
        tab = os.environ.get("CTXGRAPH_TAB")
        if not tab:
            raise SystemExit(tr("CtxGraph 앱 터미널 안에서만 쓸 수 있어요 (CTXGRAPH_TAB 없음)", "Only works inside a CtxGraph app terminal (CTXGRAPH_TAB not set)"))
        add_term_event(con, tab, "notify", one_line(" ".join(args), 200) or tr("알림", "Alert"))
        print(tr("알림 보냄", "alert sent"))
        return 0
    if cmd == "spaces":
        cur = current_space(con)
        rows = con.execute("SELECT s.id, s.name, s.sort, (SELECT COUNT(*) FROM placements p WHERE p.space=s.id) AS nodes"
                           " FROM spaces s ORDER BY s.sort, s.created_at").fetchall()
        print(json.dumps([dict(r) | {"current": r["id"] == cur} for r in rows], ensure_ascii=False, indent=1))
        return 0
    if cmd == "places":
        rows = con.execute("SELECT * FROM places ORDER BY sort, id").fetchall()
        print(json.dumps([dict(r) for r in rows], ensure_ascii=False, indent=1))
        return 0
    if cmd == "scope":
        if not args:
            raise SystemExit(tr("사용법", "usage") + tr(": scope <sid|current> [--all | 위치ID…]", ": scope <sid|current> [--all | placeID…]"))
        sid = resolve(con, args[0], allow_sessions=False)
        rest = args[1:]
        if rest == ["--all"]:
            con.execute("UPDATE nodes SET write_limited=0 WHERE session_id=?", (sid,))
        elif rest:
            ids = [int(x) for x in rest]
            con.execute("BEGIN IMMEDIATE")
            con.execute("DELETE FROM node_places WHERE session_id=?", (sid,))
            for i in ids:
                con.execute("INSERT OR IGNORE INTO node_places(session_id, place_id) VALUES(?,?)", (sid, i))
            con.execute("UPDATE nodes SET write_limited=1 WHERE session_id=?", (sid,))
            con.execute("COMMIT")
        scope = write_scope(con, sid)
        if scope is None:
            print(f"«{title_of(con, sid)}»: " + tr("제한 없음", "no restriction"))
        else:
            print(f"«{title_of(con, sid)}»: " + tr("이 안에서만 수정", "edits only inside") + f" ({scope_key(scope)})")
            for _, name, p in scope:
                print(f"  - {name}: {p}")
            if not scope:
                print(tr("  (위치 없음 — 어떤 파일도 못 고침)", "  (no places — can't edit any file)"))
        return 0
    if cmd == "import-orc":
        n = import_orc(con)
        msg = tr(f"orc 별칭 {n}개 가져옴", f"imported {n} orc aliases")
        if "--key" in args:
            if ORC_KEY_PATH.is_file():
                keys = load_keys()
                keys["openrouter"] = ORC_KEY_PATH.read_text().strip()
                save_keys(keys)
                msg += tr(" · OpenRouter 키 복사함", " · copied the OpenRouter key")
            else:
                msg += tr(" · 키 파일 없음", " · no key file") + f" ({ORC_KEY_PATH})"
        print(msg)
        return 0
    if cmd == "test-model":
        m = model_row(con, args[0] if args else None)
        t0 = time.time()
        try:
            if m["provider"] == "subscription":
                out = tr("구독 모델은 Claude Code 로그인으로 동작 (시험 생략)", "subscription models use the Claude Code login (test skipped)")
            else:
                out = http_messages(con, m, "Reply briefly.", "Reply with exactly one word: pong", max_tokens=1500, timeout=90)
            print(f"OK ({time.time() - t0:.1f}s): {one_line(out, 80)}")
            return 0
        except RuntimeError as e:
            print(tr("실패", "Failed") + f": {e}")
            return 2
    raise SystemExit(tr("알 수 없는 명령", "Unknown command") + f": {cmd}")


def import_orc(con) -> int:
    """or.zsh 의 typeset -gA OR_MODELS=( alias slug ... ) 를 openrouter 프로필로."""
    try:
        text = ORC_PATH.read_text()
    except OSError:
        return 0
    m = re.search(r"OR_MODELS=\((.*?)\)", text, re.S)
    if not m:
        return 0
    n = 0
    for i, line in enumerate(m.group(1).splitlines()):
        parts = line.split("#")[0].split()
        if len(parts) != 2:
            continue
        alias, slug = parts
        con.execute("INSERT OR REPLACE INTO models(id, name, provider, model, small_model, base_url, sort)"
                    " VALUES(?,?,?,?,?,?,?)", (f"or:{alias}", f"{alias} · {slug.split('/')[-1]}", "openrouter",
                                               slug, None, None, 50 + i))
        n += 1
    return n


def scan_if_needed(con) -> None:
    if con.execute("SELECT COUNT(*) FROM sessions").fetchone()[0] == 0:
        scan(con)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
