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

## Execution Model

1. The runner checks whether the current date is a weekday.
2. It queries Korean public holidays from `date.nager.at` and caches the result locally.
3. If it is a weekend or public holiday, it skips generation unless forced.
4. It creates the dated output folder and writes `run.log` with explicit `STARTED`, `SUCCEEDED`, or `FAILED` status lines.
5. It runs `codex exec --search` with the `daily-news-picker` instructions.
6. If Codex fails or writes an empty report, the runner removes partial `md/html` outputs and records a categorized failure summary.
7. It converts the validated Markdown into an HTML file.

## Safety Notes

- `--dangerously-bypass-approvals-and-sandbox` is no longer implicit in the runner.
- Enable that behavior only when you explicitly pass `-DangerouslyBypassApprovalsAndSandbox`.
- Re-register the Windows task after changing this flag so the scheduled action matches the intended trust level.

## Scheduler

Use Windows Task Scheduler to call the runner every day at 7:00 AM.
Weekend and public holiday suppression is handled inside the runner script.
Register the task with PowerShell 7 (`pwsh`) when available. Windows PowerShell 5 may misread UTF-8 Korean strings in this script and fail before execution.

Example registration command:

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\daily-news-picker\scripts\register-daily-news-picker-task.ps1" -BasePath "$env:USERPROFILE\Documents\Codex\DailyNewsPicker"
```

If unattended execution still needs the broader Codex flag, register with:

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\daily-news-picker\scripts\register-daily-news-picker-task.ps1" -BasePath "$env:USERPROFILE\Documents\Codex\DailyNewsPicker" -DangerouslyBypassApprovalsAndSandbox
```
