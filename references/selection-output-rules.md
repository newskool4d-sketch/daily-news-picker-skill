# Selection And Output Rules

## Source Priority

1. Linked press articles
2. Incheon Metropolitan Office of Education main-office coverage
3. District office and direct-institution coverage
4. Local media
5. National media

Prefer the clearest authoritative source when several sources repeat the same fact.
For the observed outlet roster and excluded source types, see [search-recipes.md](./search-recipes.md).

## Selection

- Keep items tied to policy, budget, projects, student safety, education activity, audits, organization operation, facilities, hiring, awards, agreements, complaints, incidents, or accidents.
- Exclude generic education news unless an Incheon education-office entity directly appears.
- Exclude stale articles outside the requested period unless needed as background.
- Exclude low-information reposts, clickbait, automated content farms, and duplicates.
- Article form: include only journalist-bylined press articles. Exclude raw press-release reprints (보도자료 원문 게재) and institution notice pages, except as background labeled by source type.
- Cross-outlet duplicates: when multiple outlets cover the same event, keep the single most informative article (coverage depth and detail), and drop the rest even if headlines differ.
- Anti-fabrication: never invent titles or URLs; include only URLs confirmed to resolve to the actual article. If nothing qualifies, state it plainly.
- Prefer directly accessible links.

## Output

Default structure:

1. `핵심 요약`
   - one-line assessment
   - most important 1 to 2 issues
2. `선별 기사`
   - date, institution, outlet, title, key content, reason selected, link
3. `제외 또는 참고`
   - duplicate articles, background items, uncertain items

## Save

- Save completed briefings as both `.md` and `.html`.
- Create one folder per run date named `인천교육청 언론보도 현황(YYYYMMDD)`.
- Keep title and article order aligned across Markdown and HTML.
- If the base path is unclear, infer from context or ask briefly.

## Edge Cases

- If no meaningful articles exist, return `확인된 유의미 기사 없음` and list checked sources.
- If sources mix notices and press articles, label the source type.
- For developing stories, include the exact checked time and mark details as provisional.
