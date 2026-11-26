import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from datetime import date, datetime
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("collect_news_rss", ROOT / "scripts" / "collect_news_rss.py")
NEWS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NEWS)


class CollectionWindowTests(unittest.TestCase):
    def test_cli_default_skips_weekend_and_holiday_across_years(self):
        holidays = {2026: set(), 2027: {date(2027, 1, 1)}}
        with (
            tempfile.TemporaryDirectory() as tmp,
            mock.patch.object(NEWS, "korean_public_holidays", side_effect=holidays.__getitem__) as calendar,
            mock.patch.object(NEWS, "collect", return_value=([], [])) as collect,
        ):
            args = ["collect_news_rss.py", "--date", "2027-01-04", "--out-dir", tmp]
            with mock.patch.object(sys, "argv", args), contextlib.redirect_stdout(io.StringIO()):
                NEWS.main()
            collect.assert_called_once_with(
                datetime(2026, 12, 31, 9, tzinfo=NEWS.KST),
                datetime(2027, 1, 4, 9, tzinfo=NEWS.KST),
                resolve=True,
            )
            self.assertEqual([mock.call(2027), mock.call(2026)], calendar.call_args_list)
            saved = json.loads((Path(tmp) / "collected_articles.json").read_text(encoding="utf-8"))
            self.assertEqual("2026-12-31 09:00", saved["window_start"])
            self.assertEqual("2027-01-04 09:00", saved["window_end"])

    def test_explicit_boundaries_preserve_time_and_skip_calendar(self):
        with mock.patch.object(NEWS, "korean_public_holidays") as calendar:
            start, end = NEWS.collection_window(None, "2026-07-16 05:37", "2026-07-17 11:04")
        calendar.assert_not_called()
        self.assertEqual(datetime(2026, 7, 16, 5, 37, tzinfo=NEWS.KST), start)
        self.assertEqual(datetime(2026, 7, 17, 11, 4, tzinfo=NEWS.KST), end)
        self.assertTrue(NEWS.in_window(start, start, end))
        self.assertFalse(NEWS.in_window(end, start, end))

    def test_cli_invalid_boundaries_fail_before_collection(self):
        first = "2026-07-16 05:00"
        last = "2026-07-17 05:00"
        for args in (
            ["--start", first], ["--end", last],
            ["--start", last, "--end", first], ["--start", first, "--end", first],
        ):
            with (
                self.subTest(args=args),
                mock.patch.object(sys, "argv", ["collector", *args]),
                mock.patch.object(NEWS, "collect") as collect,
                mock.patch.object(NEWS, "korean_public_holidays") as calendar,
            ):
                with self.assertRaises(SystemExit) as failure, contextlib.redirect_stderr(io.StringIO()):
                    NEWS.main()
                self.assertEqual(2, failure.exception.code)
                collect.assert_not_called()
                calendar.assert_not_called()

    def test_shared_calendar_refresh_and_offline_fallback(self):
        expected = {date(2026, 1, 1)}
        records = [{"date": "2026-01-01", "countryCode": "KR"}]
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(NEWS, "HOLIDAY_CACHE_DIR", Path(tmp)):
            cache = Path(tmp) / "holidays-kr-2026.json"
            with mock.patch.object(NEWS.urllib.request, "urlopen", return_value=io.BytesIO(json.dumps(records).encode())):
                self.assertEqual(expected, NEWS.korean_public_holidays(2026))
            self.assertEqual(records, json.loads(cache.read_text(encoding="utf-8")))
            with mock.patch.object(NEWS.urllib.request, "urlopen", side_effect=OSError("offline")) as fetch:
                self.assertEqual(expected, NEWS.korean_public_holidays(2026))
                fetch.assert_not_called()
                os.utime(cache, (0, 0))
                with contextlib.redirect_stderr(io.StringIO()) as warning:
                    self.assertEqual(expected, NEWS.korean_public_holidays(2026))
                self.assertIn("만료된 캐시", warning.getvalue())
                cache.write_text("{", encoding="utf-8")
                with contextlib.redirect_stderr(io.StringIO()) as warning:
                    self.assertEqual(set(), NEWS.korean_public_holidays(2026))
                self.assertIn("주말만", warning.getvalue())


class DuplicateCandidateTests(unittest.TestCase):
    def test_unresolved_and_distinct_sources_survive_and_same_urls_merge(self):
        title = "인천 학교 행사"
        published = "Thu, 16 Jul 2026 03:00:00 GMT"
        rss = [
            {
                "title": title,
                "link": f"https://news.google.com/articles/{index}",
                "pubdate": published,
                "source_name": "매체",
                "source_url": "https://press.example",
            }
            for index in range(3)
        ]
        naver = [
            {"title": title, "originallink": url, "pubDate": published}
            for url in ("https://press.example/1", "https://press.example/2",
                        "https://other.example/1", "https://press.example/2?utm_source=news")
        ]
        original = {
            rss[0]["link"]: None,
            rss[1]["link"]: "https://press.example/1?utm_source=rss",
            rss[2]["link"]: "https://press.example/1",
        }
        queries = [("Q1", "하나"), ("Q2", "둘"), ("Q3", "셋")]
        with (
            mock.patch.object(NEWS, "QUERIES", queries),
            mock.patch.object(NEWS, "fetch_rss", side_effect=[rss[:2], rss[2:], OSError("offline")]),
            mock.patch.object(NEWS, "resolve_original_url", side_effect=original.__getitem__),
            mock.patch.object(NEWS, "naver_keys", return_value=("test", "test")),
            mock.patch.object(NEWS, "fetch_naver_window", return_value=naver),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            candidates, failures = NEWS.collect(
                datetime(2026, 7, 16, 9, tzinfo=NEWS.KST), datetime(2026, 7, 17, 9, tzinfo=NEWS.KST)
            )
        self.assertEqual(1, len(failures))
        self.assertEqual(
            [None, "https://press.example/1", "https://press.example/2", "https://other.example/1"],
            [article["original_url"] for article in candidates],
        )
        self.assertEqual(["Q1:하나", "Q2:둘", "Q3:셋"], candidates[1]["queries"])
        self.assertTrue(all(article["title"] == title and not article["publication_eligible"] for article in candidates))


class SourceDomainCollectionTests(unittest.TestCase):
    def test_roster_cli_queries_each_domain_once_and_records_only_observed_results(self):
        def item(domain, identifier, published="Thu, 16 Jul 2026 03:00:00 GMT"):
            return {
                "source_url": "https://" + domain, "source_name": "매체", "title": "기사",
                "link": f"https://news.google.com/articles/{identifier}", "pubdate": published,
            }

        shared = item("www.incheonin.com", "shared")
        responses = {
            "기관명": [shared],
            "site:incheonin.com 인천교육청": [shared, item("incheonin.com", "alias"), item("incheonin.com", "new")],
            "site:incheontoday.com 인천교육청": [item("incheontoday.com", "old", "Wed, 15 Jul 2026 03:00:00 GMT")],
            "site:incheonilbo.com 인천교육청": OSError("offline"),
            "site:kyeongin.com 인천교육청": [item("kyeongin.com", "capped")] * 100,
            "site:kyeonggi.com 인천교육청": [item("notkyeonggi.com", "wrong-domain")],
            "site:kihoilbo.co.kr 인천교육청": [item("kihoilbo.co.kr", "unknown", "bad-date")],
        }

        def search(query, range_operator):
            response = responses.get(query, [])
            if isinstance(response, Exception):
                raise response
            return response

        def resolve(link):
            identifier = link.rsplit("/", 1)[1]
            return "https://press.example/" + ("shared" if identifier == "alias" else identifier)

        with (
            tempfile.TemporaryDirectory() as tmp,
            mock.patch.object(NEWS, "QUERIES", [("Q1", "기관명")]),
            mock.patch.object(NEWS, "fetch_rss", side_effect=search) as rss,
            mock.patch.object(NEWS, "resolve_original_url", side_effect=resolve),
            mock.patch.object(NEWS, "fetch_naver_window") as naver,
            contextlib.redirect_stdout(io.StringIO()),
        ):
            args = ["collector", "--coverage-roster", str(ROOT / "references" / "media-sources.md"),
                    "--start", "2026-07-16 09:00", "--end", "2026-07-17 09:00", "--out-dir", tmp]
            with mock.patch.object(sys, "argv", args):
                NEWS.main()
            result = json.loads((Path(tmp) / "collected_articles.json").read_text(encoding="utf-8"))
        naver.assert_not_called()
        checks = result["source_checks"]
        self.assertEqual(53, len(checks))
        self.assertNotIn("ice.go.kr", checks)
        queries = [call.args[0] for call in rss.call_args_list]
        self.assertCountEqual(["기관명", *(f"site:{domain} 인천교육청" for domain in checks)], queries)
        self.assertEqual(1, len({call.args[1] for call in rss.call_args_list}))
        self.assertEqual("checked_found", checks["incheonin.com"])
        self.assertEqual("checked_empty", checks["incheontoday.com"])
        self.assertEqual("checked_empty", checks["news.kbs.co.kr"])
        for domain in ("incheonilbo.com", "kyeongin.com", "kyeonggi.com", "kihoilbo.co.kr"):
            self.assertEqual("failed", checks[domain])
            self.assertTrue(result["source_check_evidence"][domain]["error"])
        found = result["source_check_evidence"]["incheonin.com"]
        self.assertEqual("google-news-rss", found["engine"])
        self.assertEqual("site:incheonin.com 인천교육청", found["query"])
        self.assertEqual(rss.call_args_list[0].args[1], found["range_operator"])
        self.assertEqual(3, found["fetched_count"])
        self.assertEqual(3, found["matched_count"])
        self.assertIsNone(found["error"])
        candidates = {row["original_url"]: row for row in result["articles"]}
        self.assertEqual(3, result["article_count"])
        self.assertEqual({"https://press.example/shared", "https://press.example/new",
                          "https://press.example/capped"}, set(candidates))
        self.assertEqual(["Q1:기관명", "SOURCE:site:incheonin.com 인천교육청"],
                         candidates["https://press.example/shared"]["queries"])

    def test_non_rss_document_is_a_failed_site_search(self):
        with mock.patch.object(NEWS.urllib.request, "urlopen", return_value=io.BytesIO(b"<html/>")):
            with self.assertRaisesRegex(ValueError, "RSS"):
                NEWS.fetch_rss("site:press.example 인천교육청", "after:2026-07-15 before:2026-07-17")


if __name__ == "__main__":
    unittest.main()
