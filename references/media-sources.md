# Monitored Media Sources

Use this file as the source roster for `daily-news-picker`.

## Operating Rule

- User-provided reference links are treated as monitored media evidence.
- A media domain in this file means: search it during low-count or normal daily runs, verify article dates, then include or explicitly exclude the item.
- Official `ice.go.kr` pages are verification sources, not preferred article sources. Use them to confirm facts or to find outbound/original media links.
- This roster is not a quality whitelist. It is a coverage net for media the office may reference.
- If a new user-provided article link appears, add its domain here before the next routine run.

## Required Source-Seed Domains

Run these media source-seed checks after the institution-name news queries, especially when candidate count is low.
The table intentionally prioritizes external media domains over official education-office pages because the briefing should point to original article links.

| Group | Outlet | Domain query seed |
|---|---|---|
| Incheon / Gyeonggi local | 인천in | `site:incheonin.com 인천교육청` |
| Incheon / Gyeonggi local | 인천투데이 | `site:incheontoday.com 인천교육청` |
| Incheon / Gyeonggi local | 인천일보 | `site:incheonilbo.com 인천교육청` |
| Incheon / Gyeonggi local | 경인일보 | `site:kyeongin.com 인천교육청` |
| Incheon / Gyeonggi local | 경기일보 | `site:kyeonggi.com 인천교육청` |
| Incheon / Gyeonggi local | 기호일보 | `site:kihoilbo.co.kr 인천교육청` |
| Incheon / Gyeonggi local | 경기신문 | `site:kgnews.co.kr 인천교육청` |
| Incheon / Gyeonggi local | 경기매일 | `site:kgmail.kr 인천교육청` |
| Incheon / Gyeonggi local | 경기etv뉴스 | `site:ggetv.co.kr 인천교육청` |
| Incheon / Gyeonggi local | 경인매일 | `site:kmaeil.com 인천교육청` |
| Incheon / Gyeonggi local | 경인신문 | `site:asn24.com 인천교육청` |
| Incheon / Gyeonggi local | 경인방송 | `site:news.ifm.kr 인천교육청` |
| Incheon / Gyeonggi local | 포커스인천 | `site:focusincheon.com 인천교육청` |
| Incheon / Gyeonggi local | 중부일보 | `site:joongboo.com 인천교육청` |
| Incheon / Gyeonggi local | 경기도민일보 | `site:kgdm.co.kr 인천교육청` |
| Incheon / Gyeonggi local | 경기헤드라인 | `site:gheadline.co.kr 인천교육청` |
| Education / local-specialized | 인천교육일보 | `site:in-ed.co.kr 인천교육청` |
| Education / local-specialized | 한국강사신문 | `site:lecturernews.com 인천교육청` |
| Education / local-specialized | 전자신문(에듀플러스) | `site:etnews.com 인천교육청` |
| Broadcast | KBS | `site:news.kbs.co.kr 인천교육청` |
| National / agency | 연합뉴스 | `site:yna.co.kr 인천교육청` |
| National / agency | 아이뉴스24 | `site:inews24.com 인천교육청` |
| National / agency | 신아일보 | `site:shinailbo.co.kr 인천교육청` |
| National / agency | 세계일보 | `site:segye.com 인천교육청` |
| National / agency | 매일일보 | `site:m-i.kr 인천교육청` |
| National / agency | 시민일보 | `site:siminilbo.co.kr 인천교육청` |
| National / agency | 스포츠조선 | `site:sportschosun.com 인천교육감` |
| National / agency | 컨슈머타임스 | `site:cstimes.com 인천교육청` |
| Internet / local distribution | 내외일보 | `site:naewoeilbo.com 인천교육청` |
| Internet / local distribution | 연합시민의소리 | `site:cunews.net 인천교육청` |
| Internet / local distribution | 국제뉴스 | `site:gukjenews.com 인천교육청` |
| Internet / local distribution | 뉴스프리존 | `site:newsfreezone.co.kr 인천교육청` |
| Internet / local distribution | 미디어투데이 | `site:mediatoday.asia 인천교육청` |
| Internet / local distribution | 문화저널21 | `site:mhj21.com 인천교육청` |
| Internet / local distribution | The세종 | `site:thesejong.tv 인천교육청` |
| Internet / local distribution | 세계타임즈 | `site:thesegye.com 인천교육청` |
| Internet / local distribution | 스카이데일리 | `site:skypress.co.kr 인천교육청` |
| Internet / local distribution | 뉴스피크 | `site:newspeak.kr 인천교육청` |
| Internet / local distribution | 뉴스타운 | `site:newstown.co.kr 인천교육청` |
| Internet / local distribution | 뉴스쉐어 | `site:newsshare.co.kr 인천교육청` |
| Internet / local distribution | 일간투데이 | `site:dtoday.co.kr 인천교육청` |
| Internet / local distribution | 경인종합일보 | `site:jonghapnews.com 인천교육청` |
| Internet / local distribution | 피디언뉴스 | `site:pedien.com 인천교육청` |
| Internet / local distribution | 더코리아 | `site:thekorea.kr 인천교육청` |
| Internet / local distribution | 웹이코노미 | `site:webeconomy.co.kr 인천교육청` |
| Internet / local distribution | 케이에스피뉴스 | `site:kspnews.com 인천교육청` |
| Internet / local distribution | 한국정경신문 | `site:kpenews.com 인천교육청` |
| Internet / local distribution | 엔디엔뉴스 | `site:ndnnews.co.kr 인천교육청` |
| Internet / local distribution | 중부뉴스통신 | `site:jungbunews.com 인천교육청` |
| Internet / local distribution | 투데이경제 | `site:tookyung.com 인천교육청` |
| Internet / local distribution | 디스커버리뉴스 | `site:discoverynews.kr 인천교육청` |
| Internet / local distribution | 뉴스뷰 | `site:newsview.co.kr 인천교육청` |
| Internet / local distribution | 서프라이즈뉴스 | `site:surprisenews.kr 인천교육청` |

## Official Verification Sources

Use these after external media searches to confirm facts, dates, institution names, and whether media coverage mirrors an official release. Do not use these as the representative selected article link when an external article exists.

| Group | Source | Query seed |
|---|---|---|
| Official verification | 인천광역시교육청 | `site:ice.go.kr 인천교육청` |
| Official verification | 인천광역시교육청 언론보도 현황 | `site:ice.go.kr/ice/na/ntt/selectNttList.do 언론보도 현황` |

## Query Variants

For each monitored domain, run at least one of these variants inside the requested date window:

- `site:{domain} 인천교육청`
- `site:{domain} 인천시교육청`
- `site:{domain} 인천광역시교육청`
- `site:{domain} 인천교육지원청`
- For a narrow institution request, add the institution term, e.g. `site:{domain} 인천 학생교육원`.

## Count And Reporting

- Record how many monitored domains were checked when the final article count is low.
- If monitored domains produce mostly duplicate or press-release reprint items, state that in `제외 또는 참고`.
- Do not turn a low selected count into `확인된 보도 부족` until the monitored domain roster has been checked.
- Do not stop after collecting only the top 5 items. The purpose of this roster is broad coverage recovery for the full daily press list.
