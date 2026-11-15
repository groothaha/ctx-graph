"""훅 설치기: 사용자의 settings.json 에서 우리 훅만 넣고 빼고, 나머지는 한 글자도 안 건드린다."""
from __future__ import annotations

import json
import re
import shutil
import subprocess
import unittest

from support import Sandbox

OURS = re.compile(r"ctxgraph\.py'?\s+hook(\s|$)")
EVENTS = ["UserPromptSubmit", "SessionStart", "Stop", "Notification", "PreToolUse"]

USER_SETTINGS = {
    "model": "opus",
    "permissions": {"allow": ["Bash(ls:*)"]},
    "hooks": {
        "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "echo mine"}]}],
        "PostToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "~/bin/log.sh"}]}],
    },
}


class InstallTest(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox("ko")
        self.settings = self.sb.claude_dir / "settings.json"
        self.skill = self.sb.claude_dir / "skills" / "ctx" / "SKILL.md"

    def tearDown(self):
        self.sb.close()

    def status(self):
        return json.loads(self.sb.run("hooks-status").stdout)

    def data(self):
        return json.loads(self.settings.read_text())

    def backups(self):
        return sorted(self.settings.parent.glob("settings.json.bak-ctxgraph-*"))

    def ours(self, data, ev):
        return [h for g in data["hooks"].get(ev, []) for h in g["hooks"] if OURS.search(h["command"])]

    def test_fresh_install(self):
        st = self.status()
        self.assertFalse(st["installed"])
        self.assertEqual(st["claude_version"], "2.1.99")
        self.assertIn("훅을 넣었어요", self.sb.run("install-hooks").stdout)
        d = self.data()
        for ev in EVENTS:
            self.assertEqual(len(self.ours(d, ev)), 1, ev)
        self.assertEqual(d["hooks"]["PreToolUse"][0]["matcher"], "Edit|Write|MultiEdit|NotebookEdit")
        self.assertEqual(self.backups(), [], "원래 파일이 없었으면 백업도 없음")
        st = self.status()
        self.assertTrue(st["installed"])
        self.assertFalse(st["stale"] or st["partial"])
        self.assertEqual(st["skill"], "managed")
        self.assertIn(str(self.sb.script), self.skill.read_text(), "/ctx 스킬이 이 스크립트를 가리킴")

    def test_install_is_idempotent(self):
        self.sb.run("install-hooks")
        first = self.settings.read_text()
        self.assertIn("이미 들어 있어요", self.sb.run("install-hooks").stdout)
        self.assertEqual(self.settings.read_text(), first)
        self.assertEqual(self.backups(), [])

    def test_keeps_everything_else_and_uninstall_restores(self):
        self.settings.parent.mkdir(parents=True, exist_ok=True)
        self.settings.write_text(json.dumps(USER_SETTINGS, indent=2))
        original = self.settings.read_text()
        self.sb.run("install-hooks")
        d = self.data()
        self.assertEqual(d["model"], "opus")
        self.assertEqual(d["permissions"], USER_SETTINGS["permissions"])
        cmds = [h["command"] for g in d["hooks"]["UserPromptSubmit"] for h in g["hooks"]]
        self.assertIn("echo mine", cmds)
        self.assertEqual(d["hooks"]["PostToolUse"], USER_SETTINGS["hooks"]["PostToolUse"])
        self.assertEqual(len(self.backups()), 1)
        self.assertEqual(self.backups()[0].read_text(), original, "백업 = 원래 파일 그대로")
        self.assertIn("훅 5개를 뺐어요", self.sb.run("uninstall-hooks").stdout)
        self.assertEqual(self.data(), USER_SETTINGS, "빼면 원래 내용으로 돌아감")
        self.assertFalse(self.skill.exists(), "우리가 넣은 스킬은 같이 지움")
        self.assertEqual(len(self.backups()), 2)

    def test_stale_path_is_detected_and_fixed(self):
        self.settings.parent.mkdir(parents=True, exist_ok=True)
        old = "python3 -I /old/place/ctxgraph.py hook"
        self.settings.write_text(json.dumps({"hooks": {ev: [{"hooks": [{"type": "command", "command": old}]}] for ev in EVENTS}}))
        st = self.status()
        self.assertTrue(st["installed"] and st["stale"])
        self.sb.run("install-hooks")
        st = self.status()
        self.assertTrue(st["installed"])
        self.assertFalse(st["stale"])
        for ev in EVENTS:
            self.assertEqual(len(self.ours(self.data(), ev)), 1, "고치기만 하고 하나 더 넣지 않음")

    def test_partial(self):
        self.settings.parent.mkdir(parents=True, exist_ok=True)
        cmd = json.loads(self.sb.run("hooks-status").stdout)["command"]
        self.settings.write_text(json.dumps({"hooks": {"Stop": [{"hooks": [{"type": "command", "command": cmd}]}]}}))
        st = self.status()
        self.assertTrue(st["partial"])
        self.assertFalse(st["installed"])

    def test_custom_skill_is_never_touched(self):
        self.skill.parent.mkdir(parents=True)
        self.skill.write_text("my own /ctx skill\n")
        self.assertIn("직접 만든 것", self.sb.run("install-hooks").stdout)
        self.assertEqual(self.status()["skill"], "custom")
        self.sb.run("uninstall-hooks")
        self.assertEqual(self.skill.read_text(), "my own /ctx skill\n")

    def test_broken_settings_are_refused(self):
        self.settings.parent.mkdir(parents=True, exist_ok=True)
        self.settings.write_text("{not json")
        self.assertIn("고치지 않았어요", self.sb.run("install-hooks").stdout)
        self.assertIn("고치지 않았어요", self.sb.run("uninstall-hooks").stdout)
        self.assertEqual(self.settings.read_text(), "{not json")
        self.assertEqual(self.backups(), [])
        self.assertIsNotNone(self.status()["error"])

    def test_claude_config_dir_is_followed(self):
        other = self.sb.dir / "other-claude"
        self.sb.run("install-hooks", env={"CLAUDE_CONFIG_DIR": str(other)})
        self.assertTrue((other / "settings.json").exists())
        self.assertTrue((other / "skills" / "ctx" / "SKILL.md").exists())
        self.assertFalse(self.settings.exists())

    def test_installed_command_runs_from_a_path_with_spaces(self):
        """배포판은 ~/Library/Application Support/… (공백) 에서 돈다. Claude Code 처럼 셸로 실행해 본다."""
        spaced = self.sb.dir / "Application Support" / "bin"
        shutil.copytree(self.sb.bin, spaced)
        script = spaced / "ctxgraph.py"
        self.sb.run("install-hooks", script=script)
        cmd = self.ours(self.data(), "UserPromptSubmit")[0]["command"]
        self.assertIn("'", cmd, "공백 있는 경로는 따옴표로")
        st = json.loads(self.sb.run("hooks-status", script=script).stdout)
        self.assertTrue(st["installed"] and not st["stale"], "따옴표로 감싼 자기 훅도 알아봐야 함")
        self.assertIn("이미 들어 있어요", self.sb.run("install-hooks", script=script).stdout)
        for ev in EVENTS:
            self.assertEqual(len(self.ours(self.data(), ev)), 1, "다시 켜도 하나만")
        r = subprocess.run(["/bin/sh", "-c", cmd], input=json.dumps({"hook_event_name": "UserPromptSubmit",
                           "session_id": "x"}), capture_output=True, text=True, env=self.sb.env, timeout=30)
        self.assertEqual((r.returncode, r.stderr), (0, ""))


if __name__ == "__main__":
    unittest.main()
