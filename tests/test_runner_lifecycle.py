"""Exercise both scheduled entry points with disposable input, engines and downstream CLIs."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
PWSH = shutil.which("pwsh")
DATE = "2026-11-03"
SELECTED = "https://incheonin.com/offline-selected"
EXCLUDED = "https://incheonin.com/offline-excluded"
TITLE = "인천교육청 언론보도 현황"
RUNNERS = {"Codex": "run-daily-news-picker.ps1", "Claude": "run-daily-news-picker-claude.ps1"}

# Each copy is invoked with the real command's arguments. Only synthetic data
# are read/written, including the arguments the organizer actually received.
FAKE_CLI = r'''
import json
import os
from pathlib import Path
import sys
import time

root = Path(os.environ["DNP_FIXTURE"])
args = sys.argv[1:]
actor = Path(__file__).stem

def value(flag):
    return args[args.index(flag) + 1]

def event(step, **details):
    with (root / "calls.jsonl").open("a", encoding="utf-8") as stream:
        stream.write(json.dumps({"step": step, **details}, ensure_ascii=False) + "\n")
    if os.environ.get("DNP_FAIL") == step:
        sys.exit(23)

if actor == "collect_news_rss":
    event("collect")
    if os.environ.get("DNP_SLOW_COLLECTOR"):
        time.sleep(4)
    destination = Path(value("--out-dir")) / "collected_articles.json"
    destination.write_bytes((root / "pool.json").read_bytes())
elif actor == "model":
    event("model")
    sys.stdin.buffer.read()
    if os.environ.get("DNP_BLOCK_ENGINE"):
        (root / "engine-ready").touch()
        deadline = time.monotonic() + 120
        while not (root / "engine-release").exists():
            if time.monotonic() > deadline:
                sys.exit(24)
            time.sleep(0.05)
    report = (root / "model-report.md").read_bytes()
    if "-o" in args:
        Path(value("-o")).write_bytes(report)
    else:
        sys.stdout.buffer.write(report)
elif actor == "newsdb" and "--briefing" in args:
    path = Path(value("--briefing"))
    event("briefing", file=path.name, text=path.read_text(encoding="utf-8-sig"))
elif actor == "newsdb" and "--json" in args:
    path = Path(value("--json"))
    event("json", file=path.name, payload=json.loads(path.read_text(encoding="utf-8-sig")))
elif actor == "newsdb" and args[0] in ("group", "digest"):
    event(args[0])
    if args[0] == "digest":
        Path(value("--out")).write_text("<html>digest</html>", encoding="utf-8")
elif actor == "publish_site":
    assert "--push" not in args
    event("site")
    if not os.environ.get("DNP_MISSING_ARCHIVE"):
        archive = Path(value("--site-dir")) / "archive" / (value("--date") + ".html")
        archive.parent.mkdir(parents=True, exist_ok=True)
        archive.write_text("<html>archive</html>", encoding="utf-8")
else:
    raise ValueError((actor, args))
'''

# This wrapper only forbids network calls. The tested script is invoked as a
# complete script with its real parameters, process launches and exit status.
OFFLINE_WRAPPER = r'''
function Invoke-RestMethod {
    [System.IO.File]::AppendAllText((Join-Path $env:DNP_FIXTURE 'network-attempt'), 'REST')
    throw 'Network disabled in offline runner test'
}
function Invoke-WebRequest {
    [System.IO.File]::AppendAllText((Join-Path $env:DNP_FIXTURE 'network-attempt'), 'HTTP')
    throw 'Network disabled in offline runner test'
}
$target, $tokens = $args
$parameters = @{}
for ($i = 0; $i -lt $tokens.Length; $i++) {
    $name = $tokens[$i].TrimStart('-')
    if ($name -in @('Force', 'DryRun')) {
        $parameters[$name] = $true
    } else {
        $parameters[$name] = $tokens[++$i]
    }
}
& $target @parameters
exit $LASTEXITCODE
'''


def marker(name, data):
    return f"<!-- {name}\n{json.dumps(data, ensure_ascii=False)}\n{name} -->\n"


class OfflineRunner:
    def __init__(self, root):
        self.root = root
        self.base = root / "결과"
        self.report_dir = self.base / f"{TITLE}(20261103)"
        self.profile = root / "profile"
        self.temp = root / "temp"
        self.site = root / "site"
        self.skill = self.profile / ".codex/skills/daily-news-picker"
        scripts = self.skill / "scripts"
        organizer = self.skill.parent / "edu-news-organizer/scripts"
        for directory in (scripts, organizer, self.temp, self.site, self.skill / "cache"):
            directory.mkdir(parents=True)
        shutil.copytree(ROOT / "references", self.skill / "references")
        for name in (*RUNNERS.values(), "promote_verified_candidates.py", "report-lifecycle.ps1"):
            shutil.copyfile(ROOT / "scripts" / name, scripts / name)
        shutil.copyfile(ROOT / "SKILL.md", self.skill / "SKILL.md")
        for script in (scripts / "collect_news_rss.py", organizer / "newsdb.py",
                       organizer / "publish_site.py", root / "model.py"):
            script.write_text(FAKE_CLI, encoding="utf-8")
        (self.skill / "cache/holidays-kr-2026.json").write_text("[]", encoding="utf-8")
        self.wrapper = root / "offline.ps1"
        self.wrapper.write_text(OFFLINE_WRAPPER, encoding="utf-8-sig")
        if os.name == "nt":
            self.engine = root / "engine.cmd"
            self.engine.write_bytes(b'@"%DNP_PYTHON%" "%DNP_FIXTURE%\\model.py" %*\r\n')
        else:
            self.engine = root / "engine"
            self.engine.write_text('#!/bin/sh\nexec "$DNP_PYTHON" "$DNP_FIXTURE/model.py" "$@"\n')
            self.engine.chmod(0o755)
        pool = {
            "window_start": "2026-11-02 09:00", "window_end": DATE + " 09:00",
            "article_count": 2, "failures": [], "articles": [
                {"title": title, "original_url": url, "publication_eligible": False}
                for title, url in (("선정 기사", SELECTED), ("제외 기사", EXCLUDED))
            ],
        }
        (root / "pool.json").write_text(json.dumps(pool), encoding="utf-8")
        self.write_report()

    def write_report(self, *, date=DATE, incomplete=False, empty=False):
        roster = (self.skill / "references/media-sources.md").read_text(encoding="utf-8")
        required = roster.split("## Required Source-Seed Domains", 1)[1].split("\n## ", 1)[0]
        checks = dict.fromkeys(re.findall(r"`site:([a-z0-9.-]+) ", required), "checked_empty")
        if not empty:
            checks["incheonin.com"] = "checked_found"
        if incomplete:
            checks.pop("incheontoday.com")
        manifest = [] if empty else [{
            "original_url": SELECTED, "verified": True, "publication_eligible": True,
            "verification_basis": "합성 기사 본문에서 인천 학교 학생의 교육활동을 확인함",
        }]
        main = "확인된 유의미 기사 없음" if empty else f"■ 선정 기사 - 합성매체\n{SELECTED}"
        content = (
            f"# {TITLE}\n\n- 보고일: {date}\n"
            f"- 점검 창: 2026-11-02 09:00 ~ {DATE} 09:00 (Asia/Seoul)\n\n"
            f"## 주요 언론보도\n\n{main}\n\n"
            f"## 제외 또는 참고\n\n■ 제외 기사 - 합성매체\n{EXCLUDED}\n\n"
            + marker("DAILY_NEWS_VERIFIED_CANDIDATES", manifest)
            + marker("DAILY_NEWS_SOURCE_CHECKS", checks)
        )
        (self.root / "model-report.md").write_text(content, encoding="utf-8")

    def start(self, engine, *flags, **overrides):
        env = {
            **os.environ, "USERPROFILE": str(self.profile), "HOME": str(self.profile),
            "TEMP": str(self.temp), "TMP": str(self.temp), "TMPDIR": str(self.temp),
            "DNP_PYTHON": sys.executable, "DNP_FIXTURE": str(self.root), "PYTHONUTF8": "1",
            "PYTHONDONTWRITEBYTECODE": "1", "EDU_NEWS_DB_PATH": str(self.root / "fixture.db"),
            "EDU_NEWS_SITE_PUSH": "0", **overrides,
        }
        # PowerShell must bind named parameters as tokens at its -File boundary.
        # The wrapper receives raw strings so it uses a hashtable for the call.
        return subprocess.Popen([
            PWSH, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-File", str(self.wrapper), str(self.skill / "scripts" / RUNNERS[engine]),
            "-BasePath", str(self.base), "-WorkingRoot", str(self.profile),
            "-SiteDir", str(self.site), "-PythonCommand", sys.executable,
            f"-{engine}Command", str(self.engine), "-ReportDate", DATE,
            "-CollectionTime", "09:00", "-MaxAttempts", "1", *flags,
        ], env=env, cwd=self.root, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, encoding="utf-8", errors="replace")

    def calls(self):
        path = self.root / "calls.jsonl"
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]

    def steps(self):
        return [event["step"] for event in self.calls()]


class RunnerLifecycleCases:
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.fixture = OfflineRunner(Path(directory.name))

    def tearDown(self):
        self.assertFalse((self.fixture.root / "network-attempt").exists())

    def finish(self, process, *, success=True):
        try:
            output, _ = process.communicate(timeout=100)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
        if success:
            self.assertEqual(0, process.returncode, output)
        else:
            self.assertNotEqual(0, process.returncode, output)
        self.assertFalse((self.fixture.root / "network-attempt").exists(), output)
        return output

    def run_entry(self, *flags, success=True, **env):
        return self.finish(self.fixture.start(self.engine, *flags, **env), success=success)

    def test_resume_failed_digest_and_skip_completed_run(self):
        fixture = self.fixture
        self.run_entry(success=False, DNP_FAIL="digest")
        self.assertEqual(["collect", "model", "briefing", "json", "group", "digest"], fixture.steps())
        briefing, candidates = fixture.calls()[2:4]
        self.assertEqual("selected-briefing.md", briefing["file"])
        self.assertIn(f"보고일: {DATE}", briefing["text"])
        self.assertIn(SELECTED, briefing["text"])
        self.assertNotIn(EXCLUDED, briefing["text"])
        self.assertNotIn("DAILY_NEWS_", briefing["text"])
        self.assertEqual("verified_collected_articles.json", candidates["file"])
        by_url = {row["original_url"]: row["publication_eligible"] for row in candidates["payload"]["articles"]}
        self.assertEqual({SELECTED: True, EXCLUDED: False}, by_url)
        self.assertIn(EXCLUDED, (fixture.report_dir / (TITLE + ".md")).read_text(encoding="utf-8"))
        self.assertTrue((fixture.report_dir / "report-state.json").is_file())
        self.run_entry()
        self.assertEqual(["collect", "model", "briefing", "json", "group", "digest", "digest", "site"], fixture.steps())
        before = fixture.calls()
        self.run_entry()
        self.assertEqual(before, fixture.calls())

    def test_force_with_wrong_date_or_missing_outlet_preserves_published_files(self):
        fixture = self.fixture
        self.run_entry()
        preserved = (TITLE + ".md", TITLE + ".html", "selected-briefing.md",
                     "collected_articles.json", "verified_collected_articles.json",
                     "verification-manifest.json", "report-state.json")
        good = {name: (fixture.report_dir / name).read_bytes() for name in preserved}
        good_steps = fixture.steps()
        for failure in ({"date": "2026-11-02"}, {"incomplete": True}):
            with self.subTest(failure=failure):
                fixture.write_report(**failure)
                self.run_entry("-Force", success=False)
                self.assertEqual(good, {name: (fixture.report_dir / name).read_bytes() for name in good})
                good_steps += ["collect", "model"]
                self.assertEqual(good_steps, fixture.steps())
        self.assertTrue((fixture.report_dir / "수집 미완료.md").is_file())

    def test_zero_fallback_requires_coverage_and_ingests_a_dated_empty_snapshot(self):
        fixture = self.fixture
        fixture.write_report(empty=True, incomplete=True)
        self.run_entry(success=False, DNP_FAIL="collect")
        partial = (fixture.report_dir / "수집 미완료.md").read_text(encoding="utf-8")
        self.assertNotIn("확인된 유의미 기사 없음", partial)
        self.assertIn("incheontoday.com", partial)
        self.assertEqual(["collect", "model"], fixture.steps())

        fixture.write_report(empty=True)
        raw = fixture.root / "model-report.md"
        unverified = fixture.root / "zero-without-checks.md"
        unverified.write_text(raw.read_text(encoding="utf-8").split("<!--")[0], encoding="utf-8")
        self.run_entry("-ValidateReportPath", str(unverified), success=False)
        self.run_entry("-CollectorTimeoutSeconds", "1", DNP_SLOW_COLLECTOR="1")
        records = fixture.calls()
        self.assertEqual(["collect", "model", "collect", "model", "briefing", "json", "group", "digest", "site"],
                         fixture.steps())
        self.assertEqual(f"- 보고일: {DATE}", records[4]["text"].strip())
        self.assertEqual([], records[5]["payload"]["articles"])
        self.assertEqual(DATE + " 09:00", records[5]["payload"]["window_end"])
        final_report = fixture.report_dir / (TITLE + ".md")
        self.run_entry("-ValidateReportPath", str(final_report))
        self.assertEqual(records, fixture.calls())

    def test_pending_report_transaction_restores_last_good_batch_without_recollecting(self):
        fixture = self.fixture
        self.run_entry()
        directory = fixture.report_dir
        state = directory / "report-state.json"
        names = [*json.loads(state.read_text(encoding="utf-8-sig"))["hashes"], state.name]
        good = {name: (directory / name).read_bytes() for name in names}
        previous_calls = fixture.calls()
        backup = directory / ".report-backup"
        backup.mkdir(exist_ok=True)
        for name in good:
            shutil.copyfile(directory / name, backup / name)
        journal = directory / ".report-pending"
        journal.write_text("prepared", encoding="utf-8")
        (directory / (TITLE + ".md")).write_text("interrupted replacement", encoding="utf-8")
        (directory / "selected-briefing.md").unlink()
        state.write_text("{", encoding="utf-8")

        self.run_entry()
        self.assertFalse(journal.exists())
        self.assertEqual(good, {name: (directory / name).read_bytes() for name in names})
        self.assertEqual(previous_calls, fixture.calls())

    def test_dry_run_with_force_preserves_existing_files_and_current_workspace(self):
        fixture = self.fixture
        engine_work = fixture.temp / f"DailyNewsPicker{self.engine}Work" / "current"
        engine_work.mkdir(parents=True)
        sentinel = engine_work / "last-message.md"
        sentinel.write_text("previous work", encoding="utf-8")
        self.run_entry("-DryRun", "-Force")
        self.assertFalse(fixture.base.exists())
        self.assertEqual("previous work", sentinel.read_text(encoding="utf-8"))
        self.run_entry()
        files = {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in fixture.base.rglob("*") if p.is_file()}
        self.run_entry("-Force", "-DryRun")
        self.assertEqual(files, {p: (p.read_bytes(), p.stat().st_mtime_ns)
                                 for p in fixture.base.rglob("*") if p.is_file()})
        self.assertEqual(1, fixture.steps().count("collect"))
        self.assertEqual(1, fixture.steps().count("model"))

    def test_empty_report_pair_is_regenerated_and_site_must_write_archive(self):
        fixture = self.fixture
        fixture.report_dir.mkdir(parents=True)
        for extension in (".md", ".html"):
            (fixture.report_dir / (TITLE + extension)).touch()
        self.run_entry(success=False, DNP_MISSING_ARCHIVE="1")
        self.assertEqual("site", fixture.steps()[-1])
        self.assertIn(SELECTED, (fixture.report_dir / (TITLE + ".md")).read_text(encoding="utf-8"))
        self.assertIn(SELECTED, (fixture.report_dir / (TITLE + ".html")).read_text(encoding="utf-8"))
        before = fixture.steps()
        self.run_entry()
        self.assertEqual(before + ["site"], fixture.steps())
        self.assertTrue((fixture.site / "archive" / (DATE + ".html")).is_file())

    def test_concurrent_runs_protect_date_and_shared_engine_workspace(self):
        fixture = self.fixture
        first = fixture.start(self.engine, DNP_BLOCK_ENGINE="1")
        try:
            deadline = time.monotonic() + 60
            while not (fixture.root / "engine-ready").exists():
                if first.poll() is not None:
                    self.fail(first.communicate()[0])
                if time.monotonic() >= deadline:
                    self.fail("The fake engine did not enter its blocking section")
                time.sleep(0.05)
            other = "Claude" if self.engine == "Codex" else "Codex"
            for engine, date in ((other, DATE), (self.engine, "2026-11-04")):
                with self.subTest(contending_engine=engine, date=date):
                    second = fixture.start(engine, "-ReportDate", date)
                    self.finish(second, success=False)
                    self.assertEqual(["collect", "model"], fixture.steps())
        finally:
            (fixture.root / "engine-release").touch()
            self.finish(first)
        self.assertEqual(["collect", "model", "briefing", "json", "group", "digest", "site"], fixture.steps())


@unittest.skipUnless(PWSH, "PowerShell 7 is required")
class CodexRunnerLifecycleTest(RunnerLifecycleCases, unittest.TestCase):
    engine = "Codex"


@unittest.skipUnless(PWSH, "PowerShell 7 is required")
class ClaudeRunnerLifecycleTest(RunnerLifecycleCases, unittest.TestCase):
    engine = "Claude"


if __name__ == "__main__":
    unittest.main(verbosity=2)
