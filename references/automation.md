# Automation Structure

## Engine: Codex or Claude

This automation supports two interchangeable LLM engines for the collection/verification/report-writing step.
Everything else in the pipeline (holiday calendar, RSS collector, Markdown validation/repair, candidate promotion,
downstream DB ingest, site publish) is identical between the two — only the runner script and the CLI invoked
inside it differ.

| | Codex (original) | Claude (2026-08-21) |
|---|---|---|
| Runner script | `scripts/run-daily-news-picker.ps1` | `scripts/run-daily-news-picker-claude.ps1` |
| CLI invoked | `codex exec` (`-m gpt-5.6-sol`, `-s read-only`) | `claude -p` (`--model sonnet`, `--allowedTools "Read Glob Grep WebSearch WebFetch"`, `--permission-mode bypassPermissions`) |
| Write access during the run | sandboxed via `-s read-only` | structurally impossible — the allowed-tools list has no write/edit/bash tool |
| Unattended auth | `codex` session/API credentials | `claude.exe` at `%CLAUDE_CODEX_CLAUDE_BIN%` (falls back to `claude` on PATH), verified headless via `scripts/test-claude-headless-auth.ps1` |

**Currently registered in Task Scheduler**: the Claude runner, `\DailyNewsPicker\IncheonEducationNews`, daily at 09:00
(changed from 05:00 on 2026-08-21 together with the engine switch).

**Why the switch**: the Codex-engine run on 2026-08-21 06:07 recorded `STATUS: FAILED [OUTPUT_VALIDATION]` —
not a network/MCP failure, but the model repeatedly using ad-hoc `##`-level category headers instead of the
single required `## 주요 언론보도` header, exhausting the runner's retry budget. The Claude engine run the same day
produced a valid report on the first attempt with broader outlet diversity (12+ outlets vs. 1 in the last Codex
attempt), after a similar preamble-text quirk (`claude -p` prefixing the report with a stray "모든 검증이 끝났습니다"
sentence) was fixed by tightening the prompt and adding a title-deduplication step to `Repair-MarkdownReport`.

**To roll back to Codex**: re-run `scripts/register-daily-news-picker-task.ps1` with
`-ScriptPath scripts\run-daily-news-picker.ps1` and `-StartTime 05:00`. Nothing about the Codex runner was
changed or removed.

## Manual Re-run / Backfill (Claude engine)

When a scheduled run fails and a date needs to be backfilled, do NOT pass `-EnablePublicPush` on the
command line — the `[bool]` parameter fails string-to-bool binding under `pwsh -File` when invoked from
a non-PowerShell shell (measured twice on 2026-08-27: both `-EnablePublicPush:$false` and
`-EnablePublicPush:1` die with "Cannot process argument transformation"). The Task Scheduler action's
`-EnablePublicPush:True` works only in that native invocation context; keep the two paths separate.

Canonical manual backfill command (site push enabled via env var — verified 2026-08-27):

```powershell
$env:EDU_NEWS_SITE_PUSH = "1"
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\daily-news-picker\scripts\run-daily-news-picker-claude.ps1" -BasePath "$env:USERPROFILE\Documents\Codex\DailyNewsPicker" -WorkingRoot "$env:USERPROFILE" -CollectionTime "09:00" -ReportDate "YYYY-MM-DD" -SiteDir "$env:USERPROFILE\Documents\Codex\EduNewsSite" -Force
```

Omit `EDU_NEWS_SITE_PUSH` (or set `"0"`) to rebuild the site locally without pushing. The backfilled
date's check window is derived from `-ReportDate` and `-CollectionTime` exactly as in a scheduled run
(previous business day 09:00 → report date 09:00), so late articles are excluded identically.

Known validation quirk (fixed 2026-08-27): the report validator requires the exact literal
`YYYY-MM-DD HH:mm` window strings in the body. The 2026-08-26 scheduled run failed twice because the
model paraphrased the window ("당일 오전 9시"). `Repair-MarkdownReport` now injects the canonical
`점검 창: <start> ~ <end> (Asia/Seoul)` line under the title whenever either literal is missing, making
the check deterministic.

Known downstream quirk (fixed 2026-09-21): `newsdb.py ingest --briefing` derives the batch date from one of
`YYYY. M. D.(요일) … 주요 언론보도 현황입니다`, `보고일: YYYY-MM-DD`, or a `## 보도일` block, and exits 2
("날짜 헤더를 찾지 못해 인제스트를 중단합니다") when none is present. The 2026-09-21 scheduled run wrote
`- 기준일: 2026-09-21` instead, so the report and candidate promotion succeeded but the whole downstream
stage (DB → digest → site) was skipped (`STATUS: PARTIAL [DOWNSTREAM]`). `Repair-MarkdownReport` now injects
`- 보고일: <ReportDate>` under the title when no recognized date header exists (same block as the window
injection), and the prompt pins that line explicitly. Rule of thumb: metadata the runner already knows
(report date, check window) is injected by the runner, never left to the model's phrasing.

Recovery for this failure class needs no Claude re-run — the Markdown is already valid content. Re-apply the
repair to the real file and run the downstream steps only:

```powershell
# 1) repair in place (+ regenerate the briefing HTML)
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\run-daily-news-picker-claude.ps1" -BasePath "$env:USERPROFILE\Documents\Codex\DailyNewsPicker" -ReportDate "YYYY-MM-DD" -CollectionTime "09:00" -ValidateReportPath "<folder>\인천교육청 언론보도 현황.md" -ValidationHtmlOutputPath "<folder>\인천교육청 언론보도 현황.html"
# 2) downstream (organizer scripts)
python newsdb.py ingest --briefing "<folder>\인천교육청 언론보도 현황.md"
python newsdb.py ingest --json "<folder>\verified_collected_articles.json"
python newsdb.py group --date YYYY-MM-DD
python newsdb.py digest --date YYYY-MM-DD --format html --out "<folder>\교육뉴스 다이제스트.html"
python publish_site.py --site-dir "$env:USERPROFILE\Documents\Codex\EduNewsSite" --date YYYY-MM-DD --push
```

## Default Paths

- Base output folder: set explicitly with `-BasePath` or the `DAILY_NEWS_OUTPUT_DIR` environment variable. If neither is set, the task registration script uses `%USERPROFILE%\Documents\Codex\DailyNewsPicker`.
- Daily output folder: `인천교육청 언론보도 현황(YYYYMMDD)`
- Markdown file: `인천교육청 언론보도 현황.md`
- HTML file: `인천교육청 언론보도 현황.html`
- Raw candidate JSON: `collected_articles.json` (수집 원본, 항상 보존)
- Verified candidate JSON: `verified_collected_articles.json` (본문 검증 표식으로 승격된 파생본)
- Verification manifest: `verification-manifest.json` (승격 근거·무시 항목 감사 기록)
- Run log: `run.log`
- Prompt snapshot: `prompt.txt`

## Scripts

- Runner: `scripts/run-daily-news-picker.ps1`
- Task registration: `scripts/register-daily-news-picker-task.ps1`
- RSS collector: `scripts/collect_news_rss.py` — Google News RSS 주 엔진 + 네이버 뉴스 API 보강의 결정론적 1차 수집기 (2026-07-17 실측 채택).
  러너가 Codex 실행 전에 자동 호출하며, 수동 단독 실행도 가능 (`--start/--end/--out-dir`).
- Verification promotion: `scripts/promote_verified_candidates.py` — Codex의 본문 검증 표식을
  검증 후보 파생 JSON으로 변환하고, 원본 후보 풀은 변경하지 않는다.

## Execution Model

1. The runner checks whether the current date is a weekday.
2. It queries Korean public holidays from `date.nager.at` and caches the result locally with a **7-day TTL**
   (법 개정으로 공휴일이 바뀔 수 있음 — 실사례: 2026-05-11 시행 개정으로 제헌절 재지정, 무기한 캐시 탓에
   2026-07-17 공휴일에 러너가 실행되는 사고 발생). On API failure it falls back to the stale cache.
3. If it is a weekend or public holiday, it skips generation unless forced.
4. It creates the dated output folder and writes `run.log` with explicit `STARTED`, `SUCCEEDED`, or `FAILED` status lines.
5. It runs the RSS collector (`collect_news_rss.py`) for the exact check window and drops `collected_articles.json`
   into the Codex work directory. On collector failure, timeout, or a 0-article result it falls back to Codex self-search.
6. It runs `codex exec --search` with the `daily-news-picker` instructions; when the candidate pool exists, the prompt
   directs Codex to use it as the primary pool (with an explicit relevance check for `engine: naver-api` entries)
   and to spend effort on selection, verification, and gap-filling instead of raw collection.
   The prompt is delivered via **stdin** (`codex exec -` + `-RedirectStandardInput prompt.txt`), never as an argv string:
   the npm `.cmd` shim truncates argv at the first newline, which silently delivered only the prompt's first line
   in every run during 2026-07-14~17 and caused three consecutive daily failures once the read-only sandbox landed.
7. If Codex fails or writes an empty report, the runner removes partial `md/html` outputs and records a categorized failure summary.
8. It converts the validated Markdown into an HTML file.
9. Before downstream ingest, the runner reads the Codex `DAILY_NEWS_VERIFIED_CANDIDATES` marker. Each entry must
   carry an exact candidate URL, `verified: true`, `publication_eligible: true`, and a concrete body-evidence
   `verification_basis`. The runner writes `verified_collected_articles.json`, strips the internal marker from the
   public Markdown, and keeps the raw `collected_articles.json` unchanged. Missing or malformed markers fail closed;
   candidates remain private and the run records `PARTIAL [VERIFICATION]` when the marker cannot be processed.
10. It feeds the downstream organizer (`~/.codex/skills/edu-news-organizer/scripts/newsdb.py`): briefing md first,
   then the verified candidate JSON (or the raw private pool when no promotion occurred), then same-story grouping,
   then a premium HTML digest (`교육뉴스 다이제스트.html`, Incheon Education CI design) saved next to the briefing.
   Output goes to `organizer-ingest.log`; required downstream or verification failures are surfaced as non-zero.

## Safety Notes

- `--dangerously-bypass-approvals-and-sandbox` is no longer implicit in the runner.
- Enable that behavior only when you explicitly pass `-DangerouslyBypassApprovalsAndSandbox`.
- Re-register the Windows task after changing this flag so the scheduled action matches the intended trust level.

## Scheduler

Use Windows Task Scheduler to call a runner every day; the runner skips weekends and Korean public holidays.
Weekend and public holiday suppression is handled inside the runner script; skipped-day articles are included in
the next business-day collection window. Register the task with PowerShell 7 (`pwsh`) when available. Windows
PowerShell 5 may misread UTF-8 Korean strings in this script and fail before execution.

`\DailyNewsPicker\IncheonEducationNews` currently runs `run-daily-news-picker-claude.ps1` at 09:00 daily — see
"Engine: Codex or Claude" above for why and how to switch back.

Example registration command (Claude engine, 09:00):

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\daily-news-picker\scripts\register-daily-news-picker-task.ps1" -ScriptPath "$env:USERPROFILE\.codex\skills\daily-news-picker\scripts\run-daily-news-picker-claude.ps1" -BasePath "$env:USERPROFILE\Documents\Codex\DailyNewsPicker" -StartTime "09:00"
```

Example registration command (Codex engine, original, 05:00):

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\daily-news-picker\scripts\register-daily-news-picker-task.ps1" -BasePath "$env:USERPROFILE\Documents\Codex\DailyNewsPicker"
```

If unattended execution with the Codex engine still needs the broader Codex flag, register with:

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\daily-news-picker\scripts\register-daily-news-picker-task.ps1" -BasePath "$env:USERPROFILE\Documents\Codex\DailyNewsPicker" -DangerouslyBypassApprovalsAndSandbox
```
