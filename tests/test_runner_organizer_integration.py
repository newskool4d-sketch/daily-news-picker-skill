"""Verify the installed organizer's real ingest and static site using an isolated DB."""
from contextlib import closing
from pathlib import Path
import shutil
import sqlite3
import tempfile
import unittest

from test_runner_lifecycle import DATE, EXCLUDED, OfflineRunner, PWSH, ROOT, SELECTED, TITLE
from test_runner_reports import load_organizer_share_parser


ORGANIZER = ROOT.parent / "edu-news-organizer"


@unittest.skipUnless(PWSH and (ORGANIZER / "scripts/publish_site.py").is_file(),
                     "PowerShell 7 and the connected organizer are required")
class OrganizerPublicationTest(unittest.TestCase):
    def test_only_selected_article_reaches_site_then_zero_clears_old_selection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = OfflineRunner(root)
            organizer = fixture.skill.parent / "edu-news-organizer"
            for name in ("newsdb.py", "publish_site.py", "digest_html.py", "incheon_logo.txt",
                         "incheon_masttitle.txt", "incheon_slogan.txt"):
                shutil.copyfile(ORGANIZER / "scripts" / name, organizer / "scripts" / name)
            (organizer / "references").mkdir()
            shutil.copyfile(ORGANIZER / "references/publication-contract.json",
                            organizer / "references/publication-contract.json")
            db = root / "test.sqlite"
            for empty in (False, True):
                with self.subTest(empty=empty):
                    fixture.write_report(empty=empty)
                    flags = ["-Force"] if empty else []
                    process = fixture.start("Claude", *flags, EDU_NEWS_DB_PATH=str(db))
                    try:
                        output, _ = process.communicate(timeout=90)
                    finally:
                        if process.poll() is None:
                            process.kill()
                            process.communicate()
                    self.assertEqual(0, process.returncode, output)
                    with closing(sqlite3.connect(db)) as conn:
                        urls = conn.execute(
                            "SELECT a.original_url FROM article_selections s JOIN articles a "
                            "ON a.article_id=s.article_id WHERE s.batch_date=?", (DATE,)
                        ).fetchall()
                    self.assertEqual([] if empty else [(SELECTED,)], urls)
                    full_report = (fixture.report_dir / (TITLE + ".md")).read_text(encoding="utf-8")
                    manual_import = load_organizer_share_parser()(full_report.splitlines())
                    self.assertEqual([u for (u,) in urls], [a["original_url"] for a in manual_import])
                    archive = (fixture.site / "archive" / f"{DATE}.html").read_text(encoding="utf-8")
                    self.assertEqual(not empty, SELECTED in archive)
                    self.assertNotIn(EXCLUDED, archive)
