# -*- coding: utf-8 -*-
import importlib.util
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "collect_news_rss", ROOT / "scripts" / "collect_news_rss.py"
)
NEWS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NEWS)


class RelevanceRulesTest(unittest.TestCase):
    def assert_status(self, title, expected):
        result = NEWS.classify_title_relevance(title)
        self.assertEqual(expected, result["status"], result)

    def test_explicit_incheon_school_and_student(self):
        self.assert_status("인천 관내 학교 학생, 전국대회 대상", "likely_relevant")
        self.assert_status("인천의 학생, 과학경진대회 우승", "likely_relevant")
        self.assert_status("인천에 있는 고등학교 학생 선행", "likely_relevant")

    def test_official_gun_gu_school_and_student(self):
        self.assert_status("남동구 중학생 3명, 시민 구조", "likely_relevant")
        self.assert_status("서해구 학교 보건교사 응급대응 교육", "likely_relevant")
        self.assert_status("검단구 학생, 발명대회 수상", "likely_relevant")

    def test_local_government_event_requires_education_office_or_school_link(self):
        standalone = NEWS.classify_title_relevance(
            "인천 미추홀구, 초등학생 체력왕 선발"
        )
        self.assertEqual("likely_irrelevant", standalone["status"])
        self.assertIn(
            "local_government_without_education_link", standalone["reasons"]
        )
        self.assert_status(
            "학생·학부모가 함께 가꾼 지역 환경… 서해구, 모범 자원봉사자 41명 표창",
            "likely_irrelevant",
        )
        self.assert_status(
            "미추홀구, 인천교육청과 학교 체력증진 협약", "likely_relevant"
        )
        self.assert_status(
            "서해구, 신현초등학교와 학생안전 체험행사 운영", "likely_relevant"
        )

    def test_verified_locality_candidates(self):
        self.assert_status("송도 고교생, 국제과학대회 우승", "likely_relevant")
        self.assert_status("청라 학생 선행 미담", "likely_relevant")

    def test_location_only_business_story_is_irrelevant(self):
        result = NEWS.classify_title_relevance(
            "쿠팡, 인천 물류센터 화재 피해 판매자 재고 전액 보상"
        )
        self.assertEqual("likely_irrelevant", result["status"])
        self.assertIn("location_without_education_subject", result["reasons"])
        no_location = NEWS.classify_title_relevance(
            "쿠팡CFS, 화재 피해 판매자 재고 전액 보상"
        )
        self.assertEqual("likely_irrelevant", no_location["status"])
        self.assertIn(
            "commercial_context_without_education_subject", no_location["reasons"]
        )

    def test_education_response_to_same_incident_is_relevant(self):
        self.assert_status(
            "도성훈 인천시교육감, 신현초 임시주거시설 운영 점검",
            "likely_relevant",
        )
        self.assert_status(
            "인천신현초 학생·주민 위한 화재 대피시설 운영",
            "likely_relevant",
        )

    def test_low_context_school_or_student_title_stays_reviewable(self):
        self.assert_status("갑룡초 학생, 전국대회 입상", "needs_review")
        self.assert_status("전국 학생 대상 공모전 개최", "needs_review")

    def test_q6_q7_query_coverage(self):
        self.assertEqual(24, len(NEWS.AREA_QUERIES))
        self.assertEqual(4, len(NEWS.LOCALITY_QUERIES))
        queries = {query for _, query in NEWS.QUERIES}
        for query in (
            "인천 학교",
            "인천 학생",
            "강화군 학교",
            "옹진군 학생",
            "제물포구 학교",
            "서해구 학생",
            "검단구 학교",
            "송도 학생",
            "청라 학교",
        ):
            self.assertIn(query, queries)

    def test_runner_keeps_approved_briefing_then_candidate_publication_order(self):
        runner = (ROOT / "scripts" / "run-daily-news-picker.ps1").read_text(encoding="utf-8")
        briefing_call = '@($organizerScript, "ingest", "--briefing", $markdownPath)'
        candidate_call = '@($organizerScript, "ingest", "--json", $ingestJsonPath)'
        self.assertIn(briefing_call, runner)
        self.assertIn("Copy-Item -Path $collectedJsonPath -Destination $persistedCollectedJsonPath", runner)
        self.assertIn(candidate_call, runner)
        self.assertLess(
            runner.index(briefing_call),
            runner.index(candidate_call),
        )

    def test_runner_surfaces_downstream_native_command_failures(self):
        runner = (ROOT / "scripts" / "run-daily-news-picker.ps1").read_text(encoding="utf-8")
        self.assertIn("$nativeExitCode = $LASTEXITCODE", runner)
        self.assertIn("if ($nativeExitCode -ne 0)", runner)
        self.assertIn('STATUS: PARTIAL [DOWNSTREAM]', runner)
        self.assertIn('Invoke-LoggedNativeCommand -Step "정적 사이트 게시"', runner)

    def test_collector_candidates_are_private_until_body_verification(self):
        self.assertFalse(NEWS.DEFAULT_PUBLICATION_ELIGIBLE)
        collector = (ROOT / "scripts" / "collect_news_rss.py").read_text(encoding="utf-8")
        self.assertIn('"publication_eligible": DEFAULT_PUBLICATION_ELIGIBLE', collector)

    def test_runner_requires_downstream_contract_for_site_output(self):
        runner = (ROOT / "scripts" / "run-daily-news-picker.ps1").read_text(encoding="utf-8")
        self.assertIn("$downstreamRequired", runner)
        self.assertIn("하류 구성요소 없음", runner)
        self.assertIn('archive\\{0}.html', runner)
        self.assertIn("exit 1", runner)

    def test_runner_promotes_only_structured_body_verification(self):
        runner = (ROOT / "scripts" / "run-daily-news-picker.ps1").read_text(encoding="utf-8")
        self.assertIn("DAILY_NEWS_VERIFIED_CANDIDATES", runner)
        self.assertIn("promote_verified_candidates.py", runner)
        self.assertIn("verified_collected_articles.json", runner)
        self.assertIn("verification_basis", runner)
        self.assertIn('STATUS: PARTIAL [VERIFICATION]', runner)

    def test_runner_defaults_to_gpt_5_6_sol(self):
        runner = (ROOT / "scripts" / "run-daily-news-picker.ps1").read_text(encoding="utf-8")
        self.assertIn('[string]$Model = "gpt-5.6-sol"', runner)
        self.assertNotIn('[string]$Model = "gpt-5.5"', runner)

    def test_runner_timeout_cleanup_cannot_block_codex_fallback(self):
        runner = (ROOT / "scripts" / "run-daily-news-picker.ps1").read_text(encoding="utf-8")
        self.assertIn("$collectorProcess.WaitForExit(5000)", runner)
        self.assertIn("수집기 임시 로그 읽기 실패(비치명)", runner)

    def test_runner_repairs_categorized_report_into_required_main_section(self):
        runner_path = ROOT / "scripts" / "run-daily-news-picker.ps1"
        runner = runner_path.read_text(encoding="utf-8")
        self.assertIn("[string]$ValidateReportPath", runner)
        pwsh = shutil.which("pwsh")
        self.assertIsNotNone(pwsh, "PowerShell 7 is required for runner validation")
        report = """# 인천교육청 언론보도 현황

- 보고일: 2026. 8. 21.(금)
- 점검 범위: 2026-08-20 05:00 ~ 2026-08-21 05:00 (Asia/Seoul)

## 주요 정책·현안

■ 정책 기사 - 테스트매체
https://example.com/policy

## 직속기관·도서관·교육문화

■ 기관 기사 - 테스트매체
https://example.com/institution

## 검증 메모

- 점검 범위 확인 완료
"""
        with tempfile.TemporaryDirectory() as temp_dir:
            report_path = Path(temp_dir) / "report.md"
            html_path = Path(temp_dir) / "report.html"
            report_path.write_text(report, encoding="utf-8")
            completed = subprocess.run(
                [
                    pwsh,
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    str(runner_path),
                    "-BasePath",
                    temp_dir,
                    "-ReportDate",
                    "2026-08-21",
                    "-ValidateReportPath",
                    str(report_path),
                    "-ValidationHtmlOutputPath",
                    str(html_path),
                ],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=30,
            )

            self.assertEqual(0, completed.returncode, completed.stderr or completed.stdout)
            repaired = report_path.read_text(encoding="utf-8")
            self.assertIn("## 주요 언론보도", repaired)
            self.assertIn("### 주요 정책·현안", repaired)
            self.assertIn("### 직속기관·도서관·교육문화", repaired)
            self.assertIn("## 검증 메모", repaired)
            self.assertTrue(html_path.is_file())
            rendered = html_path.read_text(encoding="utf-8")
            self.assertIn("<!doctype html>", rendered)
            self.assertIn("주요 언론보도", rendered)

    def test_runner_prompt_requires_exact_main_section_hierarchy(self):
        runner = (ROOT / "scripts" / "run-daily-news-picker.ps1").read_text(encoding="utf-8")
        self.assertIn('"## 주요 언론보도" 헤더를 정확히 한 번', runner)
        self.assertIn('분류 제목을 사용할 경우에는 그 아래 "###" 헤더', runner)

    def test_runner_retry_includes_failed_validation_fields(self):
        runner = (ROOT / "scripts" / "run-daily-news-picker.ps1").read_text(encoding="utf-8")
        self.assertIn("$lastValidationFailures", runner)
        self.assertIn("이전 출력 검증 실패 항목:", runner)
        self.assertIn("$retryPrompt", runner)

    def test_runner_preserves_successful_collector_json_on_report_validation_failure(self):
        runner = (ROOT / "scripts" / "run-daily-news-picker.ps1").read_text(encoding="utf-8")
        self.assertIn("수집 후보 JSON 보존:", runner)
        self.assertIn("$collectorUsed -and (Test-NonEmptyFile -Path $persistedCollectedJsonPath)", runner)
        self.assertIn("-ValidationFailures $lastValidationFailures", runner)


class OriginalUrlResolutionTest(unittest.TestCase):
    def test_resolves_articles_with_bounded_workers_and_preserves_order(self):
        articles = [
            {
                "google_url": f"https://news.google.com/articles/{index}",
                "original_url": f"https://news.google.com/articles/{index}",
                "url_status": "구글뉴스",
            }
            for index in range(3)
        ]

        def fake_resolve(url):
            return url.replace("https://news.google.com/articles/", "https://example.com/")

        with mock.patch.object(NEWS, "resolve_original_url", side_effect=fake_resolve):
            resolved = NEWS.resolve_article_urls(articles, max_workers=2)

        self.assertEqual(3, resolved)
        self.assertEqual(
            ["https://example.com/0", "https://example.com/1", "https://example.com/2"],
            [article["original_url"] for article in articles],
        )
        self.assertTrue(all(article["url_status"] == "복원" for article in articles))


if __name__ == "__main__":
    unittest.main()
