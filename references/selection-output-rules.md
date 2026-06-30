# Selection And Output Rules

## Source Priority

1. User-provided linked press articles from media outlets
2. Journalist-bylined articles from monitored-outlet domains in [media-sources.md](./media-sources.md)
3. Local and regional media article links
4. Education-specialized media article links
5. National or agency media article links
6. Official institution pages, press releases, notices, and `ice.go.kr` pages only as fact-checking or last-resort fallback sources

Prefer the clearest original media article when several sources repeat the same fact.
Do not use an official education-office press release as the representative selected article when an accessible external media article exists.
If an official `언론보도 현황` page lists or mirrors coverage, follow the original media article URL where available.
For the monitored outlet roster and excluded source types, see [media-sources.md](./media-sources.md) and [search-recipes.md](./search-recipes.md).

## Selection

- Keep items tied to policy, budget, projects, student safety, education activity, audits, organization operation, facilities, hiring, awards, agreements, complaints, incidents, or accidents.
- For the daily `주요 언론보도 현황`, keep all verified relevant press articles inside the requested period. There is no default cap such as 5 items.
- Ranking controls order, not inclusion. Lower-priority but relevant articles stay in `주요 언론보도`.
- Routine but direct education-office coverage is still coverage: program operation, event 개최, participant recruitment, library programs, affiliated-institution activities, school-level stories tied to 인천교육청 policy, and education-support-office stories should be kept unless clearly irrelevant.
- Exclude generic education news unless an Incheon education-office entity directly appears.
- Exclude stale articles outside the requested period unless needed as background.
- Exclude low-information reposts, clickbait, automated content farms, and duplicates.
- Article form: prefer journalist-bylined press articles. Official education-office press releases are verification or fallback sources, not normal selected article links. Do not silently drop raw press-release reprints from monitored outlets; collect them, label them as `보도자료 전재/반복 보도`, and place them in `제외 또는 참고` unless they are the only accessible coverage for an operationally important item.
- Cross-outlet duplicates: when multiple outlets cover the same event with materially identical content, keep the single most useful external article as the representative link. Do not merge or drop separate events, separate institutions, or separate program items just because they are lower priority.
- Anti-fabrication: never invent titles or URLs; include only URLs confirmed to resolve to the actual article. If nothing qualifies, state it plainly.
- Prefer directly accessible links.
- Low-count guard: if the daily count seems unusually low for a normal business-day coverage-status report, run the monitored-outlet domain checks and official verification checks before writing `확인된 유의미 기사 없음` or producing a sparse report.

## Output

Default structure:

1. Opening line
   - `YYYY. M. D.(요일) 인천광역시교육청 주요 언론보도 현황입니다.`
2. `핵심 요약` (optional but recommended)
   - one-line assessment
   - most important 1 to 3 issues
3. `주요 언론보도`
   - preserve all verified relevant items
   - default item format:
     `■ 기사 제목 - 매체명`
     `URL`
   - order by operational importance, then 본청, 교육지원청, 직속기관, 학교/의회/지역현안 as appropriate
4. `제외 또는 참고`
   - true duplicate articles, background items, uncertain items
   - monitored outlet items that were checked but excluded, with the exclusion reason

## Save

- Save completed briefings as both `.md` and `.html`.
- Create one folder per run date named `인천교육청 언론보도 현황(YYYYMMDD)`.
- Keep title and article order aligned across Markdown and HTML.
- If the base path is unclear, infer from context or ask briefly.

## Edge Cases

- If no meaningful articles exist, return `확인된 유의미 기사 없음` and list checked sources.
- If sources mix notices and press articles, label the source type.
- For developing stories, include the exact checked time and mark details as provisional.
