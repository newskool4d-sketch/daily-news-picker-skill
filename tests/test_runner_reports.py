# -*- coding: utf-8 -*-
"""Offline checks of report formatting, rendering and engine arguments.

test_runner_lifecycle exercises the complete entry points with synthetic inputs.
"""

import ast
import json
import re
import shutil
import subprocess
import tempfile
import unittest
from html.parser import HTMLParser
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RUNNERS = (
    ROOT / "scripts" / "run-daily-news-picker.ps1",
    ROOT / "scripts" / "run-daily-news-picker-claude.ps1",
)
WINDOW_START = "2026-11-02 09:00"
WINDOW_END = "2026-11-03 09:00"
ORGANIZER = ROOT.parent / "edu-news-organizer" / "scripts" / "newsdb.py"

# Only top-level function definitions are evaluated. In particular, do not
# dot-source the runner: its top-level code calculates holidays and starts work.
POWERSHELL_HARNESS = r"""
param([string]$RunnerPath, [string]$RequestPath)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $RunnerPath, [ref]$tokens, [ref]$parseErrors
)
if (@($parseErrors).Count -ne 0) { throw 'Runner PowerShell syntax is invalid' }
$definitions = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Parent -is [System.Management.Automation.Language.NamedBlockAst] -and
        $node.Parent.Parent -eq $ast
}, $true)
foreach ($definition in $definitions) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$windowStartDisplay = [string]$request.window_start
$windowEndDisplay = [string]$request.window_end
$reportDateDisplay = '2026-11-03'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
if ($request.repair) {
    Repair-MarkdownReport -Path $request.report_path
}
$failures = @(Get-MarkdownReportValidationFailures -Path $request.report_path)
$rendered = $null
if ($request.render) {
    Convert-MarkdownToHtmlDocument -MarkdownPath $request.report_path `
        -HtmlPath $request.html_path -Title '인천교육청 언론보도 현황'
    $rendered = [System.IO.File]::ReadAllText($request.html_path)
}
[pscustomobject]@{
    failures = $failures
    html = $rendered
    markdown = [System.IO.File]::ReadAllText($request.report_path)
} |
    ConvertTo-Json -Depth 8 -Compress
"""


POWERSHELL_CLAUDE_ARGUMENTS = r"""
param([string]$RunnerPath, [string]$FixtureSkillRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $RunnerPath, [ref]$tokens, [ref]$parseErrors
)
if (@($parseErrors).Count -ne 0) { throw 'Runner PowerShell syntax is invalid' }
$assignments = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -eq 'argList'
}, $true))
if ($assignments.Count -ne 1) { throw 'Review the Claude argument construction' }
$right = $assignments[0].Right
$commands = @($right.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst]
}, $true))
if ($commands.Count -ne 0) { throw 'Do not run commands while reading arguments' }
$Model = 'offline-fixture-model'
$skillRoot = $FixtureSkillRoot
$arguments = @(Invoke-Expression $right.Extent.Text)
[pscustomobject]@{ arguments = $arguments } | ConvertTo-Json -Depth 4 -Compress
"""


def report(main_body, following=""):
    return (
        "# 인천교육청 언론보도 현황\n\n"
        "- 보고일: 2026-11-03\n"
        f"- 점검 창: {WINDOW_START} ~ {WINDOW_END} (Asia/Seoul)\n\n"
        "## 주요 언론보도\n\n"
        f"{main_body}\n"
        f"{following}"
    )


def load_organizer_share_parser():
    """Load only the real share parser and its regex, never DB/CLI module code."""
    source = ast.parse(ORGANIZER.read_text(encoding="utf-8-sig"), filename=str(ORGANIZER))
    selected = [
        node
        for node in source.body
        if (
            isinstance(node, ast.FunctionDef) and node.name == "_parse_share_lines"
        )
        or (
            isinstance(node, ast.Assign)
            and any(
                isinstance(target, ast.Name) and target.id == "ARTICLE_LINE_RE"
                for target in node.targets
            )
        )
    ]
    if len(selected) != 2:
        raise AssertionError("Organizer share-parser contract must be reviewed")
    namespace = {"re": re}
    exec(
        compile(ast.Module(body=selected, type_ignores=[]), str(ORGANIZER), "exec"),
        namespace,
    )
    return namespace["_parse_share_lines"]


class ReportHtml(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.hrefs = []
        self.events = []
        self.tags = []
        self.attributes = []
        self.anchor_depth = 0
        self.nested_anchor = False

    def handle_starttag(self, tag, attrs):
        self.events.append(("start", tag))
        self.tags.append(tag)
        self.attributes.extend(attrs)
        if tag == "a":
            self.anchor_depth += 1
            self.nested_anchor |= self.anchor_depth > 1
            self.hrefs.append(dict(attrs).get("href"))

    def handle_endtag(self, tag):
        self.events.append(("end", tag))
        if tag == "a":
            self.anchor_depth -= 1

    def handle_data(self, data):
        self.events.append(("text", data))

    def line_break_before_link(self, title):
        title_index = next(
            index
            for index, event in enumerate(self.events)
            if event[0] == "text" and title in event[1]
        )
        link_index = next(
            index
            for index in range(title_index + 1, len(self.events))
            if self.events[index] == ("start", "a")
        )
        return any(
            event[0] in {"start", "end"}
            and event[1] in {"br", "p", "div", "li"}
            for event in self.events[title_index + 1 : link_index]
        )


@unittest.skipUnless(shutil.which("pwsh"), "PowerShell 7 is required")
class RunnerReportFunctionsTest(unittest.TestCase):
    def evaluate(self, runner, markdown, *, render=False, repair=True):
        with tempfile.TemporaryDirectory() as temporary:
            temporary_path = Path(temporary)
            harness_path = temporary_path / "report-functions.ps1"
            report_path = temporary_path / "report.md"
            request_path = temporary_path / "request.json"
            html_path = temporary_path / "report.html"
            harness_path.write_text(POWERSHELL_HARNESS, encoding="utf-8-sig")
            report_path.write_text(markdown, encoding="utf-8")
            request_path.write_text(
                json.dumps(
                    {
                        "window_start": WINDOW_START,
                        "window_end": WINDOW_END,
                        "report_path": str(report_path),
                        "html_path": str(html_path),
                        "render": render,
                        "repair": repair,
                    },
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
            completed = subprocess.run(
                [
                    shutil.which("pwsh"),
                    "-NoProfile",
                    "-NonInteractive",
                    "-File",
                    str(harness_path),
                    "-RunnerPath",
                    str(runner),
                    "-RequestPath",
                    str(request_path),
                ],
                capture_output=True,
                stdin=subprocess.DEVNULL,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=30,
            )
            self.assertEqual(
                0, completed.returncode, completed.stderr or completed.stdout
            )
            return json.loads(completed.stdout)

    def test_each_article_accepts_plain_or_markdown_url_with_category_headings(self):
        markdown = report(
            "### 정책·현안\n\n"
            "■ 정책 기사 - 테스트매체\nhttps://example.com/policy?id=1&source=ice\n\n"
            "### 학교·학생\n\n"
            "■ 학교 기사 - 다른매체\n[원문](https://example.org/school(1))\n"
        )
        for runner in RUNNERS:
            with self.subTest(runner=runner.name):
                self.assertEqual([], self.evaluate(runner, markdown)["failures"])

    @unittest.skipUnless(ORGANIZER.is_file(), "The connected edu-news-organizer is required")
    def test_repaired_links_preserve_organizer_article_count_and_urls(self):
        urls = [
            "https://example.com/policy?first=1&second=2",
            "https://example.org/학교(1)?name=학생",
            "http://example.net/affiliated",
        ]
        markdown = report(
            f"■ 정책 기사 - 테스트매체\n\n원문은 아래 링크입니다.\n{urls[0]}\n\n"
            f"### 학교\n\n■ 학교 기사 - 다른매체\n[매체 원문]({urls[1]})\n\n"
            "■ 기관 기사 - 지역매체\nHTTP://example.net/affiliated\n"
        )
        parse_share_lines = load_organizer_share_parser()
        for runner in RUNNERS:
            with self.subTest(runner=runner.name):
                result = self.evaluate(runner, markdown)
                self.assertEqual([], result["failures"])
                parsed = parse_share_lines(result["markdown"].splitlines())
                self.assertEqual(3, len(parsed))
                self.assertEqual(urls, [article["original_url"] for article in parsed])
                self.assertEqual(
                    ["정책 기사", "학교 기사", "기관 기사"],
                    [article["title"] for article in parsed],
                )
                lines = result["markdown"].splitlines()
                for index, line in enumerate(lines):
                    if line.startswith("■ "):
                        self.assertIn(lines[index + 1], urls)

    def test_missing_second_url_is_not_filled_by_first_article(self):
        markdown = report(
            "■ 첫 기사 - 테스트매체\nhttps://example.com/first\n\n"
            "■ 둘째 기사 - 다른매체\n본문 설명만 있고 원문 링크는 없음\n"
        )
        for runner in RUNNERS:
            with self.subTest(runner=runner.name):
                self.assertIn("article_2_url", self.evaluate(runner, markdown)["failures"])

    def test_missing_first_url_is_not_filled_by_next_article(self):
        markdown = report(
            "■ 첫 기사 - 테스트매체\n링크 없음\n\n"
            "■ 둘째 기사 - 다른매체\nhttps://example.com/second\n"
        )
        for runner in RUNNERS:
            with self.subTest(runner=runner.name):
                self.assertIn("article_1_url", self.evaluate(runner, markdown)["failures"])

    def test_reference_or_next_category_url_cannot_fill_missing_article(self):
        for following in (
            "\n## 제외 또는 참고\n\nhttps://example.com/reference\n",
            "\n### 다른 분류\n\nhttps://example.com/orphan\n",
        ):
            markdown = report("■ 기사 - 테스트매체\n", following)
            for runner in RUNNERS:
                with self.subTest(runner=runner.name, following=following):
                    self.assertIn(
                        "article_1_url", self.evaluate(runner, markdown)["failures"]
                    )

    def test_repair_cannot_turn_excluded_articles_into_selected_coverage(self):
        markdown = report("").replace("## 주요 언론보도\n", "")
        markdown += "## 제외 또는 참고\n\n■ 제외 기사 - 테스트매체\nhttps://example.org/excluded\n"
        for runner in RUNNERS:
            with self.subTest(runner=runner.name):
                result = self.evaluate(runner, markdown)
                self.assertIn("main_section", result["failures"])
                self.assertNotIn("## 주요 언론보도", result["markdown"])
                self.assertIn("## 제외 또는 참고", result["markdown"])

    def test_relative_non_http_or_hostless_urls_are_rejected(self):
        for url in (
            "/news/123",
            "ftp://example.com/news",
            "file:///C:/news.html",
            "javascript:alert(1)",
            "https:///no-host",
            "https://",
        ):
            for runner in RUNNERS:
                with self.subTest(runner=runner.name, url=url):
                    markdown = report(f"■ 기사 - 테스트매체\n{url}\n")
                    self.assertIn(
                        "article_1_url", self.evaluate(runner, markdown)["failures"]
                    )

    def test_no_article_result_is_valid_without_article_url(self):
        for runner in RUNNERS:
            with self.subTest(runner=runner.name):
                self.assertEqual(
                    [],
                    self.evaluate(runner, report("확인된 유의미 기사 없음\n"))["failures"],
                )

    def test_no_article_declaration_conflicts_with_article_list(self):
        markdown = report(
            "확인된 유의미 기사 없음\n\n"
            "■ 실제 기사 - 테스트매체\nhttps://example.com/article\n"
        )
        for runner in RUNNERS:
            with self.subTest(runner=runner.name):
                self.assertIn(
                    "article_list_conflict", self.evaluate(runner, markdown)["failures"]
                )

    def test_plain_url_becomes_clickable_on_a_separate_line(self):
        title = "■ 한글 기사 - 테스트매체"
        url = "https://example.com/학교(안전)?first=1&name=학생&quote=%22보호자%22"
        markdown = report(f"{title}\n{url}\n")
        for runner in RUNNERS:
            with self.subTest(runner=runner.name):
                result = self.evaluate(runner, markdown, render=True)
                self.assertEqual([], result["failures"])
                parsed = ReportHtml()
                parsed.feed(result["html"])
                self.assertEqual([url], parsed.hrefs)
                self.assertFalse(parsed.nested_anchor)
                self.assertTrue(parsed.line_break_before_link(title))

    def test_mixed_links_keep_balanced_parentheses_and_escaped_query(self):
        urls = [
            "https://example.com/학교(1)?first=1&second=2",
            "https://example.org/도서관(연수)?name=학생&quote=%27책%27",
        ]
        markdown = report(
            f"■ 평문 기사 - 테스트매체\n{urls[0]}\n\n"
            f"■ 링크 기사 - 다른매체\n[원문 기사]({urls[1]})\n"
        )
        for runner in RUNNERS:
            with self.subTest(runner=runner.name):
                # Exercise the renderer's Markdown support directly as well as
                # the repaired/plain-URL workflow covered by the organizer test.
                result = self.evaluate(runner, markdown, render=True, repair=False)
                parsed = ReportHtml()
                parsed.feed(result["html"])
                self.assertEqual(urls, parsed.hrefs)
                self.assertFalse(parsed.nested_anchor)
                self.assertIn("&amp;", result["html"])

    def test_html_like_article_title_is_displayed_without_active_tags(self):
        article_title = '■ <img src=x onerror=alert(1)> & "교육" - 테스트매체'
        markdown = report(f"{article_title}\nhttps://example.com/safe\n")
        for runner in RUNNERS:
            with self.subTest(runner=runner.name):
                result = self.evaluate(runner, markdown, render=True)
                self.assertEqual([], result["failures"])
                parsed = ReportHtml()
                parsed.feed(result["html"])
                self.assertNotIn("img", parsed.tags)
                self.assertFalse(any(name == "onerror" for name, _ in parsed.attributes))
                self.assertIn("&lt;img", result["html"])
                self.assertTrue(
                    any(
                        event[0] == "text" and article_title in event[1]
                        for event in parsed.events
                    )
                )

    def test_claude_arguments_limit_tools_without_permission_bypass(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness_path = Path(temporary) / "claude-arguments.ps1"
            harness_path.write_text(POWERSHELL_CLAUDE_ARGUMENTS, encoding="utf-8-sig")
            completed = subprocess.run(
                [
                    shutil.which("pwsh"),
                    "-NoProfile",
                    "-NonInteractive",
                    "-File",
                    str(harness_path),
                    "-RunnerPath",
                    str(RUNNERS[1]),
                    "-FixtureSkillRoot",
                    str(ROOT),
                ],
                capture_output=True,
                stdin=subprocess.DEVNULL,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=30,
            )
            self.assertEqual(
                0, completed.returncode, completed.stderr or completed.stdout
            )
            arguments = json.loads(completed.stdout)["arguments"]

        def value_after(flag):
            self.assertEqual(1, arguments.count(flag), flag)
            return arguments[arguments.index(flag) + 1]

        expected_tools = {"Read", "Glob", "Grep", "WebSearch", "WebFetch"}
        self.assertEqual(expected_tools, set(re.split(r"[,\s]+", value_after("--tools"))))
        self.assertEqual(
            expected_tools, set(re.split(r"[,\s]+", value_after("--allowedTools")))
        )
        self.assertEqual("dontAsk", value_after("--permission-mode"))
        self.assertNotIn("bypassPermissions", arguments)
        self.assertIn("--safe-mode", arguments)
        self.assertEqual(ROOT.resolve(), Path(value_after("--add-dir")).resolve())
        after_read_root = arguments[arguments.index("--add-dir") + 2 :]
        self.assertTrue(
            not after_read_root or after_read_root[0].startswith("--"),
            "Only the skill root may be added; parent directories are not allowed",
        )
        self.assertIn("--strict-mcp-config", arguments)
        self.assertEqual({"mcpServers": {}}, json.loads(value_after("--mcp-config")))


if __name__ == "__main__":
    unittest.main(verbosity=2)
