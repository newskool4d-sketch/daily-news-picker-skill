# -*- coding: utf-8 -*-
"""Codex 검증 표식에 따라 수집 후보를 공개 승격하는 작은 계약 어댑터.

수집기 JSON은 원본 후보 풀로 보존하고, Codex가 기사 본문을 확인한 뒤
Markdown 끝에 남긴 구조화 표식만 읽어 별도 JSON을 만든다. 표식이 없거나
불완전하면 보고서와 공개용 산출물의 작성을 중단한다.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import date, datetime, timezone
from pathlib import Path
from tempfile import NamedTemporaryFile
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit


MARKER_START = "<!-- DAILY_NEWS_VERIFIED_CANDIDATES"
MARKER_END = "DAILY_NEWS_VERIFIED_CANDIDATES -->"
CHECKS_NAME = "DAILY_NEWS_SOURCE_CHECKS"
CHECK_STATUSES = {"checked_found", "checked_empty", "failed"}
NO_ARTICLES = "확인된 유의미 기사 없음"
TRACKING_PARAMS = {
    "utm_source",
    "utm_medium",
    "utm_campaign",
    "utm_term",
    "utm_content",
    "ref",
    "source",
    "fbclid",
    "wlog_tag3",
    "outurl",
    "influxdiv",
}
MIN_BASIS_LENGTH = 12


def canonical_url(value: str) -> str:
    """비교용 URL 정규화. 원문 URL 자체는 입력 JSON에 그대로 보존한다."""
    raw = value.strip() if isinstance(value, str) else ""
    if not re.fullmatch(r"https?://[^\s<>\"\\]+", raw, flags=re.IGNORECASE):
        return ""
    try:
        parts = urlsplit(raw)
        if not parts.hostname or parts.username is not None:
            return ""
        _ = parts.port  # 잘못된 포트 번호는 urlsplit 시점이 아닌 속성 조회 때 검출된다.
    except ValueError:
        return ""
    kept_query = [
        (key, val)
        for key, val in parse_qsl(parts.query, keep_blank_values=True)
        if key.lower() not in TRACKING_PARAMS
    ]
    path = parts.path.rstrip("/") or "/"
    query = urlencode(kept_query)
    return urlunsplit(
        (parts.scheme.lower(), parts.netloc.lower(), path, query, parts.fragment)
    )


def _read_json(path: Path) -> dict:
    payload = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(payload, dict) or not isinstance(payload.get("articles"), list):
        raise ValueError("수집 JSON 계약 위반: articles 배열이 없습니다.")
    return payload


def unique_keys(pairs: list) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"검증 표식 JSON 키 중복: {key}")
        result[key] = value
    return result


def report_footer(markdown: str) -> tuple[str, list, dict | None]:
    """두 내부 주석은 순서에 관계없이 보고서 끝에만 허용한다."""
    blocks = {}
    matches = []
    for name, expected_type in (("DAILY_NEWS_VERIFIED_CANDIDATES", list), (CHECKS_NAME, dict)):
        if name == CHECKS_NAME and name not in markdown:
            continue
        pattern = rf"^[ \t]*<!-- {name}[ \t]*\n(.*?)^{name} -->[ \t]*$"
        match = re.search(pattern, markdown, re.MULTILINE | re.DOTALL)
        # 본문 문장 속 표식 이름 언급(2026-11-25 실측)은 세지 않고, 표식 줄만 센다.
        marker_lines = re.findall(rf"^[ \t]*(?:<!-- {name}|{name} -->)[ \t]*$", markdown, re.MULTILINE)
        if not match or len(marker_lines) != 2:
            raise ValueError(f"보고서 내부 표식 누락·중복 또는 손상: {name}")
        value = json.loads(match[1], object_pairs_hook=unique_keys)
        if not isinstance(value, expected_type):
            raise ValueError(f"검증 표식 JSON 자료형 오류: {name}")
        blocks[name] = value
        matches.append(match)
    matches.sort(key=lambda m: m.start())
    # 모델이 "## 검증 메모" 등을 두 표식 사이에 쓰는 경우(2026-11-24·25 실측)는
    # 결정적으로 표식 앞 본문 끝으로 옮긴다. 표식 뒤 본문은 계속 오류로 둔다.
    between = [markdown[a.end():b.start()].strip() for a, b in zip(matches, matches[1:])]
    if markdown[matches[-1].end():].strip():
        raise ValueError("내부 표식 뒤에 보고서 본문이 있습니다.")
    public = "\n\n".join([markdown[:matches[0].start()].rstrip(), *filter(None, between)]) + "\n"
    if re.search(r"<!--\s*DAILY_NEWS_", public):
        raise ValueError("인식하지 못한 내부 주석이 보고서에 남아 있습니다.")
    return public, blocks["DAILY_NEWS_VERIFIED_CANDIDATES"], blocks.get(CHECKS_NAME)


def prepare_article_blocks(markdown: str) -> tuple[str, list[tuple[str, str]]]:
    lines = markdown.splitlines()
    headers = [i for i, line in enumerate(lines) if re.fullmatch(r"##[ \t]+주요 언론보도[ \t]*", line)]
    if len(headers) != 1:
        raise ValueError("주요 언론보도 절이 정확히 한 개 필요합니다.")
    articles = []
    in_main = False
    for i, line in enumerate(lines):
        if i == headers[0]:
            in_main = True
            continue
        if re.match(r"^#{1,2}(?:\s|$)|^#{3,6}\s+(?:제외 또는 참고|검증 메모|핵심 요약)\s*$", line):
            in_main = False
        line = line.strip()
        if not line.startswith("■"):
            continue
        if not in_main:
            # The organizer's legacy share importer scans all ■ lines if a user
            # imports the full public Markdown instead of the selected projection.
            lines[i] = "- " + line[1:].lstrip()
            continue
        if not lines[i].startswith("■") or not re.fullmatch(r"■[ \t]+\S.*[ \t]+-[ \t]+\S.*", line):
            raise ValueError(f"주요 기사 제목 형식 오류: {line}")
        url = lines[i + 1].strip() if i + 1 < len(lines) else ""
        if not canonical_url(url) or not url.startswith(("http://", "https://")):
            raise ValueError(f"주요 기사 다음 줄에 원문 URL이 필요합니다: {line}")
        lines[i] = line
        articles.append((line, url))
    return "\n".join(lines).rstrip() + "\n", articles


def drop_articles(markdown: str, articles: list[tuple[str, str]], urls: set[str]) -> tuple[str, list[tuple[str, str]]]:
    """검증 표식이 없는 주요 기사(제목 줄+URL 줄)를 공개 보고서와 organizer 입력에서 뺀다."""
    drop = {(title, url) for title, url in articles if canonical_url(url) in urls}
    lines = markdown.splitlines()
    kept, i = [], 0
    while i < len(lines):
        if i + 1 < len(lines) and (lines[i], lines[i + 1].strip()) in drop:
            i += 2
            if i < len(lines) and not lines[i].strip() and kept and not kept[-1].strip():
                i += 1
            continue
        kept.append(lines[i])
        i += 1
    return "\n".join(kept).rstrip() + "\n", [a for a in articles if a not in drop]


def report_date(markdown: str) -> str | None:
    dates = set()
    for line in markdown.splitlines():
        if re.match(r"^##(?:\s|$)", line):
            break
        match = re.fullmatch(
            r"(?:[-*]\s*)?보고일\s*:\s*(20\d{2})\s*[-./]\s*(\d{1,2})\s*[-./]\s*"
            r"(\d{1,2})(?:\s*\.?\s*\([^)]*\))?\s*", line.strip()
        ) or re.match(r"^(20\d{2})\.\s*(\d{1,2})\.\s*(\d{1,2})\.\s*\([^)]*\)(?:\s*$|.*주요 언론보도 현황입니다)", line.strip())
        if match:
            dates.add(date(*map(int, match.groups())).isoformat())
    if len(dates) > 1:
        raise ValueError("보고서의 보고일이 서로 다릅니다.")
    return next(iter(dates), None)


def organizer_briefing(day: str | None, articles: list[tuple[str, str]]) -> str:
    if not day:
        raise ValueError("organizer 입력에 필요한 보고일이 없습니다.")
    return "\n\n".join([f"- 보고일: {day}", *(f"{title}\n{url}" for title, url in articles)]) + "\n"


def read_coverage_domains(roster: Path) -> list[str]:
    text = roster.read_text(encoding="utf-8-sig")
    section = re.search(r"^## Required Source-Seed Domains\s*$(.*?)(?=^## |\Z)", text, re.M | re.S)
    if not section:
        raise ValueError("매체 목록에서 Required Source-Seed Domains 절을 찾지 못했습니다.")
    domains = []
    for line in section[1].splitlines():
        if not line.startswith("|") or line.startswith(("| Group |", "|---")):
            continue
        seed = re.search(r"`site:([a-z0-9.-]+)\s", line, re.I)
        if not seed or seed[1].lower() in domains:
            raise ValueError(f"매체 목록의 중복 또는 손상된 도메인 행: {line}")
        domains.append(seed[1].lower())
    if not domains:
        raise ValueError("매체 목록이 비어 있습니다.")
    return domains


def _collector_check(domain: str, status: object, evidence: object) -> str | None:
    if not isinstance(evidence, dict) or evidence.get("engine") != "google-news-rss":
        return None
    if not str(evidence.get("query", "")).startswith(f"site:{domain} "):
        return None
    if not re.fullmatch(r"after:\d{4}-\d{2}-\d{2} before:\d{4}-\d{2}-\d{2}",
                        str(evidence.get("range_operator", ""))):
        return None
    fetched, matched = evidence.get("fetched_count"), evidence.get("matched_count")
    # 100건 상한 도달은 검색이 완료돼 해당 매체 기사가 확인된 상태다(창 초반 누락은 네이버 보강 몫).
    # 2026-11-24·26 실측: 상한만으로 failed 처리돼 공개가 막혔다.
    if (evidence.get("error") == "100건 상한 도달" and type(fetched) is int
            and type(matched) is int and 0 < matched <= fetched):
        return "checked_found"
    if status == "failed" or evidence.get("error"):
        return "failed"
    if type(fetched) is not int or type(matched) is not int or not 0 <= matched <= fetched:
        return None
    expected = "checked_found" if matched else "checked_empty"
    return expected if expected == status and "error" in evidence else None


def collector_exclusion(payload: dict, day: str | None, markdown: str) -> str | None:
    if not payload.get("source_checks"):
        return None
    if payload.get("dry_run") or payload.get("engine") not in (None, "google-news-rss"):
        return "모의 수집 또는 다른 수집 엔진"
    cutoff = payload.get("window_end")
    if day and cutoff and str(cutoff).strip()[:10] != day:
        return "보고일과 수집 종료일 불일치"
    stamp = r"20\d{2}-\d{2}-\d{2} \d{2}:\d{2}"
    window = re.search(rf"점검 창[^\n]*?({stamp})\s*[~～]\s*({stamp})", markdown)
    if window and any(payload.get(k) and payload[k] != value for k, value in
                      zip(("window_start", "window_end"), window.groups())):
        return "보고서와 수집 점검 창 불일치"
    return None


def coverage_summary(roster: Path, entries: dict, payload: dict, exclusion: str | None) -> tuple[dict, dict, dict]:
    domains = read_coverage_domains(roster)
    statuses = {}
    for key, status in entries.items():
        domain = key.strip().lower()
        if domain not in domains or domain in statuses:
            raise ValueError(f"매체 점검 표식의 미등록 또는 중복 도메인: {key}")
        if not isinstance(status, str) or status not in CHECK_STATUSES:
            raise ValueError(f"매체 점검 상태 오류: {key}")
        statuses[domain] = status
    collector = payload.get("source_checks")
    evidence = payload.get("source_check_evidence")
    normalized = {}
    origins = {}
    for domain in domains:
        automatic = collector.get(domain) if isinstance(collector, dict) else None
        detail = evidence.get(domain) if isinstance(evidence, dict) else None
        actual = _collector_check(domain, automatic, detail) if not exclusion else None
        reported = statuses.get(domain)
        if actual == "checked_found" or (actual == "checked_empty" and reported != "checked_found"):
            normalized[domain], source = actual, "collector"
        elif reported is not None:
            normalized[domain], source = reported, "report"
        elif actual == "failed":
            normalized[domain], source = "failed", "collector"
        else:
            normalized[domain], source = "failed", "missing"
        origins[domain] = {"source": source}
        if automatic is not None:
            origins[domain]["collector_status"] = automatic
        if isinstance(detail, dict):
            origins[domain]["collector_evidence"] = detail
        if reported is not None:
            origins[domain]["report_status"] = reported
    missing = [domain for domain, origin in origins.items() if origin["source"] == "missing"]
    failed = [domain for domain, status in normalized.items() if status == "failed"]
    summary = {"coverage_complete": not failed, "failed_domains": failed, "missing_domains": missing}
    if exclusion:
        summary["collector_coverage_exclusion"] = exclusion
    return normalized, origins, summary


def _verification_entry(entry: object) -> tuple[str, str] | None:
    if not isinstance(entry, dict):
        return None
    if entry.get("verified") is not True or entry.get("publication_eligible") is not True:
        return None
    basis = entry.get("verification_basis")
    if not isinstance(basis, str) or len(basis.strip()) < MIN_BASIS_LENGTH:
        return None
    url = canonical_url(entry.get("original_url") or entry.get("url"))
    if not url:
        return None
    return url, basis.strip()


def promote(payload: dict, manifest: list, selected_urls: set[str]) -> tuple[dict, dict]:
    """선정된 수집 후보와 검증 표식을 양방향 대조한 뒤에만 공개 승인한다."""
    now = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    candidates = {}
    for article in payload["articles"]:
        if not isinstance(article, dict):
            raise ValueError("수집 기사 항목은 JSON 객체여야 합니다.")
        url = canonical_url(
            article.get("original_url") or article.get("google_url") or article.get("url")
        )
        if url:
            candidates.setdefault(url, []).append(article)

    expected = candidates.keys() & selected_urls
    verified = {}
    for manifest_index, entry in enumerate(manifest):
        parsed = _verification_entry(entry)
        if parsed is None:
            raise ValueError(f"검증 표식 {manifest_index + 1}번의 URL·확인 상태·본문 근거를 점검하세요.")
        url, basis = parsed
        if url not in expected:
            raise ValueError(f"검증 표식에 주요 언론보도로 선정되지 않은 후보 또는 수집 풀 밖의 URL이 있습니다: {url}")
        if url in verified:
            raise ValueError(f"검증 표식 URL 중복: {url}")
        if (basis == "본문에서 확인한 구체적 기관·학교·영향 관계"
                or any(basis == str(a.get("title") or "").strip() for a in candidates[url])):
            raise ValueError(f"검증 표식에 제목이나 예시 문구 대신 본문 확인 근거가 필요합니다: {url}")
        verified[url] = (basis, str(entry.get("verified_at") or now))
    # 표식이 빠진 선정 후보는 실행을 멈추지 않고 비공개로 두며, 호출부가 보고서에서 뺀다.
    missing = expected.difference(verified)

    for article in payload["articles"]:
        article["publication_eligible"] = False
        article["body_status"] = "본문 미검증"
        article["publication_verification_basis"] = ""
        article["publication_verified_at"] = ""
    for url, (basis, verified_at) in verified.items():
        for article in candidates[url]:
            article["publication_eligible"] = True
            article["body_status"] = "본문 검증 완료"
            article["publication_verification_basis"] = basis
            article["publication_verified_at"] = verified_at

    summary = {
        "marker_present": True,
        "candidate_count": len(payload["articles"]),
        "promoted_count": len(verified),
        "promoted_urls": sorted(verified),
        "unverified_dropped_urls": sorted(missing),
        "ignored": [],
        "generated_at": now,
    }
    return payload, summary


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with NamedTemporaryFile(dir=path.parent, delete=False) as tmp:
        temp_path = Path(tmp.name)
    try:
        temp_path.write_text(content, encoding="utf-8")
        temp_path.replace(path)
    finally:
        temp_path.unlink(missing_ok=True)


def write_json(path: Path, payload: dict) -> None:
    write_text(path, json.dumps(payload, ensure_ascii=False, indent=2) + "\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--manifest-output", required=True, type=Path)
    parser.add_argument("--briefing-output", type=Path)
    parser.add_argument("--coverage-roster", type=Path)
    args = parser.parse_args(argv)

    try:
        paths = [p.resolve() for p in vars(args).values() if p is not None]
        if len(set(paths)) != len(paths):
            raise ValueError("원본·보고서·산출물 경로가 겹칩니다.")
        payload = _read_json(args.input) if args.input else {"articles": []}
        raw = args.report.read_text(encoding="utf-8-sig")
        markdown, manifest, checks = report_footer(raw)
        markdown, articles = prepare_article_blocks(markdown)
        day = report_date(markdown)
        promoted, summary = promote(payload, manifest, {canonical_url(url) for _, url in articles})
        if summary["unverified_dropped_urls"]:
            markdown, articles = drop_articles(markdown, articles, set(summary["unverified_dropped_urls"]))
        audit = {"manifest": manifest, "summary": summary}
        summary["coverage_complete"] = None
        summary["report_incomplete"] = bool(re.search(r"^(?:[-*] )?수집 미완료[ \t]*(?:$|[:(])", markdown, re.MULTILINE))
        if args.coverage_roster:
            exclusion = collector_exclusion(payload, day, markdown)
            normalized, origins, coverage = coverage_summary(args.coverage_roster, checks or {}, payload, exclusion)
            summary.update(coverage)
            audit["source_checks"] = normalized
            audit["source_check_evidence"] = origins
            if not summary["coverage_complete"]:
                if not articles:
                    markdown = markdown.replace(NO_ARTICLES, "수집 미완료")
                failed = ", ".join(summary["failed_domains"])
                markdown += f"\n매체 점검 미완료(실패 또는 미확인): {failed}\n"
        elif checks is not None:
            if any(not isinstance(status, str) or status not in CHECK_STATUSES for status in checks.values()):
                raise ValueError("매체 점검 표식에 알 수 없는 상태가 있습니다.")
            audit["source_checks"] = checks
        briefing = organizer_briefing(day, articles) if args.briefing_output else None
        write_json(args.output, promoted)
        write_json(args.manifest_output, audit)
        if args.briefing_output:
            write_text(args.briefing_output, briefing)
        write_text(args.report, markdown)
        print(json.dumps(summary, ensure_ascii=False, separators=(",", ":")))
        return 0
    except (OSError, ValueError) as exc:
        print(f"promotion failed: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
