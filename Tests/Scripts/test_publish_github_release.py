"""一時 Git と GitHub CLI の代役で、公開対象・ノート・再実行の拒否条件を確認する。"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "Scripts" / "publish-github-release.py"
CHANGELOG = """# 変更履歴

## [Unreleased]

- まだ公開しない変更

## [1.10.0] - 2026-09-14

### 修正
- 対象の変更

## [1.9.0] - 2026-09-13

- 前の版の変更
"""
FAKE_GH = """#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ['WASHI_RELEASE_FIXTURE'])
state = json.loads((root / 'github.json').read_text())
args = sys.argv[1:]
if args[0] == 'api':
    endpoint = next(a for a in args if a.startswith('repos/'))
    resource = endpoint.split('/')[3]
    if state.get('fail') == resource:
        sys.exit('GitHub の確認に失敗')
    print(state['sha'] if resource == 'commits' else json.dumps(state[resource]))
elif args[:2] == ['release', 'create']:
    notes = pathlib.Path(args[args.index('--notes-file') + 1]).read_text()
    (root / 'published.json').write_text(json.dumps({'args': args, 'notes': notes}))
    print('https://github.com/example/Washi/releases/tag/' + args[2])
else:
    sys.exit('未対応の呼び出し: ' + repr(args))
"""


class GitHubReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="washi-publish-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "Washi source"
        (self.repo / "Scripts").mkdir(parents=True)
        self.script = self.repo / "Scripts" / SCRIPT.name
        shutil.copyfile(SCRIPT, self.script)
        self.changelog = self.repo / "CHANGELOG.md"
        self.changelog.write_text(CHANGELOG, encoding="utf-8")
        self.git("init", "--initial-branch=main", "--quiet")
        self.git("config", "user.name", "Washi release tests")
        self.git("config", "user.email", "tests@example.invalid")
        self.commit()
        self.state = {
            "sha": self.git("rev-parse", "HEAD").strip(),
            "tags": [[{"name": "1.9.0"}], [{"name": "1.10.0"}, {"name": "2.0.0-rc1"}]],
            "releases": [[]],
        }
        binary = self.root / "bin"
        binary.mkdir()
        gh = binary / "gh"
        gh.write_text(FAKE_GH, encoding="utf-8")
        gh.chmod(0o755)
        self.environment = dict(os.environ, PATH=f"{binary}{os.pathsep}{os.environ['PATH']}",
                                WASHI_RELEASE_FIXTURE=str(self.root))
        self.published = self.root / "published.json"

    def git(self, *args):
        return subprocess.run(
            ["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", *args],
            cwd=self.repo, check=True, capture_output=True, text=True,
        ).stdout

    def commit(self):
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "検証用データ")

    def run_publish(self, tag="1.10.0"):
        (self.root / "github.json").write_text(json.dumps(self.state), encoding="utf-8")
        return subprocess.run(
            [sys.executable, str(self.script), tag, "--repo", "example/Washi"],
            cwd=self.root, env=self.environment, capture_output=True, text=True,
        )

    def assert_rejected(self, fragment, tag="1.10.0"):
        result = self.run_publish(tag)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(fragment, result.stderr)
        self.assertFalse(self.published.exists())

    def test_latest_uses_numeric_version_across_all_pages_and_exact_notes(self):
        before = self.git("rev-parse", "HEAD")
        result = self.run_publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        published = json.loads(self.published.read_text())
        self.assertEqual(published["notes"], "### 修正\n- 対象の変更\n")
        self.assertIn("--latest", published["args"])
        self.assertIn("--verify-tag", published["args"])
        self.assertIn("example/Washi", published["args"])
        self.assertIn("Washi 1.10.0", published["args"])
        self.assertEqual(self.git("rev-parse", "HEAD"), before)
        self.assertEqual(self.git("tag", "--list"), "")
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_old_tag_cannot_move_latest_backwards(self):
        self.state["tags"].append([{"name": "1.11.0"}])
        result = self.run_publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--latest=false", json.loads(self.published.read_text())["args"])

    def test_v_prefixed_tag_uses_unprefixed_changelog(self):
        self.state["tags"] = [[{"name": "v1.10.0"}]]
        result = self.run_publish("v1.10.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.published.read_text())["notes"], "### 修正\n- 対象の変更\n")

    def test_published_release_is_preserved_on_retry(self):
        self.state["releases"] = [[], [{"tag_name": "1.10.0", "draft": False, "html_url": "existing"}]]
        result = self.run_publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("公開済み", result.stdout)
        self.assertFalse(self.published.exists())

    def test_existing_draft_requires_review(self):
        self.state["releases"] = [[{"tag_name": "1.10.0", "draft": True}]]
        self.assert_rejected("下書き")

    def test_missing_remote_tag_is_rejected(self):
        self.state["tags"] = [[{"name": "1.9.0"}]]
        self.assert_rejected("対象タグが存在しません")

    def test_tag_moved_after_ci_started_is_rejected(self):
        self.state["sha"] = "f" * 40
        self.assert_rejected("検証対象コミットが一致しません")

    def test_github_read_failures_never_create_a_release(self):
        for resource in ("tags", "commits", "releases"):
            with self.subTest(resource=resource):
                self.state["fail"] = resource
                self.assert_rejected("GitHub の確認に失敗")

    def test_invalid_or_prerelease_tags_are_rejected(self):
        for tag in ("1.10", "01.10.0", "1.10.0-rc1", "Unreleased", "--generate-notes"):
            with self.subTest(tag=tag):
                # 先頭がハイフンの引数は argparse が拒否する。
                self.assert_rejected("error:" if tag.startswith("--") else "確定版", tag)

    def test_unfinalized_empty_duplicate_or_invalid_dated_notes_are_rejected(self):
        for changelog in (
            "## [Unreleased]\n\n- 変更\n",
            "## [1.10.0] - 未定\n\n- 変更\n",
            "## [1.10.0] - 2026-02-30\n\n- 変更\n",
            "## [1.10.0] - 2026-09-14\n\n## [1.9.0] - 2026-09-13\n\n- 前の版\n",
            CHANGELOG + "\n## [1.10.0] - 未定\n",
        ):
            with self.subTest(changelog=changelog):
                self.changelog.write_text(changelog, encoding="utf-8")
                self.commit()
                self.state["sha"] = self.git("rev-parse", "HEAD").strip()
                self.assert_rejected("公開に失敗")

    def test_working_tree_cannot_replace_tested_changelog(self):
        self.changelog.write_text("## [1.10.0] - 2026-09-14\n\n- 未検証の変更\n", encoding="utf-8")
        result = self.run_publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.published.read_text())["notes"], "### 修正\n- 対象の変更\n")


if __name__ == "__main__":
    unittest.main()
