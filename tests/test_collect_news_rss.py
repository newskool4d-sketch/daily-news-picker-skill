# -*- coding: utf-8 -*-
import importlib.util
import unittest
from pathlib import Path


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

    def test_runner_does_not_publish_raw_candidate_pool(self):
        runner = (ROOT / "scripts" / "run-daily-news-picker.ps1").read_text(encoding="utf-8")
        self.assertNotIn("ingest --json $collectedJsonPath", runner)
        self.assertIn("ingest --briefing $markdownPath", runner)


if __name__ == "__main__":
    unittest.main()