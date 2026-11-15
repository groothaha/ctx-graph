"""/ctx 스킬이 부르는 CLI: 대화 찾기, 잇기·끊기, 빼기."""
from __future__ import annotations

import json
import unittest

from support import A, B, C, Sandbox, two_conversations


class CliTest(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox("ko")
        two_conversations(self.sb)

    def tearDown(self):
        self.sb.close()

    def links(self):
        return {(r[0], r[1]) for r in self.sb.q("SELECT src, dst FROM links")}

    def test_find_by_title_and_id_prefix(self):
        self.assertIn("Alpha → Beta".split()[0], self.sb.run("link", "alpha", B[:6]).stdout)
        self.assertEqual(self.links(), {(A, B)})

    def test_both_directions_and_unlink(self):
        self.sb.run("summarize", A)
        self.sb.run("summarize", B)
        self.sb.run("link", A, B, "--both")
        self.assertEqual(self.links(), {(A, B), (B, A)})
        self.sb.run("unlink", B, A)
        self.assertEqual(self.links(), {(A, B)})
        self.sb.run("unlink", A, B, "--both")
        self.assertEqual(self.links(), set())

    def test_ambiguous_query_lists_candidates(self):
        self.sb.transcript(C, "/tmp/gamma", "Alpha again", [("U", "또 알파"), ("A", "네")])
        self.sb.run("scan")
        self.sb.run("add", C)
        r = self.sb.run("link", "Alpha", B, check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("후보가 여러 개", r.stderr)
        self.assertIn(A[:8], r.stderr)
        self.assertIn(C[:8], r.stderr)
        self.assertEqual(self.links(), set(), "모호하면 아무것도 안 함")

    def test_link_summarizes_source_in_background(self):
        self.sb.run("link", A, B)
        self.sb.wait_jobs()
        self.assertEqual(self.sb.q("SELECT summary_version FROM nodes WHERE session_id=?", A)[0][0], 1)

    def test_remove_cleans_links_and_injections(self):
        self.sb.run("summarize", A)
        self.sb.run("link", A, B)
        self.sb.context(B)
        self.sb.run("remove", A)
        self.assertEqual(self.sb.q("SELECT COUNT(*) FROM nodes WHERE session_id=?", A)[0][0], 0)
        self.assertEqual(self.links(), set())
        self.assertEqual(self.sb.q("SELECT COUNT(*) FROM injections")[0][0], 0)

    def test_add_places_in_current_workspace(self):
        self.sb.x("INSERT INTO spaces(id, name, sort, created_at) VALUES('s-docs', 'Docs', 1, 1)")
        self.sb.x("INSERT OR REPLACE INTO settings(key, value) VALUES('current_space', 's-docs')")
        self.sb.transcript(C, "/tmp/gamma", "Gamma", [("U", "감마"), ("A", "네")])
        self.sb.run("scan")
        self.sb.run("add", C)
        self.assertEqual([tuple(r) for r in self.sb.q("SELECT space FROM placements WHERE session_id=?", C)], [("s-docs",)])
        # 같은 대화가 공간 두 곳에 (앱에서 '다른 공간에도 놓기')
        self.sb.x("INSERT INTO placements(session_id, space, x, y, added_at) VALUES(?, 'main', 1, 1, 9e9)", C)
        self.assertIn("«Docs», «기본»", self.sb.run("status", C).stdout)
        counts = {r["id"]: r["nodes"] for r in json.loads(self.sb.run("spaces").stdout)}
        self.assertEqual(counts["s-docs"], 1)
        self.assertEqual(counts["main"], 3)
        self.sb.run("remove", C)
        self.assertEqual(self.sb.q("SELECT COUNT(*) FROM placements WHERE session_id=?", C)[0][0], 0)

    def test_user_label_is_the_title(self):
        """앱에서 붙인 이름: 찾기·상태·주입되는 글의 제목에 쓰인다 (그래프에 없는 대화도 찾음)"""
        self.sb.x("INSERT INTO labels(session_id, label, set_at) VALUES(?, 'Payments API', 1)", A)
        self.sb.run("summarize", A)
        self.sb.run("link", "payments", B)
        self.assertIn("«Payments API»", self.sb.run("status", B).stdout)
        self.assertIn("Payments API", self.sb.context(B))
        self.sb.transcript(C, "/tmp/gamma", "Gamma", [("U", "감마"), ("A", "네")])
        self.sb.run("scan")
        self.sb.x("INSERT INTO labels(session_id, label, set_at) VALUES(?, 'Ledger cleanup', 1)", C)
        self.assertIn("Ledger cleanup", self.sb.run("add", "ledger").stdout)

    def test_current_needs_claude_session(self):
        r = self.sb.run("status", check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("CLAUDE_CODE_SESSION_ID", r.stderr)
        self.assertIn("Beta work", self.sb.run("status", env={"CLAUDE_CODE_SESSION_ID": B}).stdout)


if __name__ == "__main__":
    unittest.main()
