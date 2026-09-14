"""一時 Git リポジトリでリリース前検証の拒否条件と公開先の参照を確認する。"""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "Scripts" / "release.sh"


class ReleasePreflightTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="washi-release-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "Washi source"
        self.remote = self.root / "public.git"
        self.repo.mkdir()
        self.git("init", "--initial-branch=main", "--quiet")
        self.git("config", "user.name", "Washi release tests")
        self.git("config", "user.email", "tests@example.invalid")
        self.git("init", "--bare", "--quiet", str(self.remote))
        self.git("remote", "add", "origin", str(self.remote))
        (self.repo / "Scripts").mkdir()
        self.script = self.repo / "Scripts" / "release.sh"
        shutil.copyfile(SCRIPT, self.script)
        self.changelog = self.repo / "CHANGELOG.md"
        self.changelog.write_text("# 変更履歴\n\n## [1.2.0] - 2026-09-14\n", encoding="utf-8")
        self.commit()

    def git(self, *args):
        return subprocess.run(
            ["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", *args],
            cwd=self.repo, check=True, capture_output=True, text=True,
        ).stdout

    def commit(self):
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "検証用データ")

    def publish_tag(self, version):
        # ローカルに存在しない公開済みタグも必ず検査されるようにする。
        self.git("push", "--quiet", "origin", f"HEAD:refs/tags/{version}")

    def run_check(self, *arguments):
        return subprocess.run(
            ["sh", str(self.script), *(arguments or ("1.2.0",))],
            cwd=self.root, capture_output=True, text=True,
        )

    def assert_rejected(self, fragment, *arguments):
        result = self.run_check(*arguments)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(fragment, result.stderr)

    def test_clean_release_works_from_another_directory_without_mutation(self):
        self.publish_tag("1.1.0")
        before = (self.git("rev-parse", "HEAD"), self.git("show-ref"))
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1.1.0", result.stdout)
        self.assertEqual(before, (self.git("rev-parse", "HEAD"), self.git("show-ref")))
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_first_release_without_public_tags(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("最新タグ: なし", result.stdout)

    def test_uncommitted_changelog_is_rejected(self):
        self.changelog.write_text(self.changelog.read_text() + "変更\n")
        self.assert_rejected("クリーンではありません")

    def test_untracked_file_is_rejected(self):
        (self.repo / "untracked.txt").write_text("未追跡")
        self.assert_rejected("クリーンではありません")

    def test_staged_file_is_rejected(self):
        (self.repo / "staged.txt").write_text("ステージ済み")
        self.git("add", "staged.txt")
        self.assert_rejected("クリーンではありません")

    def test_version_must_be_a_stable_three_part_number(self):
        for version in ("1.2", "01.2.0", "1.2.0-rc1", "v1.2.0"):
            with self.subTest(version=version):
                self.assert_rejected("X.Y.Z", version)

    def test_missing_or_unreleased_changelog_heading_is_rejected(self):
        for heading in ("## [Unreleased]", "## [1.2.0] - 未定", "## [1.1.0] - 2026-09-14"):
            with self.subTest(heading=heading):
                self.changelog.write_text(heading + "\n")
                self.commit()
                self.assert_rejected("確定見出し")

    def test_invalid_calendar_date_is_rejected(self):
        self.changelog.write_text("## [1.2.0] - 2026-02-30\n")
        self.commit()
        self.assert_rejected("実在する日付")

    def test_duplicate_changelog_heading_is_rejected(self):
        self.changelog.write_text(self.changelog.read_text() * 2)
        self.commit()
        self.assert_rejected("ちょうど1件")

    def test_equal_or_older_public_version_is_rejected(self):
        for version in ("1.2.0", "v1.10.0"):
            with self.subTest(version=version):
                self.publish_tag(version)
                self.assert_rejected("より新しくありません")

    def test_unpublished_local_tag_does_not_replace_public_state(self):
        self.publish_tag("1.1.0")
        self.git("tag", "99.0.0")
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1.1.0", result.stdout)

    def test_unreachable_remote_fails_closed(self):
        self.assert_rejected("Git の確認に失敗", "1.2.0", "--remote", str(self.root / "missing.git"))


if __name__ == "__main__":
    unittest.main()
