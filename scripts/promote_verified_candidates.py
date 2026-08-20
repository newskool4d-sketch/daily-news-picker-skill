# -*- coding: utf-8 -*-
"""Codex 검증 표식에 따라 수집 후보를 공개 승격하는 작은 계약 어댑터.

수집기 JSON은 원본 후보 풀로 보존하고, Codex가 기사 본문을 확인한 뒤
Markdown 끝에 남긴 구조화 표식만 읽어 별도 JSON을 만든다. 표식이 없거나
불완전하면 모든 후보를 비공개로 유지한다(fail closed).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit


MARKER_START = "<!-- DAILY_NEWS_VERIFIED_CANDIDATES"
MARKER_END = "DAILY_NEWS_VERIFIED_CANDIDATES -->"
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
    raw = (value or "").strip().strip("<>").rstrip(".,;)")
    if not raw:
        return ""
    parts = urlsplit(raw)
    if not parts.scheme or not parts.netloc:
        return raw.lower().rstrip("/")
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
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict) or not isinstance(payload.get("articles"), list):
        raise ValueError("수집 JSON 계약 위반: articles 배열이 없습니다.")
    return payload


def extract_manifest(markdown: str) -> tuple[list, bool]:
    """Markdown의 검증 표식을 읽는다. 표식이 없으면 빈 목록·False를 반환한다."""
    if (markdown or "").count(MARKER_START) > 1 or (markdown or "").count(MARKER_END) > 1:
        raise ValueError("검증 표식이 여러 개입니다.")
    pattern = re.escape(MARKER_START) + r"\s*(.*?)\s*" + re.escape(MARKER_END)
    match = re.search(pattern, markdown or "", flags=re.DOTALL)
    if not match:
        return [], False
    try:
        manifest = json.loads(match.group(1).strip())
    except json.JSONDecodeError as exc:
        raise ValueError(f"검증 표식 JSON 파싱 실패: {exc.msg}") from exc
    if not isinstance(manifest, list):
        raise ValueError("검증 표식은 JSON 배열이어야 합니다.")
    return manifest, True


def strip_manifest(markdown: str) -> str:
    """공개 Markdown/HTML에 검증용 내부 표식이 남지 않게 제거한다."""
    pattern = re.escape(MARKER_START) + r"\s*.*?\s*" + re.escape(MARKER_END)
    cleaned = re.sub(pattern, "", markdown or "", count=1, flags=re.DOTALL)
    cleaned = re.sub(r"\n{3,}", "\n\n", cleaned).strip()
    return cleaned + "\n" if cleaned else ""


def _verification_entry(entry: object) -> tuple[str, str] | None:
    if not isinstance(entry, dict):
        return None
    if entry.get("verified") is not True or entry.get("publication_eligible") is not True:
        return None
    basis = str(entry.get("verification_basis", "")).strip()
    if len(basis) < MIN_BASIS_LENGTH:
        return None
    url = canonical_url(str(entry.get("original_url") or entry.get("url") or ""))
    if not url:
        return None
    return url, basis


def promote(payload: dict, manifest: list, marker_present: bool) -> tuple[dict, dict]:
    """검증 manifest를 원본 후보 풀에 적용하고 결과·감사 요약을 반환한다."""
    now = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    candidates = {}
    for index, article in enumerate(payload["articles"]):
        if not isinstance(article, dict):
            continue
        url = canonical_url(
            str(article.get("original_url") or article.get("google_url") or article.get("url") or "")
        )
        if url:
            candidates.setdefault(url, []).append((index, article))

    promoted_urls = set()
    ignored = []
    for manifest_index, entry in enumerate(manifest):
        parsed = _verification_entry(entry)
        if parsed is None:
            ignored.append({"manifest_index": manifest_index, "reason": "invalid_or_unverified"})
            continue
        url, basis = parsed
        matches = candidates.get(url, [])
        if not matches:
            ignored.append({"manifest_index": manifest_index, "reason": "url_not_in_candidate_pool", "url": url})
            continue
        if url in promoted_urls:
            ignored.append({"manifest_index": manifest_index, "reason": "duplicate_url", "url": url})
            continue
        for _, article in matches:
            article["publication_eligible"] = True
            article["body_status"] = "본문 검증 완료"
            article["publication_verification_basis"] = basis
            article["publication_verified_at"] = str(entry.get("verified_at") or now)
        promoted_urls.add(url)

    # 원본 수집기가 실수로 true를 내보내더라도 이 단계의 명시 manifest 없이는 승격하지 않는다.
    for article in payload["articles"]:
        if not isinstance(article, dict):
            continue
        article_url = canonical_url(
            str(article.get("original_url") or article.get("google_url") or article.get("url") or "")
        )
        if article_url not in promoted_urls:
            article["publication_eligible"] = False
            article["body_status"] = article.get("body_status") or "본문 미검증"
            article["publication_verification_basis"] = ""
            article["publication_verified_at"] = ""

    summary = {
        "marker_present": marker_present,
        "candidate_count": len(payload["articles"]),
        "promoted_count": len(promoted_urls),
        "promoted_urls": sorted(promoted_urls),
        "ignored": ignored,
        "generated_at": now,
    }
    return payload, summary


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--manifest-output", required=True, type=Path)
    args = parser.parse_args(argv)

    try:
        payload = _read_json(args.input) if args.input else {"articles": []}
        markdown = args.report.read_text(encoding="utf-8")
        manifest, marker_present = extract_manifest(markdown)
        promoted, summary = promote(payload, manifest, marker_present)
        write_json(args.output, promoted)
        write_json(args.manifest_output, {"manifest": manifest, "summary": summary})
        if marker_present:
            args.report.write_text(strip_manifest(markdown), encoding="utf-8")
        print(json.dumps(summary, ensure_ascii=False, separators=(",", ":")))
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"promotion failed: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
