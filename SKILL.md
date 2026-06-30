---
name: daily-news-picker
description: Collect, rank, and summarize daily news about Incheon education offices, district offices, and affiliated institutions.
metadata:
  short-description: 인천교육청 언론보도 선별, 중복 제거, 일일 브리핑
---

# Daily News Picker

## Overview

Collect recent news about 인천광역시교육청 and its affiliated organizations, remove only invalid or true duplicate items, and produce a full daily press-coverage status list ordered by operational importance.

For institution scope and example entities, read [references/institution-scope.md](./references/institution-scope.md).
For monitored outlet domains, read [references/media-sources.md](./references/media-sources.md).

This skill should be treated as a default daily monitoring skill, not only an explicit `$daily-news-picker` command skill.

Default operating rule:

- 기준 시각: 평일 오전 7시
- 기준 범위: 직전 점검 이후 누적된 언론보도 현황
- 제외일: 토요일, 일요일, 공휴일
- 별도 지시가 없으면 위 기준을 적용
- 결과 저장: `md`와 `html` 두 형식으로 함께 저장
- 날짜별 저장 폴더: `인천교육청 언론보도 현황(YYYYMMDD)` 형식 사용
- 기본 산출물: 실제 공유 문안에 맞춘 당일 주요 언론보도 전체 링크 목록
- 기사 수 제한 금지: 상위 5건만 남기지 말고, 기간 안의 관련 원 기사 링크를 모두 보존
- 기본 기대 동작: 별도 명령이 없어도 일일 뉴스 점검 작업에 우선 적용

## Quick Start

Use this skill when the user asks for things like:

- "뉴스/ 인천교육청"
- "뉴스/ 학생교육원"
- "오늘 인천광역시교육청 뉴스 골라줘"
- "최근 교육지원청 기사만 추려줘"
- "학생교육원 관련 언론보도 브리핑 만들어줘"
- "직속기관 이슈를 아침 보고용으로 정리해줘"

Always browse because news freshness matters.

## Workflow

Use the deep-research pattern in a faster news-monitoring form:

1. Confirm the time window from the user request.
   If the user gives no separate 기간 조건, use the current business day 7:00 AM check window.
   If the user says `오늘`, `어제`, `이번 주`, or `최근`, restate it with exact dates.
   If the request date is a weekend or public holiday, say that the default briefing is skipped unless the user explicitly requests a manual run.
2. Search recent coverage with external press article links first.
   Start with institution-name queries in news search, then run the monitored-outlet source-seed checks from [references/media-sources.md](./references/media-sources.md).
   Always run the Q5 directly-affiliated-institution and library loop from [references/search-recipes.md](./references/search-recipes.md) every business day, not only on low-count days: 직속기관·도서관 are frequently reported under their own names only and are missed by 본청/지원청 keywords.
   Also run the `인천교육감` query (Q4) for 교육감 동정·인사·외부 직위 coverage that 본청 keywords can miss.
   Use official institution pages only to verify facts, institution names, dates, and background, not as the default selected article link.
   If an `ice.go.kr` page is an official press release copied by many outlets, find and prefer the actual media article URL unless no accessible external article exists.
   Use the verified query set and retry/anti-fabrication rules in [references/search-recipes.md](./references/search-recipes.md);
   do not use multi-institution `OR` queries or local-newspaper section URLs (both empirically broken, see the recipe file).
   Treat user-provided reference links as monitored outlet evidence, not decorative examples.
3. Read the actual external press article before selecting it.
   Do not rely only on headlines, portal snippets, or syndicated summaries.
   If only an official source page exists, label it as `공식 보도자료(대체)` or place it in `제외 또는 참고`; do not present it as an original article.
4. Prioritize monitored press sources and original article links.
   Prefer journalist-bylined local, education-specialized, national, or agency articles over official press releases and institution notices.
   Use official press releases and notices as fact-checking or last-resort fallback sources only.
5. De-duplicate conservatively.
   Remove only true duplicates: same URL, same outlet duplicate pages, or materially identical reposts of the same event.
   Do not drop distinct issues, institutions, programs, events, recruitment notices, library items, or affiliated-institution stories only because they are routine or lower priority.
6. Rank items by reporting value for ordering only.
   Put policy decisions, budget issues, safety incidents, personnel matters, audits, institutional openings/closures, and student-impacting changes above routine 행사 coverage, but ranking must not become an inclusion cap.
   If the period contains 20 relevant articles, list the 20 relevant articles.
7. Run follow-up checks for high-ranked or risky items.
   Re-search 기관명, 날짜, 사업명, and 핵심 쟁점 when the first source leaves ambiguity.
8. Search outline gaps before writing.
   If the briefing needs `핵심 요약`, `주요 언론보도`, or `제외/참고`, make sure each section has evidence or a clear `확인 필요` note.
   If the collected article count is unexpectedly low, explicitly run the monitored-outlet domains before concluding that coverage is sparse.
9. Run a source/date audit.
   Check article dates, source links, institution names, duplicate status, and whether each selected item is inside the requested period.
10. Write a full coverage-status briefing.
   Default main section format should match the office sharing style:
   `■ 기사 제목 - 매체명` on one line, followed by the source URL on the next line.
   For a canonical real-world reference of format and coverage breadth, see [examples/2026-06-26.md](./examples/2026-06-26.md).
   Use `핵심 요약` only to highlight important issues; do not move valid lower-priority articles out of the main list solely because they are less important.
11. Save the result files.
   Create a dated folder in the `인천교육청 언론보도 현황(YYYYMMDD)` format and store both the Markdown file and the HTML file in that folder.

## Source Priority

Use linked, directly relevant coverage first. For detailed source priority, selection, output, save, and edge-case rules, read [references/selection-output-rules.md](references/selection-output-rules.md).

## Selection, Output, And Save Rules

Use [references/selection-output-rules.md](references/selection-output-rules.md) for selection filters, output structure, save naming, and no-result handling.

## Automation Note

- This skill is intended to run by default for daily news monitoring without requiring an explicit trigger phrase each time.
- However, automatic day-by-day file creation requires an external scheduler or workflow runner.
- If no scheduler is configured, the skill can still be invoked implicitly during relevant news-monitoring tasks, but it cannot guarantee unattended daily generation on its own.
- The bundled runner keeps `run.log` status lines and removes empty partial outputs on failure.
- Broad Codex bypass mode should be treated as an explicit opt-in for automation, not a default.

## Writing Rules

- Write in Korean unless the user asks otherwise.
- Prefer concise administrative briefing tone.
- Distinguish facts from inference.
- If relevance is uncertain, say why it is borderline.
- If a requested institution cannot be confirmed from reporting, say that explicitly rather than stretching scope.

## Institution Handling

- Treat `인천광역시교육청` as the top-level institution.
- Include 산하 교육지원청 and 직속기관 when they are named explicitly or clearly fall within the user request.
- If the user says only `인천교육청`, include both 본청 and obviously affiliated bodies, but keep the ranking centered on institution-level importance.
- If the user asks for a narrower subset such as `학생교육원만`, filter strictly.

## Edge Cases

For no-result, mixed-source, and developing-story handling, use [references/selection-output-rules.md](references/selection-output-rules.md).
