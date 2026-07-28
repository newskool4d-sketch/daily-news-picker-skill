param(
    [string]$BasePath = $env:DAILY_NEWS_OUTPUT_DIR,
    [string]$WorkingRoot = $env:USERPROFILE,
    [string]$CodexCommand = $(if (Test-Path (Join-Path $env:APPDATA "npm\codex.cmd")) { Join-Path $env:APPDATA "npm\codex.cmd" } else { "codex" }),
    [string]$Model = "gpt-5.5",
    [string]$PythonCommand = "python",
    [timespan]$CollectionTime = ([timespan]"05:00"),
    [int]$CollectorTimeoutSeconds = 600,
    [int]$CodexTimeoutSeconds = 1800,
    [int]$MaxAttempts = 2,
    [datetime]$ReportDate = (Get-Date).Date,
    [switch]$DangerouslyBypassApprovalsAndSandbox,
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# 파일 쓰기 표준: UTF-8 무BOM (C-1 인코딩 정책, codex-cleanup-plan 2026-07-05)
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if ([string]::IsNullOrWhiteSpace($BasePath)) {
    throw "BasePath가 비어 있습니다. -BasePath를 지정하거나 DAILY_NEWS_OUTPUT_DIR 환경변수를 설정하세요."
}

if ($CollectionTime -lt [timespan]::Zero -or $CollectionTime -ge [timespan]::FromDays(1)) {
    throw "CollectionTime은 00:00 이상 24:00 미만이어야 합니다: $CollectionTime"
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
        [System.IO.File]::AppendAllText($Path, $line + [Environment]::NewLine, $script:Utf8NoBom)
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

    # 캐시 TTL 7일: 법 개정으로 공휴일이 바뀔 수 있다 (실사례: 2026-05-11 시행 개정으로
    # 제헌절 공휴일 재지정 — 무기한 캐시 탓에 2026-07-17 공휴일 실행 사고 발생)
    $cachePath = Get-HolidayCachePath -Year $Year
    $cacheFresh = $false
    if (Test-Path $cachePath) {
        $cacheAgeDays = ((Get-Date) - (Get-Item $cachePath).LastWriteTime).TotalDays
        $cacheFresh = ($cacheAgeDays -lt 7)
    }

    if ($cacheFresh) {
        try {
            return (Get-Content $cachePath -Raw | ConvertFrom-Json)
        } catch {
            Write-Log "휴일 캐시 파싱 실패. 다시 조회합니다."
        }
    }

    $url = "https://date.nager.at/api/v3/PublicHolidays/$Year/KR"
    try {
        $response = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 20
        [System.IO.File]::WriteAllText($cachePath, ($response | ConvertTo-Json -Depth 5), $script:Utf8NoBom)
        return $response
    } catch {
        if (Test-Path $cachePath) {
            Write-Log "공휴일 API 조회 실패. 만료된 캐시로 대체합니다."
            try {
                return (Get-Content $cachePath -Raw | ConvertFrom-Json)
            } catch {
                Write-Log "만료 캐시 파싱도 실패했습니다."
            }
        }
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

    # The markdown body is built from external news-article titles/links, so it
    # is untrusted input. ConvertFrom-Markdown (markdig) passes raw inline HTML
    # through unescaped, which would let a malicious article title execute
    # script in the generated briefing. Always HTML-encode first and only
    # re-introduce structural markup (headings/lists/links) via regex on the
    # already-encoded text, so no raw tag from the source can survive.
    $escaped = [System.Net.WebUtility]::HtmlEncode($markdown)
    $escaped = $escaped -replace '(?m)^### (.+)$', '<h3>$1</h3>'
    $escaped = $escaped -replace '(?m)^## (.+)$', '<h2>$1</h2>'
    $escaped = $escaped -replace '(?m)^# (.+)$', '<h1>$1</h1>'
    $escaped = $escaped -replace '(?m)^- (.+)$', '<li>$1</li>'
    $escaped = $escaped -replace '(<li>.*</li>(\r?\n)?)+', { param($m) "<ul>`n$($m.Value)</ul>`n" }
    # Only turn [text](url) into a real link when the URL is http(s); anything
    # else (javascript:, data:, etc.) is left as plain encoded text.
    $escaped = $escaped -replace '\[(.+?)\]\((https?://[^\s")]+)\)', '<a href="$2" rel="noopener noreferrer">$1</a>'
    $escaped = $escaped -replace "(`r`n|`n){2,}", "</p><p>"
    $body = "<p>$escaped</p>"

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

    [System.IO.File]::WriteAllText($HtmlPath, $html, $script:Utf8NoBom)
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
    [System.IO.File]::WriteAllText($Path, $normalized + [Environment]::NewLine, $script:Utf8NoBom)
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
    $hasExpectedWindowStart = $content -match [regex]::Escape($windowStartDisplay)
    $hasExpectedWindowEnd = $content -match [regex]::Escape($windowEndDisplay)
    return ($hasTitle -and $hasMainSection -and $hasArticleList -and $hasExpectedWindowStart -and $hasExpectedWindowEnd)
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
$windowStart = (Get-PreviousBusinessDay -Date $reportDate).Date.Add($CollectionTime)
$windowEnd = $reportDate.Date.Add($CollectionTime)
$windowStartDisplay = $windowStart.ToString("yyyy-MM-dd HH:mm")
$windowEndDisplay = $windowEnd.ToString("yyyy-MM-dd HH:mm")
$folderName = "인천교육청 언론보도 현황($reportDateStamp)"
$reportDir = Join-Path $BasePath $folderName
$markdownPath = Join-Path $reportDir "인천교육청 언론보도 현황.md"
$htmlPath = Join-Path $reportDir "인천교육청 언론보도 현황.html"
$persistedCollectedJsonPath = Join-Path $reportDir "collected_articles.json"
$logPath = Join-Path $reportDir "run.log"
$codexWorkRoot = Join-Path ([System.IO.Path]::GetTempPath()) "DailyNewsPickerCodexWork"
# 고정 작업 폴더: 날짜별 폴더는 Codex 신뢰 목록([projects])에 매일 1건씩 쌓여 샌드박스 ACL 갱신을 비대화시킴
$codexWorkDir = Join-Path $codexWorkRoot "current"

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
# 고정 폴더 재사용: 이전 실행 산출물이 이번 실행 결과로 오인되지 않도록 제거
Remove-Item -Path (Join-Path $codexWorkDir "last-message.md") -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $codexWorkDir "collected_articles.json") -Force -ErrorAction SilentlyContinue

$prompt = @"
Use `$daily-news-picker at C:\Users\홍주형\.codex\skills\daily-news-picker\SKILL.md.

This run is an automated report generation job, not a conversation.
Collect and rank today's news about 인천교육청 and produce the final report immediately.
The runner will save your final Markdown to disk. Treat the skill's file-save step as already delegated to the runner.
This is an existing user-approved scheduled task. The current run is authorized within this narrow scope: read web sources and return the report body without pausing for confirmation.

Apply these rules:
- Report date: $reportDateDisplay
- Check window: $windowStartDisplay ~ $windowEndDisplay Asia/Seoul
- Use this exact check window. Do not reinterpret the report date as the article date or move the window to the following day.
- Exclude any article published or updated after $windowEndDisplay. The verification memo must repeat exactly $windowStartDisplay through $windowEndDisplay, not the actual collection finish time.
- Scope: Incheon Metropolitan Office of Education, district offices of education, affiliated institutions, Incheon schools, and students who are clearly tied to Incheon
- For school/student stories, require both an education subject (school, student, teacher, parent, or education institution) and concrete Incheon evidence
- Accept concrete Incheon evidence from an exact official Incheon school name; wording such as `인천 관내`, `인천의`, `인천에 있는`, or `인천 소재`; an official Incheon gun/gu name; or a verified Incheon locality such as 송도 or 청라
- Official 2026-07-01 gun/gu names are 강화군, 옹진군, 제물포구, 영종구, 미추홀구, 연수구, 남동구, 부평구, 계양구, 서해구, and 검단구
- Treat locality-only names as evidence to verify, not automatic inclusion. Confirm an exact school, address, or explicit Incheon relationship in the article body
- Student competition awards, prizes, inventions, scholarships, good deeds, rescue, volunteering, and other positive stories are valid coverage when the student's Incheon tie is confirmed
- A regional incident or business story is not education coverage merely because `인천` appears. Exclude it when no education office, school, student, teacher, parent, education facility, or direct school impact is central to the article
- Apply the incident rule article by article: a commercial compensation story can be excluded while a separate article about education-office response, school evacuation/shelter use, student safety, or school operation impact can be included
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
[System.IO.File]::WriteAllText($promptPath, $prompt, $script:Utf8NoBom)

if ($DryRun) {
    Write-Log "DryRun 모드입니다."
    Write-Log "저장 폴더: $reportDir"
    Write-Log "Markdown: $markdownPath"
    Write-Log "HTML: $htmlPath"
    Write-Log "Prompt: $promptPath"
    Write-Log "1차 수집기: $(Join-Path $PSScriptRoot 'collect_news_rss.py') (DryRun에서는 실행하지 않음)"
    exit 0
}

# ---- 1차 수집: Google News RSS(+네이버 API 보강) 수집기 ----
# 성공 시 후보 풀 JSON을 Codex 작업 폴더에 두고 프롬프트로 안내한다.
# 실패·시간초과·0건이면 기존 방식(Codex 자체 검색)으로 폴백한다.
$collectedJsonPath = Join-Path $codexWorkDir "collected_articles.json"
$collectorPath = Join-Path $PSScriptRoot "collect_news_rss.py"
$collectorUsed = $false
$collectorCount = 0
if (Test-Path $collectorPath) {
    Write-RunLog -Path $logPath -Message "1차 수집기 실행: Google News RSS(+네이버 보강)"
    $collectorStdout = Join-Path $reportDir "collector.stdout.log"
    $collectorStderr = Join-Path $reportDir "collector.stderr.log"
    $prevPyEnc = $env:PYTHONIOENCODING
    $env:PYTHONIOENCODING = "utf-8"
    try {
        $collectorArgs = @($collectorPath, "--start", $windowStartDisplay, "--end", $windowEndDisplay, "--out-dir", $codexWorkDir)
        $quotedCollectorArgs = $collectorArgs | ForEach-Object {
            if ($_ -match '\s|"') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
        }
        $collectorProcess = Start-Process -FilePath $PythonCommand -ArgumentList ([string]::Join(' ', $quotedCollectorArgs)) -RedirectStandardOutput $collectorStdout -RedirectStandardError $collectorStderr -PassThru -NoNewWindow
        if (-not $collectorProcess.WaitForExit($CollectorTimeoutSeconds * 1000)) {
            try { $collectorProcess.Kill($true) } catch { Stop-Process -Id $collectorProcess.Id -Force -ErrorAction SilentlyContinue }
            try {
                if ($collectorProcess.WaitForExit(5000)) {
                    # Start-Process 리디렉션 파일 핸들이 닫힐 때까지 완료 대기
                    $collectorProcess.WaitForExit()
                }
            } catch {
                # 수집기 종료 확인 실패가 Codex 폴백을 막지 않도록 한다.
            }
            Write-RunLog -Path $logPath -Message "수집기 시간 초과 — Codex 자체 검색으로 폴백합니다."
        } elseif ($collectorProcess.ExitCode -ne 0) {
            Write-RunLog -Path $logPath -Message ("수집기 실패(exit {0}) — Codex 자체 검색으로 폴백합니다." -f $collectorProcess.ExitCode)
        } elseif (Test-NonEmptyFile -Path $collectedJsonPath) {
            $pool = Get-Content -Path $collectedJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($pool.article_count -ge 1) {
                $collectorUsed = $true
                $collectorCount = $pool.article_count
                Copy-Item -Path $collectedJsonPath -Destination $persistedCollectedJsonPath -Force
                Write-RunLog -Path $logPath -Message ("1차 수집 완료: {0}건 (수집 실패 쿼리 {1}건)" -f $pool.article_count, @($pool.failures).Count)
            } else {
                Write-RunLog -Path $logPath -Message "1차 수집 0건 — Codex 자체 검색으로 폴백합니다."
            }
        } else {
            Write-RunLog -Path $logPath -Message "수집 결과 파일이 없습니다 — Codex 자체 검색으로 폴백합니다."
        }
    } catch {
        Write-RunLog -Path $logPath -Message ("수집기 실행 오류: {0} — Codex 자체 검색으로 폴백합니다." -f $_.Exception.Message)
    } finally {
        $env:PYTHONIOENCODING = $prevPyEnc
        foreach ($tempLog in @($collectorStdout, $collectorStderr)) {
            if (Test-Path $tempLog) {
                try {
                    $tempLogText = [System.IO.File]::ReadAllText($tempLog, [System.Text.Encoding]::UTF8)
                    if ($tempLogText) {
                        [System.IO.File]::AppendAllText($logPath, $tempLogText, $script:Utf8NoBom)
                    }
                } catch {
                    Write-RunLog -Path $logPath -Message ("수집기 임시 로그 읽기 실패(비치명): {0}" -f $_.Exception.Message)
                } finally {
                    Remove-Item -Path $tempLog -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
} else {
    Write-RunLog -Path $logPath -Message "수집기 스크립트가 없습니다 — Codex 자체 검색으로 진행합니다."
}

if (-not $collectorUsed) {
    Remove-Item -Path $collectedJsonPath -Force -ErrorAction SilentlyContinue
} else {
    $prompt += @"

Pre-collected candidate pool: your working directory contains ``collected_articles.json`` with $collectorCount candidate articles,
produced by the skill's deterministic collector (Google News RSS primary + Naver API supplement) for exactly the check window above,
with original media URLs already resolved.
- Use it as the primary candidate pool. Do not redo broad first-pass collection from scratch.
- Verify the relevance of every entry before including it. Entries with ``"engine": "naver-api"`` are unfiltered keyword matches and require an explicit relevance check.
- Use ``relevance_hint`` only as triage metadata, never as the final decision. ``likely_irrelevant`` means the title has an Incheon location or clear commercial context but no education subject; exclude it unless the full article proves a direct education relationship. ``needs_review`` preserves exact school names and low-context titles for body verification.
- Check the ``relevance_reasons``, ``location_hits``, ``education_subject_hits``, and ``student_story_hits`` fields and state a concrete inclusion relationship in your reasoning before selecting school/student items.
- Check the ``failures`` field: queries listed there may be under-collected, so supplement those specific queries with targeted searches per the skill's recipes.
- Still apply the skill's selection, deduplication, ranking, verification, and output rules to the pool.
"@
    [System.IO.File]::WriteAllText($promptPath, $prompt, $script:Utf8NoBom)
}

# 프롬프트는 argv가 아니라 stdin으로 전달한다 ("-" = stdin 읽기).
# argv 전달 시 npm .cmd 셔틀(cmd.exe)이 개행에서 프롬프트를 끊어 첫 줄만 도달하는
# 사고가 있었다 (2026-07-14~17 실측: 4개 실행 모두 'Apply these rules' 미전달 확인).
$argList = @(
    "--search",
    "exec",
    "--skip-git-repo-check",
    "-s", "read-only",
    "-C", $codexWorkDir,
    "-m", $Model,
    "-o", (Join-Path $codexWorkDir "last-message.md"),
    "-"
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
        $process = Start-Process -FilePath $CodexCommand -ArgumentList $argumentString -RedirectStandardInput $promptPath -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru -NoNewWindow
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
            [System.IO.File]::AppendAllText($logPath, [System.IO.File]::ReadAllText($stdoutPath, [System.Text.Encoding]::UTF8), $script:Utf8NoBom)
        }
        if (Test-Path $stderrPath) {
            [System.IO.File]::AppendAllText($logPath, [System.IO.File]::ReadAllText($stderrPath, [System.Text.Encoding]::UTF8), $script:Utf8NoBom)
        }

        $lastMessagePath = Join-Path $codexWorkDir "last-message.md"
        $generatedMarkdown = if (Test-NonEmptyFile -Path $lastMessagePath) { Get-Item -LiteralPath $lastMessagePath } else { $null }
        $generatedHtml = $null

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
            if ($generatedMarkdown -and $generatedMarkdown.FullName -ne $lastMessagePath) { Remove-IfExists -Path $generatedMarkdown.FullName }
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

    # ---- 하류 자동 인제스트 (edu-news-organizer) — 실패해도 브리핑 성공에는 영향 없음 ----
    $organizerScript = Join-Path $env:USERPROFILE ".codex\skills\edu-news-organizer\scripts\newsdb.py"
    if (Test-Path $organizerScript) {
        $ingestLog = Join-Path $reportDir "organizer-ingest.log"
        Remove-IfExists -Path $ingestLog
        try {
            $env:PYTHONIOENCODING = "utf-8"
            # 7/23 운영 방식 유지: 선별본을 먼저 넣어 selected 표시를 보존한 뒤
            # 전체 후보 JSON도 넣어 수집 기사 집합과 동일보도 묶음을 유지한다.
            & $PythonCommand $organizerScript ingest --briefing $markdownPath *>> $ingestLog
            $ingestJsonPath = if (Test-NonEmptyFile -Path $collectedJsonPath) {
                $collectedJsonPath
            } elseif ($collectorUsed -and (Test-NonEmptyFile -Path $persistedCollectedJsonPath)) {
                $persistedCollectedJsonPath
            } else {
                $null
            }
            if ($ingestJsonPath) {
                & $PythonCommand $organizerScript ingest --json $ingestJsonPath *>> $ingestLog
            }
            & $PythonCommand $organizerScript group --date $reportDateDisplay *>> $ingestLog
            # 프리미엄 HTML 다이제스트를 보고 폴더에 함께 생성 (브리핑과 나란히)
            $digestHtmlPath = Join-Path $reportDir "교육뉴스 다이제스트.html"
            & $PythonCommand $organizerScript digest --date $reportDateDisplay --format html --out $digestHtmlPath *>> $ingestLog
            Write-RunLog -Path $logPath -Message "하류 인제스트·다이제스트 완료 (edu-news-organizer → organizer-ingest.log, 교육뉴스 다이제스트.html)"

            # 정적 사이트 배포(A안): EDU_NEWS_SITE_DIR가 설정된 경우에만 공개 안전본을 굽고 git push
            # (개인 데이터 제외·비공식 표기 — publish_site.py가 --public 렌더). 미설정 시 조용히 생략.
            if ($env:EDU_NEWS_SITE_DIR) {
                $publishScript = Join-Path $env:USERPROFILE ".codex\skills\edu-news-organizer\scripts\publish_site.py"
                $pushFlag = if ($env:EDU_NEWS_SITE_PUSH -eq "1") { "--push" } else { "" }
                $prevPythonUtf8 = $env:PYTHONUTF8
                try {
                    $env:PYTHONUTF8 = "1"
                    & $PythonCommand $publishScript --site-dir $env:EDU_NEWS_SITE_DIR --date $reportDateDisplay $pushFlag *>> $ingestLog
                } finally {
                    $env:PYTHONUTF8 = $prevPythonUtf8
                }
                Write-RunLog -Path $logPath -Message ("정적 사이트 배포 완료 (공개 안전본 → {0}, push={1})" -f $env:EDU_NEWS_SITE_DIR, ($env:EDU_NEWS_SITE_PUSH -eq "1"))
            }
        } catch {
            Write-RunLog -Path $logPath -Message ("하류 인제스트 실패(비치명): {0}" -f $_.Exception.Message)
        }
    }
}
catch {
    $exitCode = if ($timedOut) { 124 } elseif ($process) { $process.ExitCode } else { -1 }
    $category = if ($timedOut) { "timeout" } else { Get-RunFailureCategory -ExitCode $exitCode -StdErrPath $stderrPath }
    $summary = Get-RunFailureSummary -Category $category -ExitCode $exitCode -StdErrPath $stderrPath

    Remove-IfExists -Path $markdownPath
    Remove-IfExists -Path $htmlPath
    Remove-IfExists -Path $persistedCollectedJsonPath
    if ($generatedMarkdown -and $generatedMarkdown.FullName -ne $lastMessagePath) {
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
