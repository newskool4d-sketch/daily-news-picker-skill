param(
    [string]$BasePath = $env:DAILY_NEWS_OUTPUT_DIR,
    [string]$WorkingRoot = $env:USERPROFILE,
    [string]$CodexCommand = $(if (Test-Path (Join-Path $env:APPDATA "npm\codex.cmd")) { Join-Path $env:APPDATA "npm\codex.cmd" } else { "codex" }),
    [string]$Model = "gpt-5.4",
    [int]$CodexTimeoutSeconds = 1800,
    [int]$MaxAttempts = 2,
    [datetime]$ReportDate = (Get-Date).Date,
    [switch]$DangerouslyBypassApprovalsAndSandbox,
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($BasePath)) {
    throw "BasePath가 비어 있습니다. -BasePath를 지정하거나 DAILY_NEWS_OUTPUT_DIR 환경변수를 설정하세요."
}

function Write-Log {
    param([string]$Message)
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$stamp] $Message"
}

function Write-RunLog {
    param(
        [string]$Message,
        [string]$Path
    )

    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line
    if ($Path) {
        Add-Content -Path $Path -Value $line -Encoding UTF8
    }
}

function Get-HolidayCachePath {
    param([int]$Year)
    $cacheDir = Join-Path $env:USERPROFILE ".codex\skills\daily-news-picker\cache"
    if (-not (Test-Path $cacheDir)) {
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    }
    return (Join-Path $cacheDir "holidays-kr-$Year.json")
}

function Get-KoreanPublicHolidays {
    param([int]$Year)

    $cachePath = Get-HolidayCachePath -Year $Year
    if (Test-Path $cachePath) {
        try {
            return (Get-Content $cachePath -Raw | ConvertFrom-Json)
        } catch {
            Write-Log "휴일 캐시 파싱 실패. 다시 조회합니다."
        }
    }

    $url = "https://date.nager.at/api/v3/PublicHolidays/$Year/KR"
    try {
        $response = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 20
        $response | ConvertTo-Json -Depth 5 | Set-Content -Path $cachePath -Encoding UTF8
        return $response
    } catch {
        Write-Log "공휴일 API 조회 실패. 주말만 휴무로 간주합니다."
        return @()
    }
}

function Test-IsBusinessDay {
    param([datetime]$Date)

    if ($Date.DayOfWeek -in @([System.DayOfWeek]::Saturday, [System.DayOfWeek]::Sunday)) {
        return $false
    }

    $holidays = Get-KoreanPublicHolidays -Year $Date.Year
    $dateKey = $Date.ToString("yyyy-MM-dd")
    foreach ($holiday in $holidays) {
        if ($holiday.date -eq $dateKey) {
            return $false
        }
    }

    return $true
}

function Get-PreviousBusinessDay {
    param([datetime]$Date)

    $cursor = $Date.Date.AddDays(-1)
    for ($i = 0; $i -lt 14; $i++) {
        if (Test-IsBusinessDay -Date $cursor) {
            return $cursor
        }
        $cursor = $cursor.AddDays(-1)
    }

    throw "직전 업무일을 계산하지 못했습니다: $Date"
}

function Convert-MarkdownToHtmlDocument {
    param(
        [string]$MarkdownPath,
        [string]$HtmlPath,
        [string]$Title
    )

    $markdown = Get-Content $MarkdownPath -Raw -Encoding UTF8
    $body = $null

    if (Get-Command ConvertFrom-Markdown -ErrorAction SilentlyContinue) {
        $converted = ConvertFrom-Markdown -InputObject $markdown
        if ($converted.Html) {
            $body = $converted.Html
        }
    }

    if (-not $body) {
        $escaped = [System.Net.WebUtility]::HtmlEncode($markdown)
        $escaped = $escaped -replace '(?m)^### (.+)$', '<h3>$1</h3>'
        $escaped = $escaped -replace '(?m)^## (.+)$', '<h2>$1</h2>'
        $escaped = $escaped -replace '(?m)^# (.+)$', '<h1>$1</h1>'
        $escaped = $escaped -replace '(?m)^- (.+)$', '<li>$1</li>'
        $escaped = $escaped -replace '(<li>.*</li>(\r?\n)?)+', { param($m) "<ul>`n$($m.Value)</ul>`n" }
        $escaped = $escaped -replace '\[(.+?)\]\((.+?)\)', '<a href="$2">$1</a>'
        $escaped = $escaped -replace "(`r`n|`n){2,}", "</p><p>"
        $body = "<p>$escaped</p>"
    }

    $generatedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $html = @"
<!doctype html>
<html lang="ko">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="icon" href="data:,">
  <title>$Title</title>
  <style>
    :root {
      color-scheme: light;
      --ink: #111827;
      --muted: #6b7280;
      --line: #d1d5db;
      --paper: #fafafa;
      --soft: #f2f4f7;
      --blue: #0f4c81;
      --red: #a23b2a;
      --teal: #0f766e;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      background: var(--paper);
      color: var(--ink);
      font-family: "KoPubWorld Batang", "Noto Serif KR", "Nanum Myeongjo", "Malgun Gothic", serif;
      line-height: 1.78;
    }
    .page {
      width: min(1080px, calc(100% - 44px));
      margin: 0 auto;
      padding: 38px 0 58px;
    }
    header {
      display: grid;
      grid-template-columns: 1fr 270px;
      gap: 28px;
      padding: 22px 0 26px;
      border-top: 6px solid var(--ink);
      border-bottom: 1px solid var(--line);
    }
    .kicker {
      margin: 0 0 8px;
      color: var(--blue);
      font-family: "Pretendard", "SUIT", "Malgun Gothic", sans-serif;
      font-size: 13px;
      font-weight: 800;
    }
    h1 {
      margin: 0;
      font-size: 45px;
      line-height: 1.15;
      letter-spacing: 0;
    }
    .deck {
      max-width: 720px;
      margin: 16px 0 0;
      color: #374151;
      font-size: 18px;
    }
    .meta {
      margin: 0;
      padding: 0;
      list-style: none;
      font-family: "Pretendard", "SUIT", "Malgun Gothic", sans-serif;
      font-size: 13px;
      color: var(--muted);
    }
    .meta li {
      padding: 8px 0;
      border-bottom: 1px solid var(--line);
    }
    .layout {
      display: grid;
      grid-template-columns: 220px 1fr;
      gap: 34px;
      margin-top: 34px;
    }
    aside {
      padding-right: 22px;
      border-right: 1px solid var(--line);
    }
    .number {
      display: block;
      color: var(--blue);
      font-family: "Pretendard", "SUIT", "Malgun Gothic", sans-serif;
      font-size: 34px;
      font-weight: 900;
      line-height: 1.05;
    }
    .side-title {
      margin: 10px 0 8px;
      font-family: "Pretendard", "SUIT", "Malgun Gothic", sans-serif;
      font-size: 15px;
      font-weight: 900;
    }
    .side-text {
      margin: 0 0 22px;
      color: var(--muted);
      font-size: 14px;
    }
    .article > h1:first-child { display: none; }
    .article h2 {
      margin: 0 0 14px;
      padding-top: 28px;
      border-top: 3px solid var(--ink);
      color: var(--ink);
      font-family: "Pretendard", "SUIT", "Malgun Gothic", sans-serif;
      font-size: 22px;
      line-height: 1.3;
      letter-spacing: 0;
    }
    .article h2:first-child,
    .article > h1:first-child + h2 {
      padding-top: 0;
      border-top: 0;
    }
    .article h2 + ul {
      margin: 0 0 30px;
      padding: 18px 22px;
      background: var(--soft);
      border-left: 5px solid var(--blue);
      border-radius: 0 8px 8px 0;
    }
    .article h3 {
      margin: 26px 0 12px;
      padding-top: 22px;
      border-top: 1px solid var(--line);
      color: var(--ink);
      font-size: 26px;
      line-height: 1.35;
      letter-spacing: 0;
    }
    .article p { margin: 0 0 12px; }
    .article ul,
    .article ol {
      margin: 0 0 16px;
      padding-left: 24px;
    }
    .article li { margin: 6px 0; }
    a {
      color: var(--blue);
      font-family: "Pretendard", "SUIT", "Malgun Gothic", sans-serif;
      font-weight: 800;
      text-decoration: none;
      word-break: break-all;
    }
    a:hover { text-decoration: underline; }
    code {
      padding: 2px 5px;
      background: #fff;
      border: 1px solid var(--line);
      border-radius: 5px;
      color: #374151;
      font-family: "D2Coding", Consolas, monospace;
      font-size: 0.92em;
    }
    blockquote {
      margin: 16px 0;
      padding: 12px 16px;
      background: var(--soft);
      border-left: 4px solid var(--blue);
      color: #374151;
    }
    table {
      width: 100%;
      margin: 1rem 0;
      border-collapse: collapse;
      font-family: "Pretendard", "SUIT", "Malgun Gothic", sans-serif;
      font-size: 14px;
    }
    th,
    td {
      padding: 10px 12px;
      border: 1px solid var(--line);
      vertical-align: top;
    }
    th {
      background: var(--soft);
      text-align: left;
    }
    @media print {
      body { background: #fff; }
      .page { width: 100%; padding: 0; }
      a { color: #000; }
    }
    @media (max-width: 840px) {
      header,
      .layout { grid-template-columns: 1fr; }
      aside {
        padding: 0 0 18px;
        border-right: 0;
        border-bottom: 1px solid var(--line);
      }
      h1 { font-size: 34px; }
    }
    @media (max-width: 560px) {
      .page { width: min(100% - 24px, 1080px); }
      h1 { font-size: 29px; }
      .article h3 { font-size: 23px; }
    }
  </style>
</head>
<body>
  <main class="page">
    <header>
      <div>
        <p class="kicker">Morning Editorial Brief</p>
        <h1>$Title</h1>
        <p class="deck">인천광역시교육청 및 산하기관 언론보도를 현안성, 기관 관련성, 후속 대응 필요성 기준으로 선별한 일일 브리핑입니다.</p>
      </div>
      <ul class="meta">
        <li>생성 시각: $generatedAt</li>
        <li>산출 형식: Markdown 원문 기반 HTML 브리핑</li>
        <li>대상: 본청, 교육지원청, 직속기관 관련 언론보도</li>
      </ul>
    </header>
    <div class="layout">
      <aside>
        <span class="number">AUTO</span>
        <p class="side-title">자동 선별</p>
        <p class="side-text">수집 결과를 기반으로 보고 우선순위와 참고 기사를 구분합니다.</p>
        <span class="number">ICE</span>
        <p class="side-title">점검 기준</p>
        <p class="side-text">현안성, 기관 관련성, 후속 대응 필요성을 중심으로 확인합니다.</p>
      </aside>
      <section class="article">
$body
      </section>
    </div>
  </main>
</body>
</html>
"@

    Set-Content -Path $HtmlPath -Value $html -Encoding UTF8
}

function Get-PreferredGeneratedFile {
    param(
        [string]$SearchDir,
        [string]$Pattern
    )

    if (-not (Test-Path $SearchDir)) {
        return $null
    }

    $candidate = Get-ChildItem -Path $SearchDir -Filter $Pattern -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    return $candidate
}

function Remove-IfExists {
    param([string]$Path)

    if ($Path -and (Test-Path $Path)) {
        Remove-Item -Path $Path -Force -ErrorAction SilentlyContinue
    }
}

function Test-NonEmptyFile {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return $false
    }

    $item = Get-Item -Path $Path -ErrorAction SilentlyContinue
    return ($item -and $item.Length -gt 0)
}

function Repair-MarkdownReport {
    param([string]$Path)

    if (-not (Test-NonEmptyFile -Path $Path)) {
        return
    }

    $content = Get-Content -Path $Path -Raw -Encoding UTF8
    $normalized = ($content -replace "^\uFEFF", "").Trim()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return
    }

    if (-not $normalized.TrimStart().StartsWith("# 인천교육청 언론보도 현황")) {
        $normalized = "# 인천교육청 언론보도 현황`r`n`r`n$normalized"
    }

    $normalized = [regex]::Replace($normalized, '(?m)^(핵심 요약|주요 언론보도|제외 또는 참고)\s*$', '## $1')
    Set-Content -Path $Path -Value $normalized -Encoding UTF8
}

function Test-IsMarkdownReport {
    param([string]$Path)

    if (-not (Test-NonEmptyFile -Path $Path)) {
        return $false
    }

    $content = Get-Content -Path $Path -Raw -Encoding UTF8
    $trimmed = $content.TrimStart()
    $hasTitle = $trimmed.StartsWith("# 인천교육청 언론보도 현황") -or ($trimmed -match '^20\d{2}\.\s*\d{1,2}\.\s*\d{1,2}\.')
    $hasMainSection = $content -match '(?m)^(?:##\s*)?주요 언론보도\s*$'
    $hasArticleList = ($content -match '(?m)^■\s+.+\s+-\s+.+$') -or ($content -match '확인된 유의미 기사 없음')
    return ($hasTitle -and $hasMainSection -and $hasArticleList)
}

function Get-GeneratedReportMarkdown {
    param([string[]]$SearchDirs)

    foreach ($searchDir in $SearchDirs) {
        if (-not (Test-Path $searchDir)) {
            continue
        }

        $candidate = Get-ChildItem -Path $searchDir -Recurse -Filter "*.md" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Where-Object { Test-IsMarkdownReport -Path $_.FullName } |
            Select-Object -First 1

        if ($candidate) {
            return $candidate
        }
    }

    return $null
}

function Set-GitBashEnvironment {
    $candidatePaths = @(
        $env:OMO_CODEX_GIT_BASH_PATH,
        "C:\Program Files\Git\bin\bash.exe",
        "C:\Program Files\Git\usr\bin\bash.exe"
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    $gitBash = $candidatePaths |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1

    if (-not $gitBash) {
        return $null
    }

    $gitPathDirs = @(
        "C:\Program Files\Git\bin",
        "C:\Program Files\Git\usr\bin"
    ) | Where-Object { Test-Path -LiteralPath $_ }

    $env:OMO_CODEX_GIT_BASH_PATH = $gitBash
    $currentPathParts = @($env:PATH -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $remainingPathParts = $currentPathParts | Where-Object {
        $pathPart = $_
        -not ($gitPathDirs | Where-Object { [string]::Equals($_, $pathPart, [System.StringComparison]::OrdinalIgnoreCase) })
    }
    $env:PATH = @($gitPathDirs + $remainingPathParts) -join ';'

    return $gitBash
}

function Get-RunFailureCategory {
    param(
        [int]$ExitCode,
        [string]$StdErrPath
    )

    $stderrText = ""
    if (Test-Path $StdErrPath) {
        $stderrText = Get-Content -Path $StdErrPath -Raw -Encoding UTF8
    }

    if ($stderrText -match "알려진 호스트가 없습니다|dns error|responses_websocket|stream disconnected before completion") {
        return "network"
    }

    if ($stderrText -match "mcp: .* failed|MCP startup failed") {
        return "mcp"
    }

    if ($ExitCode -ne 0) {
        return "codex_exit"
    }

    return "output_validation"
}

function Get-RunFailureSummary {
    param(
        [string]$Category,
        [int]$ExitCode,
        [string]$StdErrPath
    )

    $detail = switch ($Category) {
        "network" { "네트워크 또는 DNS 연결 실패" }
        "mcp" { "MCP 시작 실패" }
        "timeout" { "Codex 실행 시간 제한 초과" }
        "codex_exit" { "Codex 비정상 종료" }
        default { "결과물 검증 실패" }
    }

    $lastErrorLine = ""
    if (Test-Path $StdErrPath) {
        $lastErrorLine = Get-Content -Path $StdErrPath -Encoding UTF8 |
            Where-Object { $_ -match "ERROR|error|Warning|warning|failed|실패|알려진 호스트" } |
            Select-Object -Last 1
    }

    if ($lastErrorLine) {
        return ("{0} (exit code: {1}) | {2}" -f $detail, $ExitCode, $lastErrorLine.Trim())
    }

    return ("{0} (exit code: {1})" -f $detail, $ExitCode)
}

$reportDate = $ReportDate.Date
$reportDateStamp = $reportDate.ToString("yyyyMMdd")
$reportDateDisplay = $reportDate.ToString("yyyy-MM-dd")
$windowStart = (Get-PreviousBusinessDay -Date $reportDate).Date.AddHours(7)
$windowEnd = $reportDate.Date.AddHours(7)
$windowStartDisplay = $windowStart.ToString("yyyy-MM-dd HH:mm")
$windowEndDisplay = $windowEnd.ToString("yyyy-MM-dd HH:mm")
$folderName = "인천교육청 언론보도 현황($reportDateStamp)"
$reportDir = Join-Path $BasePath $folderName
$markdownPath = Join-Path $reportDir "인천교육청 언론보도 현황.md"
$htmlPath = Join-Path $reportDir "인천교육청 언론보도 현황.html"
$logPath = Join-Path $reportDir "run.log"
$runStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$codexWorkRoot = Join-Path ([System.IO.Path]::GetTempPath()) "DailyNewsPickerCodexWork"
$codexWorkDir = Join-Path $codexWorkRoot $runStamp

if (-not (Test-Path $BasePath)) {
    New-Item -ItemType Directory -Force -Path $BasePath | Out-Null
}

if (-not (Test-IsBusinessDay -Date $reportDate) -and -not $Force) {
    Write-Log "주말 또는 공휴일입니다. 기본 규칙에 따라 생성을 건너뜁니다."
    exit 0
}

if ((Test-Path $markdownPath) -and (Test-Path $htmlPath) -and -not $Force) {
    Write-Log "이미 오늘 결과가 존재합니다: $reportDir"
    exit 0
}

New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
New-Item -ItemType Directory -Force -Path $codexWorkDir | Out-Null

$prompt = @"
Use `$daily-news-picker at C:\Users\홍주형\.codex\skills\daily-news-picker\SKILL.md.

This run is an automated report generation job, not a conversation.
Collect and rank today's news about 인천교육청 and produce the final report immediately.
The runner will save your final Markdown to disk. Treat the skill's file-save step as already delegated to the runner.

Apply these rules:
- Report date: $reportDateDisplay
- Check window: $windowStartDisplay ~ $windowEndDisplay Asia/Seoul
- Use this exact check window. Do not reinterpret the report date as the article date or move the window to the following day.
- Scope: Incheon Metropolitan Office of Education, district offices of education, and affiliated institutions
- Use original external media article links first; do not use `ice.go.kr` press releases as representative selected article links when an accessible media article exists
- Treat user-provided/reference outlet links as monitored media sources
- Run monitored outlet domain checks from media-sources.md, especially if candidate count is low
- Do not conclude that coverage is sparse until the monitored outlet domain roster has been checked
- Use education office homepage notices and press releases only for fact-checking or last-resort fallback, and label fallback official items clearly
- This is a full daily press-coverage status list, not a top-5 briefing. Include every verified relevant article in the requested window.
- Ranking controls output order only. Do not omit relevant lower-priority routine items, affiliated-institution items, library items, school-level items, or local issue articles solely because they are not top priority.
- If several outlets carry materially the same story, keep one representative external media article for that same event, but do not merge separate issues or institutions.
- In the main list, use this sharing format for each item: `■ article title - outlet` followed by the URL on the next line.
- If no meaningful article is found, still produce the full report structure and say `확인된 유의미 기사 없음`
- Do not ask follow-up questions
- Do not explain the workflow
- Do not mention that this is a weekend, holiday, or skipped schedule
- Do not output conversational text before or after the report
- Do not call apply_patch or any filesystem-write tool
- Do not create, edit, or propose files inside the Codex work directory
- Do not output diffs, patches, tool logs, or save confirmations

Write the final answer in Korean as a complete Markdown report ready to save directly to disk.
The first line must be `# 인천교육청 언론보도 현황`.
Output only the final report body.
"@

$promptPath = Join-Path $reportDir "prompt.txt"
Set-Content -Path $promptPath -Value $prompt -Encoding UTF8

if ($DryRun) {
    Write-Log "DryRun 모드입니다."
    Write-Log "저장 폴더: $reportDir"
    Write-Log "Markdown: $markdownPath"
    Write-Log "HTML: $htmlPath"
    Write-Log "Prompt: $promptPath"
    exit 0
}

$argList = @(
    "--search",
    "exec",
    "--skip-git-repo-check",
    "-C", $codexWorkDir,
    "-m", $Model,
    "-o", $markdownPath,
    $prompt
)

$stdoutPath = Join-Path $reportDir "codex.stdout.log"
$stderrPath = Join-Path $reportDir "codex.stderr.log"
$generatedMarkdown = $null
$generatedHtml = $null
$process = $null
$timedOut = $false

Write-RunLog -Path $logPath -Message "STATUS: STARTED"
Write-RunLog -Path $logPath -Message ("설정: model={0}, bypass={1}, output={2}, codexWorkDir={3}, timeoutSeconds={4}" -f $Model, $DangerouslyBypassApprovalsAndSandbox.IsPresent, $reportDir, $codexWorkDir, $CodexTimeoutSeconds)

$gitBashPath = Set-GitBashEnvironment
if ($gitBashPath) {
    Write-RunLog -Path $logPath -Message ("Git Bash 경로 고정: {0}" -f $gitBashPath)
} else {
    Write-RunLog -Path $logPath -Message "Git Bash 경로를 찾지 못했습니다. 현재 PATH를 그대로 사용합니다."
}

if ($DangerouslyBypassApprovalsAndSandbox) {
    $argList = @("--dangerously-bypass-approvals-and-sandbox") + $argList
}

try {
    $quotedArgs = $argList | ForEach-Object {
        if ($_ -match '\s|"') {
            '"' + ($_ -replace '"', '\"') + '"'
        } else {
            $_
        }
    }
    $argumentString = [string]::Join(' ', $quotedArgs)

    $reportReady = $false
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-RunLog -Path $logPath -Message ("Codex 실행을 시작합니다. (시도 {0}/{1})" -f $attempt, $MaxAttempts)
        $timedOut = $false
        $process = Start-Process -FilePath $CodexCommand -ArgumentList $argumentString -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru -NoNewWindow
        if (-not $process.WaitForExit($CodexTimeoutSeconds * 1000)) {
            $timedOut = $true
            try {
                $process.Kill($true)
            } catch {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            }
            throw "Codex 실행 시간 제한 초과"
        }

        if (Test-Path $stdoutPath) {
            Get-Content $stdoutPath | Add-Content -Path $logPath
        }
        if (Test-Path $stderrPath) {
            Get-Content $stderrPath | Add-Content -Path $logPath
        }

        $generatedMarkdown = Get-PreferredGeneratedFile -SearchDir $reportDir -Pattern "*_$reportDateStamp.md"
        $generatedHtml = Get-PreferredGeneratedFile -SearchDir $reportDir -Pattern "*_$reportDateStamp.html"

        if ($generatedMarkdown -and $generatedMarkdown.FullName -ne $markdownPath) {
            Copy-Item -Path $generatedMarkdown.FullName -Destination $markdownPath -Force
        }

        if ($generatedHtml -and $generatedHtml.FullName -ne $htmlPath) {
            Copy-Item -Path $generatedHtml.FullName -Destination $htmlPath -Force
        }

        if (Test-NonEmptyFile -Path $markdownPath) {
            Repair-MarkdownReport -Path $markdownPath
        }

        if (-not (Test-IsMarkdownReport -Path $markdownPath)) {
            $generatedReportMarkdown = Get-GeneratedReportMarkdown -SearchDirs @($reportDir, $codexWorkDir)
            if ($generatedReportMarkdown -and $generatedReportMarkdown.FullName -ne $markdownPath) {
                Copy-Item -Path $generatedReportMarkdown.FullName -Destination $markdownPath -Force
            }
        }

        if (Test-NonEmptyFile -Path $markdownPath) {
            Repair-MarkdownReport -Path $markdownPath
        }

        if (($process.ExitCode -eq 0) -and (Test-IsMarkdownReport -Path $markdownPath)) {
            $reportReady = $true
            break
        }

        if ($attempt -lt $MaxAttempts) {
            $retryReason = if ($process.ExitCode -ne 0) { "exit code $($process.ExitCode)" } else { "빈 응답 또는 보고서 형식 불충족" }
            Write-RunLog -Path $logPath -Message ("시도 {0} 실패({1}). 부분 산출물 제거 후 재시도합니다." -f $attempt, $retryReason)
            Remove-IfExists -Path $markdownPath
            Remove-IfExists -Path $htmlPath
            if ($generatedMarkdown) { Remove-IfExists -Path $generatedMarkdown.FullName }
            if ($generatedHtml) { Remove-IfExists -Path $generatedHtml.FullName }
            Start-Sleep -Seconds 15
        }
    }

    if (-not $reportReady) {
        if ($process -and $process.ExitCode -ne 0) {
            throw "Codex 실행 실패"
        }
        if (-not (Test-NonEmptyFile -Path $markdownPath)) {
            throw "Markdown 결과가 비어 있거나 생성되지 않았습니다."
        }
        throw "Markdown 결과가 보고서 본문 형식이 아닙니다."
    }

    Convert-MarkdownToHtmlDocument -MarkdownPath $markdownPath -HtmlPath $htmlPath -Title $folderName

    if (-not (Test-NonEmptyFile -Path $htmlPath)) {
        throw "HTML 결과가 비어 있거나 생성되지 않았습니다."
    }

    Write-RunLog -Path $logPath -Message "STATUS: SUCCEEDED"
    Write-RunLog -Path $logPath -Message "생성 완료: $reportDir"
}
catch {
    $exitCode = if ($timedOut) { 124 } elseif ($process) { $process.ExitCode } else { -1 }
    $category = if ($timedOut) { "timeout" } else { Get-RunFailureCategory -ExitCode $exitCode -StdErrPath $stderrPath }
    $summary = Get-RunFailureSummary -Category $category -ExitCode $exitCode -StdErrPath $stderrPath

    Remove-IfExists -Path $markdownPath
    Remove-IfExists -Path $htmlPath
    if ($generatedMarkdown) {
        Remove-IfExists -Path $generatedMarkdown.FullName
    }
    if ($generatedHtml) {
        Remove-IfExists -Path $generatedHtml.FullName
    }

    Write-RunLog -Path $logPath -Message ("STATUS: FAILED [{0}]" -f $category.ToUpperInvariant())
    Write-RunLog -Path $logPath -Message ("원인: {0}" -f $summary)
    throw "{0}. 로그: {1}" -f $summary, $logPath
}
finally {
    Remove-IfExists -Path $stdoutPath
    Remove-IfExists -Path $stderrPath
}
