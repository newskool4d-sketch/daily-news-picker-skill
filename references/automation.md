# Automation Structure

## Engine: Codex or Claude

This automation supports two interchangeable LLM engines for the collection/verification/report-writing step.
Everything else in the pipeline (holiday calendar, RSS collector, Markdown validation/repair, candidate promotion,
downstream DB ingest, site publish) is identical between the two — only the runner script and the CLI invoked
inside it differ.

| | Codex (original) | Claude (2026-08-21) |
|---|---|---|
| Runner script | `scripts/run-daily-news-picker.ps1` | `scripts/run-daily-news-picker-claude.ps1` |
| CLI invoked | `codex exec` (`-m gpt-5.6-sol`, `-s read-only`) | `claude -p` (`--model sonnet`, `--safe-mode`, explicit `--tools`/`--allowedTools`, `--permission-mode dontAsk`; see Safety Notes) |
| Write access during the run | sandboxed via `-s read-only` | built-in tools restricted to Read/Glob/Grep/WebSearch/WebFetch; inherited customization and MCP isolated by the runner options; normal-run verification pending |
| Unattended auth | `codex` session/API credentials | `claude.exe` at `%CLAUDE_CODEX_CLAUDE_BIN%` (falls back to `claude` on PATH); diagnostic: `scripts/test-claude-headless-auth.ps1` |

**Currently registered in Task Scheduler**: the Claude runner, `\DailyNewsPicker\IncheonEducationNews`, daily at 09:00
(changed from 05:00 on 2026-08-21 together with the engine switch).

Reconfirmed 2026-11-03 by reading `%WINDIR%\System32\Tasks\DailyNewsPicker\IncheonEducationNews` directly:
the enabled daily trigger starts at `2026-08-21T00:00:00Z` (09:00 KST), and the action explicitly passes
`-CollectionTime "09:00"` to the Claude runner. CIM and `schtasks` queries were unavailable in this session;
the saved task XML, runner code, and recent candidate metadata were compared instead. No task was re-registered.

### Execution time and article cutoff

- Scheduled invocation: every day at 09:00 KST. The runner skips generation on weekends and Korean public holidays unless forced.
- Article window: previous business day 09:00 inclusive through report day 09:00 exclusive. Skipped-day articles therefore enter the next business-day window.
- Explicit `-CollectionTime` takes precedence. Without it, the Claude runner defaults to 09:00 and the Codex runner to 05:00.
- The registration script's `-StartTime` defaults to 05:00 and supplies both the task trigger and `-CollectionTime` for a new registration. That default does not change the current task's explicit 09:00 action.
- A delayed run with the same `ReportDate` keeps the configured cutoff; it does not extend the window to the collection finish time. A run after midnight without an explicit report date may select a different report day.
- The 2026-11-03 candidate file records `2026-11-02 09:00 ~ 2026-11-03 09:00`, despite collection at 11:17 and report-processing log entries at 11:17–11:20. Whether that was a delayed or manual run was not established.

**Why the switch**: the Codex-engine run on 2026-08-21 06:07 recorded `STATUS: FAILED [OUTPUT_VALIDATION]` —
not a network/MCP failure, but the model repeatedly using ad-hoc `##`-level category headers instead of the
single required `## 주요 언론보도` header, exhausting the runner's retry budget. The Claude engine run the same day
produced a valid report on the first attempt with broader outlet diversity (12+ outlets vs. 1 in the last Codex
attempt), after a similar preamble-text quirk (`claude -p` prefixing the report with a stray "모든 검증이 끝났습니다"
sentence) was fixed by tightening the prompt and adding a title-deduplication step to `Repair-MarkdownReport`.

**To switch to the original Codex/05:00 configuration**: re-run `scripts/register-daily-news-picker-task.ps1` with
`-ScriptPath scripts\run-daily-news-picker.ps1` and `-StartTime 05:00`. Nothing about the Codex runner was
removed. To change only the engine while preserving the current window, explicitly use `-StartTime 09:00` instead.

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

## Headless Authentication (measured 2026-10-01 ~ 10-02)

Failure class `STATUS: FAILED [CLAUDE_EXIT]` (exit 1, both attempts end within ~30 s, `claude.stderr.log`
empty) has three observed causes — always read `<engineWorkDir>\last-message.md` first to tell them apart:

| last-message.md text | Cause | Recovery |
|---|---|---|
| `Failed to authenticate: OAuth session expired and could not be refreshed` | login session expired (`.credentials.json` `expiresAt` reset to 0) | user runs `/login` in an interactive `claude`, then standard backfill |
| `You've hit your session limit · resets <time>` | Max plan usage limit | wait until reset, then backfill |
| `Failed to authenticate. API Error: 401 OAuth access token is invalid` | a token supplied via `CLAUDE_CODE_OAUTH_TOKEN` is revoked (no refresh path) | delete the variable, then backfill from a **new** terminal |

Measured cadence of the login-expiry case on the Claude engine: 2026-09-01 and 2026-10-01 (30 days apart).
The claude.ai refresh token is issued for ~27 days from the interactive login and the daily refresh does not
extend it (`refreshTokenExpiresAt` stays fixed), so a plain `/login` has to be repeated about monthly. This is
the accepted operating mode.

**Do not use `claude setup-token` / `CLAUDE_CODE_OAUTH_TOKEN` on this machine.** Tried 2026-10-01: the token
passed a headless test at 17:26, then the 2026-10-02 09:00 scheduled run failed with `401 OAuth access token
is invalid` while the interactive login token still returned HTTP 200. No `/login` or `setup-token` was run in
between; the only event was the interactive session's automatic credential refresh at 08:12. Conclusion: a
long-lived token is revoked when another session on the same account refreshes its login (undocumented — the
docs only state a one-year validity). With the desktop app keeping sessions open all day, the token cannot
survive. While the stale variable exists, **every new Claude session, including interactive ones, fails with
401**, because the variable takes precedence over `.credentials.json`. The variable was deleted 2026-10-02.

Side finding: the scheduled task (`LogonType=Interactive`) did inherit a user environment variable added the
previous day without re-registration.

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

- Current scheduled runner: `scripts/run-daily-news-picker-claude.ps1`; Codex alternative: `scripts/run-daily-news-picker.ps1`
- Task registration: `scripts/register-daily-news-picker-task.ps1`
- RSS collector: `scripts/collect_news_rss.py` — Google News RSS 주 엔진 + 네이버 뉴스 API 보강의 결정론적 1차 수집기 (2026-07-17 실측 채택).
  러너가 선택한 모델 실행 전에 자동 호출하며, 수동 단독 실행도 가능 (`--start/--end/--out-dir`).
- Verification promotion: `scripts/promote_verified_candidates.py` — 모델의 본문 검증 표식을
  검증 후보 파생 JSON으로 변환하고, 원본 후보 풀은 변경하지 않는다.

## Execution Model

1. The runner checks whether the current date is a weekday.
2. It queries Korean public holidays from `date.nager.at` and caches the result locally with a **7-day TTL**
   (법 개정으로 공휴일이 바뀔 수 있음 — 실사례: 2026-05-11 시행 개정으로 제헌절 재지정, 무기한 캐시 탓에
   2026-07-17 공휴일에 러너가 실행되는 사고 발생). On API failure it falls back to the stale cache.
3. If it is a weekend or public holiday, it skips generation unless forced.
4. It creates the dated output folder and writes `run.log` with explicit `STARTED`, `SUCCEEDED`, or `FAILED` status lines.
5. It runs the RSS collector (`collect_news_rss.py`) for the exact check window and drops `collected_articles.json`
   into the engine work directory. On collector failure, timeout, or a 0-article result it falls back to model-assisted search.
6. It runs `claude -p` or `codex exec --search` with the `daily-news-picker` instructions; when the candidate pool exists, the prompt
   directs the model to use it as the primary pool (with an explicit relevance check for `engine: naver-api` entries)
   and to spend effort on selection, verification, and gap-filling instead of raw collection.
   The prompt is delivered via **stdin** (`-RedirectStandardInput prompt.txt`), never as a multiline argv string.
   For Codex, `codex exec -` is required:
   the npm `.cmd` shim truncates argv at the first newline, which silently delivered only the prompt's first line
   in every run during 2026-07-14~17 and caused three consecutive daily failures once the read-only sandbox landed.
7. It repairs and validates the report, retrying within the configured attempt budget on invalid output. Each main-list
   article needs its own absolute HTTP(S) URL; a reference-section URL cannot cover a missing article URL.
   A main list cannot contain both articles and a no-article declaration. Final report-validation failure stops before
   candidate promotion, DB ingest, and site publication; it must not be repaired by silently deleting articles.
8. Before downstream ingest, the runner reads the model's `DAILY_NEWS_VERIFIED_CANDIDATES` marker. Each entry must
   carry an exact candidate URL, `verified: true`, `publication_eligible: true`, and a concrete body-evidence
   `verification_basis`. The runner writes `verified_collected_articles.json`, strips the internal marker from the
   public Markdown, and keeps the raw `collected_articles.json` unchanged. Missing or malformed markers fail closed;
   candidates remain private and the run records `PARTIAL [VERIFICATION]` when the marker cannot be processed.
9. It converts the validated, marker-stripped Markdown into HTML. Plain article URLs and Markdown links become
   clickable anchors, with title and URL on separate lines and escaped HTML text. URL syntax validation and rendering
   do not replace actual article-body/source checks.
10. It feeds the downstream organizer (`~/.codex/skills/edu-news-organizer/scripts/newsdb.py`): briefing md first,
   then the verified candidate JSON (or the raw private pool when no promotion occurred), then same-story grouping,
   then a premium HTML digest (`교육뉴스 다이제스트.html`, Incheon Education CI design) saved next to the briefing.
   Output goes to `organizer-ingest.log`; required downstream or verification failures are surfaced as non-zero.

This improvement keeps that `edu-news-organizer` contract: briefing → candidate JSON → group → digest → existing
site publication. The raw candidate pool is preserved separately from promotion output. Same-story grouping,
three-section layout, and responsive grid continue to be owned by the organizer and are not redesigned here.

## Safety Notes

- `--dangerously-bypass-approvals-and-sandbox` is no longer implicit in the runner.
- Enable that behavior only when you explicitly pass `-DangerouslyBypassApprovalsAndSandbox`.
- Re-register the Windows task after changing this flag so the scheduled action matches the intended trust level.
- Claude uses `--tools "Read,Glob,Grep,WebSearch,WebFetch"` to restrict built-in tool availability and the same
  `--allowedTools` list to permit those tools without prompting, together with `--permission-mode dontAsk`.
  `--allowedTools` alone is not a tool-availability restriction; `bypassPermissions` is no longer used by this runner.
- `--safe-mode` disables inherited customization, installed plugins, hooks, MCP, CLAUDE.md, and skills for that Claude
  invocation; the runner supplies the task instructions explicitly. `--strict-mcp-config` with an empty
  `--mcp-config '{"mcpServers":{}}'` also prevents loading configured MCP servers. Existing authentication is reused;
  global settings and credential files are not rewritten or copied.
- The runner adds only the `daily-news-picker` skill root with `--add-dir` so safe-mode file tools can read its `SKILL.md` and references; it does not add the whole user home directory.
- These are the revised execution settings, not evidence of a completed normal run. Functional tests and actual
  collection → verification → organizer → site confirmation are deferred to the normal 2026-11-04 09:00 run,
  per the user's instruction. See [tests/smoke.md](../tests/smoke.md) for the pending checks.

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
