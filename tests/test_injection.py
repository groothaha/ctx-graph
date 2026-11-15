"""맥락 주입: 훅이 실제로 넣는 글, 미리보기와 같은지, 버전·끊김·재개 처리, 요약 예약."""
from __future__ import annotations

import json
import time
import unittest

from support import A, B, T0, Sandbox, two_conversations


class InjectionTest(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox("ko")
        two_conversations(self.sb)
        self.assertEqual(self.sb.run("summarize", A).stdout.strip(), "v1")
        self.assertIn("연결함", self.sb.run("link", A, B).stdout)

    def tearDown(self):
        self.sb.close()

    def preview(self, sid):
        return json.loads(self.sb.run("preview", sid).stdout)

    def test_first_message_gets_full_summary_and_matches_preview(self):
        before = self.sb.dump()
        p = self.preview(B)
        self.assertEqual(self.sb.dump(), before, "미리보기는 아무것도 기록하지 않아야 함")
        self.assertEqual([i["mode"] for i in p["items"]], ["full"])
        ctx = self.sb.context(B)
        self.assertEqual(ctx, p["text"], "미리보기 글 == 훅이 실제로 넣는 글")
        self.assertIn("[맥락 그래프]", ctx)
        self.assertIn("## «Alpha work»", ctx)
        self.assertIn("SUMMARY 1", ctx)
        self.assertEqual(self.sb.q("SELECT version FROM injections WHERE target=? AND source=?", B, A)[0][0], 1)

    def test_same_version_is_not_sent_twice(self):
        self.assertIsNotNone(self.sb.context(B))
        self.assertIsNone(self.sb.context(B))
        self.assertEqual([i["mode"] for i in self.preview(B)["items"]], ["same"])

    def test_next_version_sends_only_the_delta(self):
        self.sb.context(B)
        self.sb.append(A, [("U", "알파 2단계"), ("A", "2단계도 했어요.")])
        self.assertEqual(self.sb.run("summarize", A).stdout.strip(), "v2")
        call = self.sb.calls()[-1]
        self.assertIn("SUMMARY 1", call["prompt"], "점진 요약은 이전 요약을 같이 보냄")
        self.assertIn("알파 2단계", call["prompt"])
        self.assertNotIn("알파 기능을 만들자", call["prompt"], "이미 요약한 부분은 다시 안 보냄")
        ctx = self.sb.context(B)
        self.assertIn("업데이트 (요약 v2", ctx)
        self.assertIn("DELTA 2", ctx)
        self.assertNotIn("SUMMARY 2", ctx)

    def test_resume_or_compact_resends_full_summary(self):
        self.sb.context(B)
        for source in ("resume", "compact"):
            self.assertIsNone(self.sb.hook("SessionStart", B, source=source))
            ctx = self.sb.context(B)
            self.assertIsNotNone(ctx, source)
            self.assertIn("SUMMARY 1", ctx)
        self.sb.hook("SessionStart", B, source="startup")
        self.assertIsNone(self.sb.context(B), "새로 시작(startup)은 받은 기록을 지우지 않음")

    def test_unlink_notice_once(self):
        self.sb.context(B)
        self.sb.run("unlink", A, B)
        ctx = self.sb.context(B)
        self.assertIn("«Alpha work» 연결 해제됨", ctx)
        self.assertIsNone(self.sb.context(B))

    def test_source_without_summary_sends_nothing(self):
        self.sb.run("link", B, A)                 # B → A, B 는 요약이 아직 없음 (요약을 백그라운드로 시작)
        self.sb.wait_jobs()
        self.sb.x("UPDATE nodes SET summary=NULL, summary_version=0 WHERE session_id=?", B)
        self.assertEqual([i["mode"] for i in self.preview(A)["items"]], ["none"])
        self.assertIsNone(self.sb.context(A))

    def test_budget_truncates_long_context(self):
        self.sb.x("UPDATE nodes SET summary=? WHERE session_id=?", "가" * 20000, A)
        ctx = self.sb.context(B)
        self.assertLess(len(ctx), 9_500)
        self.assertIn("길어서 잘림", ctx)

    def test_stop_schedules_summary_only_for_sending_nodes(self):
        # B 는 보내는 곳이 없음 → 예약 안 함
        self.sb.append(B, [("U", "베타 더"), ("A", "네")], mtime=T0)
        self.sb.hook("Stop", B)
        self.assertIsNone(self.sb.q("SELECT job_started_at FROM nodes WHERE session_id=?", B)[0][0])
        # A 는 B 로 보냄 + 기록이 늘어남 → 예약 → (잠잠·쿨다운이 이미 지났으니) 바로 요약
        self.sb.append(A, [("U", "알파 3단계"), ("A", "했어요")], mtime=time.time() - 1000)
        self.sb.x("UPDATE nodes SET summary_at=? WHERE session_id=?", time.time() - 1000, A)
        self.sb.hook("Stop", A)
        self.sb.wait_jobs()
        row = self.sb.q("SELECT summary_version, job_started_at FROM nodes WHERE session_id=?", A)[0]
        self.assertEqual(row["summary_version"], 2)
        self.assertIsNone(row["job_started_at"])
        # 기록이 그대로면 다시 예약하지 않음
        n = len(self.sb.calls())
        self.sb.hook("Stop", A)
        self.sb.wait_jobs()
        self.assertEqual(len(self.sb.calls()), n)

    def test_failed_summary_is_recorded_and_hook_still_works(self):
        (self.sb.fake / "fail").write_text("1")
        self.sb.append(A, [("U", "실패할 요약"), ("A", "...")])
        self.assertIn("실패", self.sb.run("summarize", A).stdout)
        err = self.sb.q("SELECT summary_error FROM nodes WHERE session_id=?", A)[0][0]
        self.assertIn("claude -p", err)
        runs = self.sb.q("SELECT ok FROM summary_runs ORDER BY at")
        self.assertEqual([r[0] for r in runs], [1, 0])
        self.assertIn("SUMMARY 1", self.sb.context(B), "실패해도 이전 요약은 그대로 들어감")


class SummaryCallTest(unittest.TestCase):
    """요약은 도구 없이, 설정·세션 기록 없이, 우리 훅이 다시 돌지 않게 부른다"""

    def test_claude_p_flags_and_clean_env(self):
        sb = Sandbox("ko")
        try:
            two_conversations(sb)
            sb.run("summarize", A, env={"CLAUDE_CODE_PLUGIN_DIRS": "/x", "CLAUDE_CODE_SESSION_ID": "zzz"})
            call = sb.calls()[-1]
            args = call["args"]
            self.assertIn("-p", args)
            self.assertEqual(args[args.index("--model") + 1], "haiku")
            self.assertEqual(args[args.index("--tools") + 1], "")
            self.assertEqual(args[args.index("--setting-sources") + 1], "project")
            self.assertIn("--no-session-persistence", args)
            self.assertIn("CTXGRAPH_INTERNAL", call["env"], "요약 안에서 우리 훅이 다시 돌지 않게")
            self.assertFalse([k for k in call["env"] if k.startswith(("CLAUDE", "ANTHROPIC"))],
                             "사용자 Claude 환경(플러그인·세션 ID 등)은 요약 호출에 안 넘김")
        finally:
            sb.close()


class HookSafetyTest(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox("ko")
        two_conversations(self.sb)

    def tearDown(self):
        self.sb.close()

    def test_garbage_input_never_breaks_the_conversation(self):
        for raw in ("", "not json", "[]", "{}", '{"hook_event_name": "UserPromptSubmit"}'):
            self.assertIsNone(self.sb.hook("UserPromptSubmit", None, raw=raw), raw)

    def test_unknown_session_gets_nothing(self):
        self.assertIsNone(self.sb.context("dddddddd-4444-4444-8444-444444444444"))

    def test_internal_summary_call_skips_hook(self):
        self.sb.run("summarize", A)
        self.sb.run("link", A, B)
        r = self.sb.run("hook", input=json.dumps({"hook_event_name": "UserPromptSubmit", "session_id": B}),
                        env={"CTXGRAPH_INTERNAL": "1"})
        self.assertEqual(r.stdout, "")

    def test_payload_format_change_raises_health_notice(self):
        self.sb.hook("UserPromptSubmit", None, raw=json.dumps({"session_id": B, "prompt": "x"}))
        msg = self.sb.q("SELECT value FROM settings WHERE key='health_hook'")[0][0]
        self.assertIn("hook_event_name", msg)
        self.sb.context(B)
        self.assertEqual(self.sb.q("SELECT value FROM settings WHERE key='health_hook'")[0][0], "")


if __name__ == "__main__":
    unittest.main()
