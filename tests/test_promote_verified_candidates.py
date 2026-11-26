# -*- coding: utf-8 -*-
import importlib.util
import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "promote_verified_candidates", ROOT / "scripts" / "promote_verified_candidates.py"
)
PROMOTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROMOTER)

SELECTED = "https://example.com/article?id=1"
CANDIDATE = "https://EXAMPLE.com/article?utm_source=rss&id=1"
REFERENCE = "https://local.example/background"
EXTERNAL = "https://extra.example/follow-up(1)"
ROSTER = ROOT / "references" / "media-sources.md"
VERIFIED = "DAILY_NEWS_VERIFIED_CANDIDATES"
CHECKS = "DAILY_NEWS_SOURCE_CHECKS"


def marker(name, value):
    return f"<!-- {name}\n{json.dumps(value, ensure_ascii=False)}\n{name} -->\n"


def evidence(url=SELECTED):
    return {
        "original_url": url,
        "verified": True,
        "publication_eligible": True,
        "verification_basis": "본문에 인천교육청과 학교의 시설 공동점검 일정이 명시됨",
        "verified_at": "2026-08-20T00:00:00+00:00",
    }


def report(body, manifest, checks="", date_header="- 보고일: 2026-08-20"):
    return (
        f"# 인천교육청 언론보도 현황\n\n{date_header}\n\n"
        "## 핵심 요약\n\n■ 요약에만 있는 기사 - 매체\nhttps://summary.example/item\n\n"
        f"## 주요 언론보도\n\n{body}\n\n"
        f"## 제외 또는 참고\n\n■ 제외 기사 - 다른매체\n{REFERENCE}\n\n"
        f"{manifest}{checks}"
    )


class PromoteVerifiedCandidatesTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.raw = self.root / "collected.json"
        self.report = self.root / "report.md"
        self.output = self.root / "verified.json"
        self.audit = self.root / "verification-manifest.json"
        self.briefing = self.root / "organizer.md"
        self.payload = {"articles": [
            {"title": "인천교육청 시설 공동점검", "original_url": CANDIDATE},
            {"title": "참고 기사", "original_url": REFERENCE, "publication_eligible": True},
        ]}
        self.raw.write_text(json.dumps(self.payload, ensure_ascii=False), encoding="utf-8")
        self.main_article = f"■ 인천교육청 시설 공동점검 - 매체\n{SELECTED}"

    def invoke(self, source, *, with_pool=True, with_roster=False):
        self.report.write_text(source, encoding="utf-8")
        args = ["--report", str(self.report), "--output", str(self.output),
                "--manifest-output", str(self.audit), "--briefing-output", str(self.briefing)]
        if with_pool:
            args += ["--input", str(self.raw)]
        if with_roster:
            args += ["--coverage-roster", str(ROSTER)]
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()) as errors:
            code = PROMOTER.main(args)
        return code, errors.getvalue()

    def assert_failure(self, source, *, with_roster=False):
        code, error = self.invoke(source, with_roster=with_roster)
        self.assertEqual(code, 2, error)
        self.assertTrue(error)
        self.assertEqual(self.report.read_text(encoding="utf-8"), source)
        for path in [self.output, self.audit, self.briefing]:
            self.assertFalse(path.exists(), path)

    def json_at(self, path):
        return json.loads(path.read_text(encoding="utf-8"))

    def test_briefing_and_promotion_follow_main_articles_only(self):
        body = f"### 본청\n\n{self.main_article}\n\n추가 출처 {REFERENCE}\n\n"
        body += f"### 학교\n\n■ 학교 후속 보도 - 외부매체\n{EXTERNAL}"
        source = report(body, marker(VERIFIED, [evidence()]))
        self.assertEqual(self.invoke(source), (0, ""))
        self.assertEqual(self.json_at(self.raw), self.payload)
        first, second = self.json_at(self.output)["articles"]
        self.assertEqual(first["original_url"], CANDIDATE)
        self.assertTrue(first["publication_eligible"])
        self.assertEqual(first["publication_verification_basis"], evidence()["verification_basis"])
        self.assertEqual(first["publication_verified_at"], evidence()["verified_at"])
        self.assertFalse(second["publication_eligible"])
        summary = self.json_at(self.audit)["summary"]
        self.assertEqual(summary["promoted_urls"], [SELECTED])
        self.assertEqual(summary["promoted_count"], 1)
        self.assertEqual(self.briefing.read_text(encoding="utf-8"),
                         f"- 보고일: 2026-08-20\n\n{self.main_article}\n\n■ 학교 후속 보도 - 외부매체\n{EXTERNAL}\n")
        public = source.split("<!--")[0].rstrip().replace("■ 요약에만", "- 요약에만").replace("■ 제외 기사", "- 제외 기사")
        self.assertEqual(self.report.read_text(encoding="utf-8"), public + "\n")

    def test_empty_manifest_allows_external_or_zero_articles(self):
        share_date = "2026. 8. 20.(목) 인천광역시교육청 주요 언론보도 현황입니다."
        for body, with_pool in [(f"■ 별도 취재 - 매체\n{EXTERNAL}", True),
                                (f"■ 별도 취재 - 매체\n{EXTERNAL}", False),
                                (PROMOTER.NO_ARTICLES, True)]:
            with self.subTest(body=body, with_pool=with_pool):
                self.assertEqual(self.invoke(report(body, marker(VERIFIED, []), date_header=share_date),
                                             with_pool=with_pool), (0, ""))
                self.assertEqual(self.json_at(self.audit)["summary"]["promoted_count"], 0)
                briefing = self.briefing.read_text(encoding="utf-8")
                self.assertTrue(briefing.startswith("- 보고일: 2026-08-20\n"))
                self.assertNotIn("참고", briefing)
                if body == PROMOTER.NO_ARTICLES:
                    self.assertEqual(briefing, "- 보고일: 2026-08-20\n")

    def test_unmarked_selected_candidate_is_dropped_not_fatal(self):
        body = f"{self.main_article}\n\n■ 별도 취재 - 매체\n{EXTERNAL}"
        self.assertEqual(self.invoke(report(body, marker(VERIFIED, []))), (0, ""))
        summary = self.json_at(self.audit)["summary"]
        self.assertEqual(summary["unverified_dropped_urls"], [SELECTED])
        self.assertFalse(self.json_at(self.output)["articles"][0]["publication_eligible"])
        for path in [self.report, self.briefing]:
            text = path.read_text(encoding="utf-8")
            self.assertNotIn(SELECTED, text)
            self.assertIn(EXTERNAL, text)

    def test_text_between_markers_moves_above_markers(self):
        source = report(self.main_article, marker(CHECKS, {}) + "\n## 검증 메모\n\n- 메모 내용\n\n"
                        + marker(VERIFIED, [evidence()]))
        self.assertEqual(self.invoke(source), (0, ""))
        text = self.report.read_text(encoding="utf-8")
        self.assertTrue(text.rstrip().endswith("## 검증 메모\n\n- 메모 내용"))
        self.assertNotIn("DAILY_NEWS_", text)

    def test_missing_or_corrupt_manifest_is_a_hard_error(self):
        for block in ["", PROMOTER.MARKER_START, PROMOTER.MARKER_END,
                      f"{PROMOTER.MARKER_START}\nxyz\n{PROMOTER.MARKER_END}",
                      marker(VERIFIED, {}), marker(VERIFIED, []) * 2,
                      marker(VERIFIED, []) + "주석 이후의 출력\n"]:
            with self.subTest(block=block):
                self.assert_failure(report(PROMOTER.NO_ARTICLES, block))

    def test_rejects_missing_extra_duplicate_or_unsupported_evidence(self):
        for entries in [[evidence(REFERENCE)], [evidence(EXTERNAL)], [evidence()] * 2,
                        [dict(evidence(), verified=False)],
                        [dict(evidence(), publication_eligible=1)],
                        [dict(evidence(), verification_basis="관련 있음")],
                        [dict(evidence(), verification_basis=["여러 문자이지만 문자열이 아니다"])],
                        [dict(evidence(), verification_basis="본문에서 확인한 구체적 기관·학교·영향 관계")]]:
            with self.subTest(entries=entries):
                self.assert_failure(report(self.main_article, marker(VERIFIED, entries)))

    def test_non_main_or_unattached_urls_cannot_be_promoted(self):
        body = f"{self.main_article}\n\n{REFERENCE}\n\n### 제외 또는 참고\n■ 제외 - 매체\n{REFERENCE}"
        self.assert_failure(report(body, marker(VERIFIED, [evidence(), evidence(REFERENCE)])))

    def test_article_must_have_raw_immediately_following_url(self):
        for bad in [f"[기사]({SELECTED})", f"\n{SELECTED}", "https://", "http://example.com:a/b",
                    "https://example.com 설명", "//example.com/path", ""]:
            with self.subTest(bad=bad):
                self.assert_failure(report(f"■ 보고 기사 - 매체\n{bad}", marker(VERIFIED, [])))

    def test_invalid_date_stops_all_output(self):
        self.assert_failure(report(self.main_article, marker(VERIFIED, [evidence()]),
                                   date_header="- 보고일: 2026-02-30"))

    def test_partial_coverage_is_a_reportable_result(self):
        checks = {" InCheOnIn.Com ": "checked_found", "incheonilbo.com": "failed"}
        source = report(PROMOTER.NO_ARTICLES, marker(VERIFIED, []), marker(CHECKS, checks))
        self.assertEqual(self.invoke(source, with_roster=True), (0, ""))
        audit = self.json_at(self.audit)
        summary = audit["summary"]
        self.assertIs(summary["coverage_complete"], False)
        self.assertEqual(len(audit["source_checks"]), 53)
        self.assertEqual(audit["source_checks"]["incheonin.com"], "checked_found")
        self.assertEqual(len(summary["failed_domains"]), 52)
        self.assertEqual(len(summary["missing_domains"]), 51)
        self.assertNotIn("ice.go.kr", audit["source_checks"])
        public = self.report.read_text(encoding="utf-8")
        self.assertIn("수집 미완료", public)
        self.assertNotIn(PROMOTER.NO_ARTICLES, public)
        self.assertNotIn(CHECKS, public)
        for domain in summary["failed_domains"]:
            self.assertIn(domain, public)
        self.assertNotIn("incheonin.com", public)
        self.assertNotIn("incheonilbo.com", self.briefing.read_text(encoding="utf-8"))

    def test_all_checks_successful_permits_confirmed_zero(self):
        domains = PROMOTER.read_coverage_domains(ROSTER)
        statuses = {d: "checked_empty" for d in domains}
        statuses["incheonin.com"] = "checked_found"  # 후보 확인 후 제외할 수 있다.
        source = report(PROMOTER.NO_ARTICLES, marker(CHECKS, statuses), marker(VERIFIED, []))
        self.assertEqual(self.invoke(source, with_roster=True), (0, ""))
        self.assertTrue(self.json_at(self.audit)["summary"]["coverage_complete"])
        self.assertIn(PROMOTER.NO_ARTICLES, self.report.read_text(encoding="utf-8"))

    def test_absent_checks_marks_all_failed_and_keeps_verified_articles(self):
        self.assertEqual(self.invoke(report(self.main_article, marker(VERIFIED, [evidence()])),
                                     with_roster=True), (0, ""))
        summary = self.json_at(self.audit)["summary"]
        self.assertIs(summary["coverage_complete"], False)
        self.assertEqual(len(summary["failed_domains"]), 53)
        self.assertEqual(summary["promoted_count"], 1)
        self.assertIn(self.main_article, self.report.read_text(encoding="utf-8"))

    def test_report_can_still_be_incomplete_after_all_domain_queries(self):
        statuses = dict.fromkeys(PROMOTER.read_coverage_domains(ROSTER), "checked_empty")
        raw = report("수집 미완료\n기관별 추가 검색 실패", marker(VERIFIED, []), marker(CHECKS, statuses))
        self.assertEqual(self.invoke(raw, with_roster=True), (0, ""))
        summary = self.json_at(self.audit)["summary"]
        self.assertTrue(summary["coverage_complete"])
        self.assertTrue(summary["report_incomplete"])

    def test_capped_collector_check_with_matches_counts_as_found(self):
        domains = PROMOTER.read_coverage_domains(ROSTER)
        automatic = {d: "checked_empty" for d in domains}
        details = {
            d: {"engine": "google-news-rss", "query": f"site:{d} 인천교육청",
                "range_operator": "after:2026-11-24 before:2026-11-26",
                "fetched_count": 0, "matched_count": 0, "error": None} for d in domains
        }
        capped, timeout = domains[:2]
        automatic[capped] = automatic[timeout] = "failed"
        details[capped].update(fetched_count=100, matched_count=58, error="100건 상한 도달")
        details[timeout]["error"] = "timeout"
        self.payload.update(source_checks=automatic, source_check_evidence=details)
        self.raw.write_text(json.dumps(self.payload), encoding="utf-8")
        checks = {capped: "failed", timeout: "failed"}
        source = report(PROMOTER.NO_ARTICLES, marker(VERIFIED, []), marker(CHECKS, checks))
        self.assertEqual(self.invoke(source, with_roster=True), (0, ""))
        audit = self.json_at(self.audit)
        self.assertEqual(audit["source_checks"][capped], "checked_found")
        self.assertEqual(audit["source_check_evidence"][capped]["source"], "collector")
        self.assertEqual(audit["summary"]["failed_domains"], [timeout])

    def test_verified_collector_checks_and_report_complement_each_other(self):
        domains = PROMOTER.read_coverage_domains(ROSTER)
        automatic = {d: "checked_empty" for d in domains}
        details = {
            d: {"engine": "google-news-rss", "query": f"site:{d} 인천교육청",
                "range_operator": "after:2026-08-18 before:2026-08-21",
                "fetched_count": 0, "matched_count": 0, "error": None} for d in domains
        }
        found, extra, failed, mock, legacy, inconsistent = domains[:6]
        automatic[found] = "checked_found"
        details[found].update(fetched_count=2, matched_count=1)
        automatic[failed] = "failed"
        details[failed]["error"] = "timeout"
        details[mock]["engine"] = "mock"
        del details[legacy]
        details[inconsistent]["matched_count"] = 2
        self.payload.update(source_checks=automatic, source_check_evidence=details)
        self.raw.write_text(json.dumps(self.payload), encoding="utf-8")
        checks = {found: "checked_empty", extra: "checked_found", failed: "checked_empty",
                  mock: "checked_empty", legacy: "checked_found", inconsistent: "checked_empty"}
        source = report(PROMOTER.NO_ARTICLES, marker(VERIFIED, []), marker(CHECKS, checks))
        self.assertEqual(self.invoke(source, with_roster=True), (0, ""))
        audit = self.json_at(self.audit)
        self.assertTrue(audit["summary"]["coverage_complete"])
        self.assertEqual(audit["source_checks"][found], "checked_found")
        self.assertEqual(audit["source_check_evidence"][found]["source"], "collector")
        for domain in [extra, failed, mock, legacy, inconsistent]:
            self.assertEqual(audit["source_check_evidence"][domain]["source"], "report")
            self.assertEqual(audit["source_checks"][domain], checks[domain])
        self.assertEqual(audit["source_check_evidence"][failed]["collector_evidence"]["error"], "timeout")
        self.assertEqual(audit["source_check_evidence"][domains[6]]["source"], "collector")

        self.assertEqual(self.invoke(report(PROMOTER.NO_ARTICLES, marker(VERIFIED, [])),
                                     with_roster=True), (0, ""))
        audit = self.json_at(self.audit)
        self.assertFalse(audit["summary"]["coverage_complete"])
        self.assertCountEqual(audit["summary"]["failed_domains"], [failed, mock, legacy, inconsistent])
        self.assertCountEqual(audit["summary"]["missing_domains"], [mock, legacy, inconsistent])

    def test_rejects_bad_checks(self):
        for block in [marker(CHECKS, []), marker(CHECKS, {"incheonin.com": "ok"}),
                      marker(CHECKS, {"ice.go.kr": "checked_empty"}),
                      marker(CHECKS, {"incheonin.com": "checked_empty", "INCHEONIN.COM": "failed"}),
                      marker(CHECKS, {}) * 2, "<!-- DAILY_NEWS_SOURCE_CHECKS",
                      '<!-- DAILY_NEWS_SOURCE_CHECKS\n{"incheonin.com":"checked_found","incheonin.com":"failed"}\nDAILY_NEWS_SOURCE_CHECKS -->']:
            with self.subTest(block=block):
                self.assert_failure(report(PROMOTER.NO_ARTICLES, marker(VERIFIED, []), block),
                                    with_roster=True)

    def test_single_cli_does_not_reuse_different_window_or_mock_checks(self):
        domain = "incheonin.com"
        self.payload.update(
            source_checks={domain: "checked_empty"},
            source_check_evidence={domain: {
                "engine": "google-news-rss", "query": f"site:{domain} 인천교육청",
                "range_operator": "after:2026-08-18 before:2026-08-21",
                "fetched_count": 0, "matched_count": 0, "error": None,
            }},
        )
        header = ("2026. 8. 20.(목) 인천광역시교육청 주요 언론보도 현황입니다.\n"
                  "점검 창: 2026-08-19 09:00 ~ 2026-08-20 09:00 (Asia/Seoul)")
        source = report(PROMOTER.NO_ARTICLES, marker(VERIFIED, []), date_header=header)
        for flags in [{"window_end": "2026-08-19 09:00"},
                      {"window_end": "2026-08-20 05:00"}, {"dry_run": True}]:
            with self.subTest(flags=flags):
                self.raw.write_text(json.dumps(dict(self.payload, **flags)), encoding="utf-8")
                self.assertEqual(self.invoke(source, with_roster=True), (0, ""))
                audit = self.json_at(self.audit)
                self.assertEqual(audit["source_checks"][domain], "failed")
                self.assertEqual(audit["source_check_evidence"][domain]["source"], "missing")
                self.assertIn("collector_coverage_exclusion", audit["summary"])
        self.assertEqual(self.invoke(source, with_pool=False, with_roster=True), (0, ""))
        self.assertEqual(len(self.json_at(self.audit)["summary"]["missing_domains"]), 53)


if __name__ == "__main__":
    unittest.main(verbosity=2)
