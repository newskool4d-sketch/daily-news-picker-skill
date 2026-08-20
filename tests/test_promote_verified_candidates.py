# -*- coding: utf-8 -*-
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "promote_verified_candidates",
    ROOT / "scripts" / "promote_verified_candidates.py",
)
PROMOTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROMOTER)


class PromoteVerifiedCandidatesTest(unittest.TestCase):
    def setUp(self):
        self.payload = {
            "window_end": "2026-08-20 05:00",
            "articles": [
                {
                    "title": "인천교육청, 본문 확인 후보",
                    "original_url": "https://example.com/article?utm_source=rss&id=1",
                    "relevance_hint": "likely_relevant",
                    "publication_eligible": False,
                },
                {
                    "title": "인천교육청, 미검증 후보",
                    "original_url": "https://example.com/unverified",
                    "relevance_hint": "needs_review",
                    "publication_eligible": False,
                },
            ],
        }

    def test_body_verified_manifest_promotes_only_matching_candidate(self):
        manifest = [{
            "original_url": "https://EXAMPLE.com/article?id=1",
            "verified": True,
            "publication_eligible": True,
            "verification_basis": "본문에 인천교육청과 학교 협력 사업이 명시됨",
            "verified_at": "2026-08-20T00:00:00+00:00",
        }]
        promoted, summary = PROMOTER.promote(self.payload, manifest, True)

        self.assertEqual(summary["promoted_count"], 1)
        self.assertTrue(promoted["articles"][0]["publication_eligible"])
        self.assertEqual(promoted["articles"][0]["body_status"], "본문 검증 완료")
        self.assertIn("인천교육청과 학교", promoted["articles"][0]["publication_verification_basis"])
        self.assertEqual(
            promoted["articles"][0]["publication_verified_at"],
            "2026-08-20T00:00:00+00:00",
        )
        self.assertFalse(promoted["articles"][1]["publication_eligible"])

    def test_missing_marker_fails_closed(self):
        promoted, summary = PROMOTER.promote(self.payload, [], False)

        self.assertFalse(summary["marker_present"])
        self.assertEqual(summary["promoted_count"], 0)
        self.assertTrue(all(not a["publication_eligible"] for a in promoted["articles"]))
        self.assertTrue(all(a["body_status"] == "본문 미검증" for a in promoted["articles"]))

    def test_invalid_manifest_entries_are_ignored(self):
        manifest = [
            {"original_url": "https://example.com/unverified", "verified": True,
             "publication_eligible": True, "verification_basis": "짧음"},
            {"original_url": "https://example.com/missing", "verified": True,
             "publication_eligible": True, "verification_basis": "본문에서 직접 확인한 근거가 있음"},
            {"original_url": "https://example.com/article?id=1", "verified": False,
             "publication_eligible": True, "verification_basis": "본문에서 직접 확인한 근거가 있음"},
        ]
        promoted, summary = PROMOTER.promote(self.payload, manifest, True)

        self.assertEqual(summary["promoted_count"], 0)
        self.assertEqual(len(summary["ignored"]), 3)
        self.assertTrue(all(not a["publication_eligible"] for a in promoted["articles"]))

    def test_cli_writes_derived_json_and_strips_internal_marker(self):
        marker = (
            f"{PROMOTER.MARKER_START}\n"
            '[{"original_url":"https://example.com/unverified",'
            '"verified":true,"publication_eligible":true,'
            '"verification_basis":"본문에 학교 운영 영향이 명시됨"}]\n'
            f"{PROMOTER.MARKER_END}"
        )
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            input_path = root / "collected.json"
            report_path = root / "report.md"
            output_path = root / "verified.json"
            manifest_path = root / "verification-manifest.json"
            input_path.write_text(json.dumps(self.payload, ensure_ascii=False), encoding="utf-8")
            report_path.write_text(f"# 보고서\n\n본문\n\n{marker}\n", encoding="utf-8")

            code = PROMOTER.main([
                "--input", str(input_path),
                "--report", str(report_path),
                "--output", str(output_path),
                "--manifest-output", str(manifest_path),
            ])

            self.assertEqual(code, 0)
            self.assertTrue(output_path.exists())
            self.assertTrue(manifest_path.exists())
            self.assertNotIn(PROMOTER.MARKER_START, report_path.read_text(encoding="utf-8"))
            written = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertTrue(written["articles"][1]["publication_eligible"])

    def test_malformed_marker_returns_failure_without_promoting(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            input_path = root / "collected.json"
            report_path = root / "report.md"
            output_path = root / "verified.json"
            manifest_path = root / "verification-manifest.json"
            input_path.write_text(json.dumps(self.payload, ensure_ascii=False), encoding="utf-8")
            report_path.write_text(
                f"{PROMOTER.MARKER_START}\nnot-json\n{PROMOTER.MARKER_END}\n",
                encoding="utf-8",
            )

            code = PROMOTER.main([
                "--input", str(input_path),
                "--report", str(report_path),
                "--output", str(output_path),
                "--manifest-output", str(manifest_path),
            ])

            self.assertEqual(code, 2)
            self.assertFalse(output_path.exists())
            self.assertIn("not-json", report_path.read_text(encoding="utf-8"))

    def test_cli_without_candidate_pool_still_strips_marker(self):
        marker = (
            f"{PROMOTER.MARKER_START}\n[]\n{PROMOTER.MARKER_END}"
        )
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            report_path = root / "report.md"
            output_path = root / "verified.json"
            manifest_path = root / "verification-manifest.json"
            report_path.write_text(f"# 보고서\n\n{marker}\n", encoding="utf-8")

            code = PROMOTER.main([
                "--report", str(report_path),
                "--output", str(output_path),
                "--manifest-output", str(manifest_path),
            ])

            self.assertEqual(code, 0)
            self.assertNotIn(PROMOTER.MARKER_START, report_path.read_text(encoding="utf-8"))
            self.assertEqual(
                json.loads(output_path.read_text(encoding="utf-8"))["articles"], []
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
