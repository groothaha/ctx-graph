"""graph.sqlite 형식 번호: 새 DB, 번호 없던 0.x DB 올리기, 동시에 열기, 더 새 DB 는 안 건드리기, 앱과 번호 맞추기."""
from __future__ import annotations

import importlib.util
import os
import re
import sqlite3
import subprocess
import sys
import time
import unittest
from pathlib import Path

from support import A, B, ROOT, SCRIPT, Sandbox, two_conversations

SCHEMA_VERSION = int(re.search(r"^SCHEMA_VERSION = (\d+)", SCRIPT.read_text(), re.M).group(1))

# 0.1 시절 DB: 무방향 edges 표, 나중에 생긴 열·표가 없음
LEGACY_01 = """
CREATE TABLE nodes(session_id TEXT PRIMARY KEY, transcript_path TEXT NOT NULL, cwd TEXT, label TEXT, x REAL, y REAL,
  added_at REAL NOT NULL, summary TEXT, delta TEXT, summary_version INTEGER NOT NULL DEFAULT 0, summary_at REAL,
  summary_src_size INTEGER NOT NULL DEFAULT 0, summary_error TEXT, job_started_at REAL, summarizing_at REAL);
CREATE TABLE edges(a TEXT NOT NULL, b TEXT NOT NULL, created_at REAL NOT NULL, PRIMARY KEY(a, b));
CREATE TABLE injections(target TEXT NOT NULL, source TEXT NOT NULL, version INTEGER NOT NULL, at REAL NOT NULL,
  PRIMARY KEY(target, source));
INSERT INTO nodes(session_id, transcript_path, cwd, added_at, summary, summary_version) VALUES
  ('aaaaaaaa-1111-4111-8111-111111111111', '/nonexistent/a.jsonl', '/tmp/alpha', 1, 'old summary', 3),
  ('bbbbbbbb-2222-4222-8222-222222222222', '/nonexistent/b.jsonl', '/tmp/beta', 2, NULL, 0);
INSERT INTO edges VALUES('aaaaaaaa-1111-4111-8111-111111111111', 'bbbbbbbb-2222-4222-8222-222222222222', 5);
INSERT INTO injections VALUES('bbbbbbbb-2222-4222-8222-222222222222', 'aaaaaaaa-1111-4111-8111-111111111111', 3, 9);
"""


def columns(sb, table):
    return {r[1] for r in sb.q(f"PRAGMA table_info({table})")}


class SchemaTest(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox("ko")

    def tearDown(self):
        self.sb.close()

    def make_legacy(self):
        self.sb.app_dir.mkdir(parents=True)
        con = sqlite3.connect(str(self.sb.db_path))
        con.executescript(LEGACY_01)
        con.close()

    def assert_current(self):
        sb = self.sb
        self.assertEqual(sb.q("PRAGMA user_version")[0][0], SCHEMA_VERSION)
        self.assertTrue({"model_id", "write_limited", "write_strict", "space", "summary_src_at"} <= columns(sb, "nodes"))
        self.assertIn("src_at", columns(sb, "injections"))
        kinds = {r[0]: r[1] for r in sb.q("SELECT name, type FROM sqlite_master")}
        self.assertEqual(kinds.get("edges"), "view")
        self.assertEqual(kinds.get("summary_runs"), "table")
        self.assertEqual(sb.q("SELECT id FROM models WHERE id='claude'")[0][0], "claude")
        self.assertEqual(sb.q("SELECT id FROM spaces WHERE id='main'")[0][0], "main")
        self.assertEqual(kinds.get("placements"), "table")
        self.assertEqual(kinds.get("labels"), "table")
        unplaced = sb.q("SELECT COUNT(*) FROM nodes WHERE session_id NOT IN (SELECT session_id FROM placements)")[0][0]
        self.assertEqual(unplaced, 0, "모든 노드가 어딘가에 놓여 있음")

    def test_new_database(self):
        self.sb.run("init")
        self.assert_current()

    def test_unnumbered_01_database_is_upgraded(self):
        self.make_legacy()
        self.sb.run("init")
        self.assert_current()
        links = {(r[0], r[1]) for r in self.sb.q("SELECT src, dst FROM links")}
        self.assertEqual(links, {(A, B), (B, A)}, "예전 무방향 연결은 양방향으로")
        self.assertEqual(self.sb.q("SELECT summary, summary_version FROM nodes WHERE session_id=?", A)[0][:], ("old summary", 3))
        self.assertEqual(self.sb.q("SELECT version FROM injections")[0][0], 3)

    def test_v1_positions_become_placements(self):
        """v1 → v2: 노드 한 줄의 (공간, 좌표) 가 placements 로 — 좌표·공간 그대로"""
        two_conversations(self.sb)
        self.sb.x("INSERT INTO spaces(id, name, sort, created_at) VALUES('s-docs', 'Docs', 1, 1)")
        self.sb.x("DROP TABLE placements")
        self.sb.x("UPDATE nodes SET space=NULL, x=111, y=222 WHERE session_id=?", A)
        self.sb.x("UPDATE nodes SET space='s-docs', x=333, y=444 WHERE session_id=?", B)
        self.sb.x("PRAGMA user_version=1")
        self.sb.run("init")
        self.assert_current()
        got = {tuple(r) for r in self.sb.q("SELECT session_id, space, x, y FROM placements")}
        self.assertEqual(got, {(A, "main", 111, 222), (B, "s-docs", 333, 444)})

    def test_v2_node_labels_become_conversation_labels(self):
        """v2 → v3: 노드에 붙였던 이름이 대화 이름(labels)으로 — 그래프에서 빼도 남는다"""
        two_conversations(self.sb)
        self.sb.x("DROP TABLE labels")
        self.sb.x("UPDATE nodes SET label='My Alpha' WHERE session_id=?", A)
        self.sb.x("UPDATE nodes SET label='새 대화' WHERE session_id=?", B)   # 예전 앱이 잘못 저장한 자리 표시 제목
        self.sb.x("PRAGMA user_version=2")
        self.sb.run("init")
        self.assert_current()
        self.assertEqual([tuple(r) for r in self.sb.q("SELECT session_id, label FROM labels")], [(A, "My Alpha")])
        self.assertEqual(self.sb.q("SELECT COUNT(*) FROM nodes WHERE label IS NOT NULL")[0][0], 0)
        self.sb.run("remove", A)
        self.assertEqual(self.sb.q("SELECT label FROM labels WHERE session_id=?", A)[0][0], "My Alpha")

    def test_upgrade_runs_once(self):
        self.make_legacy()
        self.sb.run("init")
        first = self.sb.dump()
        self.sb.run("init")
        self.assertEqual(self.sb.dump(), first)

    def test_many_processes_opening_at_once(self):
        """훅 여러 개가 같은 순간 처음 여는 경우"""
        self.make_legacy()
        procs = [subprocess.Popen([sys.executable, "-I", str(self.sb.script), "init"], env=self.sb.env,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for _ in range(8)]
        for p in procs:
            out, err = p.communicate(timeout=60)
            self.assertEqual(p.returncode, 0, err)
        self.assert_current()
        self.assertEqual(self.sb.q("SELECT COUNT(*) FROM links")[0][0], 2)

    def test_newer_database_is_left_alone(self):
        two_conversations(self.sb)
        self.sb.run("summarize", A)
        self.sb.run("link", A, B)
        self.sb.x(f"PRAGMA user_version={SCHEMA_VERSION + 1}")
        before = self.sb.dump()
        r = self.sb.run("status", B, check=False)
        self.assertEqual(r.returncode, 3)
        self.assertIn("더 새 CtxGraph", r.stderr)
        self.assertIsNone(self.sb.context(B), "훅은 조용히 건너뜀 (대화는 막지 않음)")
        self.sb.hook("Stop", A)
        self.sb.hook("PreToolUse", B, tool_name="Write", tool_input={"file_path": "/tmp/x"})
        self.assertEqual(self.sb.dump(), before, "더 새 DB 에는 아무것도 쓰지 않음")

    def test_app_and_script_agree_on_release_version(self):
        plist = (ROOT / "app" / "Info.plist").read_text()
        m = re.search(r"<key>CFBundleShortVersionString</key>\s*<string>([^<]+)</string>", plist)
        v = re.search(r'^VERSION = "([^"]+)"', SCRIPT.read_text(), re.M)
        self.assertEqual(m.group(1), v.group(1), "Info.plist 버전 == ctxgraph.py VERSION")

    def test_app_and_script_agree_on_version(self):
        swift = (ROOT / "app" / "Sources" / "CtxGraph" / "Backend.swift").read_text()
        m = re.search(r"enum Schema \{[^}]*static let version = (\d+)", swift)
        self.assertIsNotNone(m, "Backend.swift 에 enum Schema { static let version = N } 이 있어야 함")
        self.assertEqual(int(m.group(1)), SCHEMA_VERSION)


class MigrationStepTest(unittest.TestCase):
    """다음 형식 번호를 더할 때 쓸 단계 장치"""

    def setUp(self):
        self.sb = Sandbox("ko")
        self.sb.run("init")
        old = os.environ.get("HOME")
        os.environ["HOME"] = str(self.sb.home)
        try:
            spec = importlib.util.spec_from_file_location("ctxgraph_under_test", self.sb.script)
            self.mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(self.mod)
        finally:
            os.environ["HOME"] = old
        self.assertEqual(self.mod.DB_PATH, self.sb.db_path)

    def tearDown(self):
        self.sb.close()

    def test_step_applies_once_and_bumps_version(self):
        v = self.mod.SCHEMA_VERSION + 1
        self.mod.MIGRATIONS = [(v, lambda con: con.execute("ALTER TABLE nodes ADD COLUMN pinned INTEGER"))]
        self.mod.SCHEMA_VERSION = v
        for _ in range(2):
            con = self.mod.connect()
            con.close()
        self.assertEqual(self.sb.q("PRAGMA user_version")[0][0], v)
        self.assertIn("pinned", columns(self.sb, "nodes"))

    def test_wal_switch_retries_while_locked(self):
        """처음 WAL 로 바꿀 때 바로 나는 'database is locked' 는 잠깐 뒤 다시 (CI 에서 8개 동시 열기 중 하나가 실패했었다)"""
        class Flaky:
            def __init__(self, fails, msg="database is locked"):
                self.fails, self.msg, self.calls = fails, msg, 0

            def execute(self, sql):
                self.calls += 1
                if self.calls <= self.fails:
                    raise sqlite3.OperationalError(self.msg)
        con = Flaky(3)
        self.mod.set_wal(con)
        self.assertEqual(con.calls, 4)
        with self.assertRaises(sqlite3.OperationalError):     # 다른 오류는 다시 하지 않는다
            self.mod.set_wal(Flaky(1, "disk I/O error"))
        stuck = Flaky(10**6)
        t0 = time.monotonic()
        with self.assertRaises(sqlite3.OperationalError):     # 끝까지 잠겨 있으면 포기
            self.mod.set_wal(stuck, wait=1.0)
        # 몇 번 다시 했는지는 러너 속도에 달렸다 (느린 CI 는 sleep 이 길어져 2번에 그친 적 있음) — 다시 했는지와 제때 멈췄는지만
        self.assertGreaterEqual(stuck.calls, 2)
        self.assertLess(time.monotonic() - t0, 3.0)

    def test_failed_step_rolls_back(self):
        v = self.mod.SCHEMA_VERSION + 1

        def bad(con):
            con.execute("ALTER TABLE nodes ADD COLUMN half_done INTEGER")
            raise RuntimeError("boom")
        self.mod.MIGRATIONS = [(v, bad)]
        self.mod.SCHEMA_VERSION = v
        with self.assertRaises(RuntimeError):
            self.mod.connect()
        self.assertEqual(self.sb.q("PRAGMA user_version")[0][0], v - 1)
        self.assertNotIn("half_done", columns(self.sb, "nodes"))


if __name__ == "__main__":
    unittest.main()
