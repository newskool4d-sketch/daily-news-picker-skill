# Automation Structure

## Default Paths

- Base output folder: set explicitly with `-BasePath` or the `DAILY_NEWS_OUTPUT_DIR` environment variable. If neither is set, the task registration script uses `%USERPROFILE%\Documents\Codex\DailyNewsPicker`.
- Daily output folder: `인천교육청 언론보도 현황(YYYYMMDD)`
- Markdown file: `인천교육청 언론보도 현황.md`
- HTML file: `인천교육청 언론보도 현황.html`
- Run log: `run.log`
- Prompt snapshot: `prompt.txt`

## Scripts

- Runner: `scripts/run-daily-news-picker.ps1`
- Task registration: `scripts/register-daily-news-picker-task.ps1`
- RSS collector: `scripts/collect_news_rss.py` — Google News RSS 주 엔진 + 네이버 뉴스 API 보강의 결정론적 1차 수집기 (2026-07-17 실측 채택).
  러너가 Codex 실행 전에 자동 호출하며, 수동 단독 실행도 가능 (`--start/--end/--out-dir`).

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
9. After SUCCEEDED, it feeds the downstream organizer (`~/.codex/skills/edu-news-organizer/scripts/newsdb.py`)
   non-fatally: briefing md first (so the `--selected` filter works), then the candidate-pool JSON, then same-story
   grouping for the report date. Output goes to `organizer-ingest.log`; failures are logged but never fail the run.

## Safety Notes

- `--dangerously-bypass-approvals-and-sandbox` is no longer implicit in the runner.
- Enable that behavior only when you explicitly pass `-DangerouslyBypassApprovalsAndSandbox`.
- Re-register the Windows task after changing this flag so the scheduled action matches the intended trust level.

## Scheduler

Use Windows Task Scheduler to call the runner every weekday at 9:00 AM.
Weekend and public holiday suppression is handled inside the runner script; skipped-day articles are included in the next business-day 9:00 AM check window.
Register the task with PowerShell 7 (`pwsh`) when available. Windows PowerShell 5 may misread UTF-8 Korean strings in this script and fail before execution.

Example registration command:

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\daily-news-picker\scripts\register-daily-news-picker-task.ps1" -BasePath "$env:USERPROFILE\Documents\Codex\DailyNewsPicker"
```

If unattended execution still needs the broader Codex flag, register with:

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\daily-news-picker\scripts\register-daily-news-picker-task.ps1" -BasePath "$env:USERPROFILE\Documents\Codex\DailyNewsPicker" -DangerouslyBypassApprovalsAndSandbox
```
