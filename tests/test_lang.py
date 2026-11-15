"""언어: 한국어·영어 사용자가 받는 글. 훅이 넣는 글은 golden/ 의 파일과 한 글자도 달라지면 안 된다.

일부러 바꾼 거라면: UPDATE_GOLDEN=1 python3 -m unittest test_lang  (그리고 diff 를 눈으로 확인)
"""
from __future__ import annotations

import json
import os
import unittest
from pathlib import Path

from support import A, B, Sandbox, two_conversations

GOLDEN = Path(__file__).parent / "golden"


def scenario(lang: str) -> tuple[Sandbox, str, str]:
    """A → B 연결: B 가 처음 받는 전체 요약, 그다음 A 가 한 번 더 요약된 뒤 받는 변경분"""
    sb = Sandbox(lang)
    two_conversations(sb)
    sb.run("summarize", A)
    sb.run("link", A, B)
    first = sb.context(B)
    sb.append(A, [("U", "two"), ("A", "done")])
    sb.run("summarize", A)
    second = sb.context(B)
    return sb, sb.normalize(first), sb.normalize(second)


class GoldenTest(unittest.TestCase):
    def check(self, name: str, text: str):
        f = GOLDEN / name
        if os.environ.get("UPDATE_GOLDEN"):
            f.write_text(text)
        self.assertTrue(f.exists(), f"{f} 없음 — UPDATE_GOLDEN=1 로 만들기")
        self.assertEqual(text, f.read_text(), f"{name} 이 바뀜")

    def test_korean(self):
        sb, first, second = scenario("ko")
        try:
            self.check("inject_full.ko.txt", first)
            self.check("inject_delta.ko.txt", second)
            system = sb.calls()[0]["args"][sb.calls()[0]["args"].index("--system-prompt") + 1]
            self.assertIn("요약", system, "한국어 사용자는 한국어 요약")
        finally:
            sb.close()

    def test_english(self):
        sb, first, second = scenario("en")
        try:
            self.check("inject_full.en.txt", first)
            self.check("inject_delta.en.txt", second)
            self.assertTrue(first.startswith("[Context graph]"))
            self.assertFalse(any("가" <= ch <= "힣" for ch in first + second), "영어 사용자 글에 한글 없음")
            call = sb.calls()[0]
            system = call["args"][call["args"].index("--system-prompt") + 1]
            self.assertFalse(any("가" <= ch <= "힣" for ch in system + call["prompt"].split("<")[0]))
        finally:
            sb.close()

    def test_language_is_remembered_for_hooks(self):
        """앱이 CTXGRAPH_LANG 을 넘기면 settings.lang 에 남고, 그 env 가 없는 훅도 그 언어를 쓴다"""
        sb = Sandbox("en")
        try:
            two_conversations(sb)
            sb.run("summarize", A)
            sb.run("link", A, B)
            del sb.env["CTXGRAPH_LANG"]
            sb.env["LANG"] = "ko_KR.UTF-8"
            self.assertTrue(sb.context(B).startswith("[Context graph]"))
        finally:
            sb.close()

    def test_cli_messages(self):
        for lang, word in (("ko", "연결함"), ("en", "linked")):
            sb = Sandbox(lang)
            try:
                two_conversations(sb)
                sb.run("summarize", A)
                self.assertIn(word, sb.run("link", A, B).stdout)
                self.assertEqual(json.loads(sb.run("spaces").stdout)[0]["name"], "기본" if lang == "ko" else "Main")
            finally:
                sb.close()


if __name__ == "__main__":
    unittest.main()
