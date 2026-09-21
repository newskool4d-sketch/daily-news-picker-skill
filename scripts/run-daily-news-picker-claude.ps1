param(
    [string]$BasePath = $env:DAILY_NEWS_OUTPUT_DIR,
    [string]$WorkingRoot = $env:USERPROFILE,
    [string]$ClaudeCommand = $(if ($env:CLAUDE_CODEX_CLAUDE_BIN) { $env:CLAUDE_CODEX_CLAUDE_BIN } else { "claude" }),
    [string]$Model = "sonnet",
    [string]$PythonCommand = "python",
    [string]$SiteDir = $env:EDU_NEWS_SITE_DIR,
    [bool]$EnablePublicPush = ($env:EDU_NEWS_SITE_PUSH -eq "1"),
    [timespan]$CollectionTime = ([timespan]"09:00"),
    [int]$CollectorTimeoutSeconds = 600,
    [int]$ClaudeTimeoutSeconds = 1800,
    [int]$MaxAttempts = 2,
    [datetime]$ReportDate = (Get-Date).Date,
    [string]$ValidateReportPath,
    [string]$ValidationHtmlOutputPath,
    [switch]$Force,
    [switch]$DryRun,
    [switch]$SkipDownstream
)

# 2026-08-21 Codex(gpt-5.6-sol) -> Claude 예약작업 이관 초안.
# 원본: run-daily-news-picker.ps1 (Codex exec 엔진). 6단계 파이프라인 중 3단계(검증·랭킹·작성)의
# 엔진만 교체했다 — 공휴일 계산, RSS 1차 수집, Markdown 검증/복구, 후보 승격, 하류 DB/사이트 배포는
# 원본과 동일 로직을 그대로 사용한다.
# 변경 요지:
#  - codex exec(-s read-only, -m gpt-5.6-sol) -> claude -p --model sonnet
#  - 쓰기 차단을 샌드박스 플래그가 아니라 --allowedTools 화이트리스트(Read/Glob/Grep/WebSearch/WebFetch)로
#    구조적으로 강제 — Edit/Write/Bash 자체가 도구 목록에 없어 "쓰기 금지" 프롬프트 지시보다 강함.
#  - 무인 실행이므로 --permission-mode bypassPermissions로 승인 프롬프트 자체를 없앤다(위 화이트리스트와 결합).
#  - CollectionTime 기본값 09:00 (사용자 지시로 05:00 -> 09:00 변경, 2026-08-21).
#  - 실패 시에도 run.log/claude.stderr.log를 보존한다(원본은 finally에서 항상 삭제 — 2026-08-21 자동 실행
#    실패 원인 조사 시 로그가 이미 지워져 있어 원인 규명이 불가능했던 문제의 재발 방지).
# 아직 하지 않은 것: Windows Task Scheduler 액션 교체, SKILL.md/register 스크립트 수정, 실사용 커밋·푸시.
# 이 스크립트는 초안이며 -DryRun / 수동 1회 실행으로 검증 후 사용자 승인을 받아 스케줄러에 등록한다.

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if ([string]::IsNullOrWhiteSpace($BasePath)) {
    throw "BasePath가 비어 있습니다. -BasePath를 지정하거나 DAILY_NEWS_OUTPUT_DIR 환경변수를 설정하세요."
}

if ($EnablePublicPush -and [string]::IsNullOrWhiteSpace($SiteDir)) {
    throw "공개 배포를 켜려면 -SiteDir를 지정하거나 EDU_NEWS_SITE_DIR 환경변수를 설정하세요."
}

$env:EDU_NEWS_SITE_DIR = $SiteDir
$env:EDU_NEWS_SITE_PUSH = if ($EnablePublicPush) { "1" } else { "0" }

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

function Invoke-LoggedNativeCommand {
    param(
        [string]$Step,
        [string]$Command,
        [string[]]$Arguments,
        [string]$LogPath
    )

    & $Command @Arguments *>> $LogPath
    $nativeExitCode = $LASTEXITCODE
    if ($nativeExitCode -ne 0) {
        throw ("{0} 실패(exit {1}) — {2} 확인" -f $Step, $nativeExitCode, $LogPath)
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

    $escaped = [System.Net.WebUtility]::HtmlEncode($markdown)
    $escaped = $escaped -replace '(?m)^### (.+)$', '<h3>$1</h3>'
    $escaped = $escaped -replace '(?m)^## (.+)$', '<h2>$1</h2>'
    $escaped = $escaped -replace '(?m)^# (.+)$', '<h1>$1</h1>'
    $escaped = $escaped -replace '(?m)^- (.+)$', '<li>$1</li>'
    $escaped = $escaped -replace '(<li>.*</li>(\r?\n)?)+', { param($m) "<ul>`n$($m.Value)</ul>`n" }
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

    # Claude(-p)가 본문 앞에 "모든 검증이 끝났습니다" 류의 메타 서술이나 중복 제목을 남기는 사례가
    # 관측됨(2026-08-21 엔진 검증 실행). 제목 줄이 여러 번 나오면 마지막 등장 지점부터만 남긴다 —
    # 프롬프트 지시만으로는 100% 막히지 않아 여기서 한 번 더 방어한다.
    $titleLineMatches = [regex]::Matches($normalized, '(?m)^#\s*인천교육청 언론보도 현황\s*$')
    if ($titleLineMatches.Count -gt 1) {
        $lastTitleIndex = $titleLineMatches[$titleLineMatches.Count - 1].Index
        $normalized = $normalized.Substring($lastTitleIndex).TrimStart()
    }

    if (-not $normalized.TrimStart().StartsWith("# 인천교육청 언론보도 현황")) {
        $normalized = "# 인천교육청 언론보도 현황`r`n`r`n$normalized"
    }

    # 러너 소유 메타데이터 보정(보고일·점검 창): 하류는 모델의 정확한 표기에 의존한다 —
    #  - newsdb.py 인제스트는 `YYYY. M. D.(요일) … 주요 언론보도 현황입니다` 또는 `보고일: YYYY-MM-DD`
    #    형식의 날짜 헤더가 없으면 exit 2로 중단(2026-09-21 실측: 모델이 `- 기준일:`로 써서 하류 전체 실패)
    #  - 검증기는 windowStart/windowEnd의 정확한 문자열을 요구(2026-08-26 실측: "당일 오전 9시"로 써서 FAILED)
    # 두 값 모두 러너가 정하는 값이므로, 인식 형식이 없으면 제목 바로 아래에 정본 줄을 한 번에 삽입해
    # 하류를 결정적으로 만든다. 모델이 이미 올바르게 썼으면 아무것도 넣지 않는다.
    $headerLines = @()
    $dateHeaderPresent = $normalized -match ('(?m)^[ \t]*(?:20\d{2}\.[ \t]*\d{1,2}\.[ \t]*\d{1,2}\.[ \t]*\(.\).*주요 언론보도 현황입니다' +
        '|(?:[-*][ \t]*)?보고일[ \t]*:[ \t]*20\d{2}[ \t]*[-./][ \t]*\d{1,2}[ \t]*[-./][ \t]*\d{1,2})')
    if (-not $dateHeaderPresent) {
        $headerLines += "- 보고일: $reportDateDisplay"
    }
    if (($normalized -notmatch [regex]::Escape($windowStartDisplay)) -or
        ($normalized -notmatch [regex]::Escape($windowEndDisplay))) {
        $headerLines += "점검 창: $windowStartDisplay ~ $windowEndDisplay (Asia/Seoul)"
    }
    if ($headerLines.Count -gt 0) {
        $insertion = [string]::Join("`r`n", $headerLines)
        $normalized = [regex]::Replace(
            $normalized,
            '(?m)^(#\s*인천교육청 언론보도 현황\s*)$',
            ('$1' + "`r`n`r`n" + $insertion),
            [System.Text.RegularExpressions.RegexOptions]::None,
            [timespan]::FromSeconds(5)
        )
    }

    $normalized = [regex]::Replace($normalized, '(?m)^(핵심 요약|주요 언론보도|제외 또는 참고)\s*$', '## $1')

    if (($normalized -notmatch '(?m)^##\s+주요 언론보도\s*$') -and
        ($normalized -match '(?m)^■\s+.+\s+-\s+.+$')) {
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($line in [regex]::Split($normalized, "\r?\n")) {
            [void]$lines.Add($line)
        }

        $firstArticleIndex = -1
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -match '^■\s+.+\s+-\s+.+$') {
                $firstArticleIndex = $index
                break
            }
        }

        if ($firstArticleIndex -ge 0) {
            $reservedHeadings = @('핵심 요약', '주요 언론보도', '제외 또는 참고', '검증 메모')
            $firstCategoryHeadingIndex = -1
            for ($index = $firstArticleIndex - 1; $index -ge 0; $index--) {
                if ($lines[$index] -match '^##\s+(.+?)\s*$') {
                    $heading = $Matches[1].Trim()
                    if ($heading -notin $reservedHeadings) {
                        $firstCategoryHeadingIndex = $index
                        break
                    }
                }
            }

            $insertAt = if ($firstCategoryHeadingIndex -ge 0) { $firstCategoryHeadingIndex } else { $firstArticleIndex }
            $lines.Insert($insertAt, '')
            $lines.Insert($insertAt, '## 주요 언론보도')

            $insideMainSection = $false
            for ($index = 0; $index -lt $lines.Count; $index++) {
                if ($lines[$index] -match '^##\s+주요 언론보도\s*$') {
                    $insideMainSection = $true
                    continue
                }
                if ($insideMainSection -and $lines[$index] -match '^##\s+(.+?)\s*$') {
                    $heading = $Matches[1].Trim()
                    if ($heading -in @('핵심 요약', '제외 또는 참고', '검증 메모')) {
                        $insideMainSection = $false
                    } else {
                        $lines[$index] = "### $heading"
                    }
                }
            }

            $normalized = [string]::Join([Environment]::NewLine, $lines)
        }
    }
    [System.IO.File]::WriteAllText($Path, $normalized + [Environment]::NewLine, $script:Utf8NoBom)
}

function Get-MarkdownReportValidationFailures {
    param([string]$Path)

    if (-not (Test-NonEmptyFile -Path $Path)) {
        return @('non_empty_file')
    }

    $content = Get-Content -Path $Path -Raw -Encoding UTF8
    $trimmed = $content.TrimStart()
    $failures = [System.Collections.Generic.List[string]]::new()
    if (-not ($trimmed.StartsWith("# 인천교육청 언론보도 현황") -or ($trimmed -match '^20\d{2}\.\s*\d{1,2}\.\s*\d{1,2}\.'))) {
        [void]$failures.Add('title')
    }
    if ($content -notmatch '(?m)^(?:##\s*)?주요 언론보도\s*$') {
        [void]$failures.Add('main_section')
    }
    if (-not (($content -match '(?m)^■\s+.+\s+-\s+.+$') -or ($content -match '확인된 유의미 기사 없음'))) {
        [void]$failures.Add('article_list')
    }
    if ($content -notmatch [regex]::Escape($windowStartDisplay)) {
        [void]$failures.Add('window_start')
    }
    if ($content -notmatch [regex]::Escape($windowEndDisplay)) {
        [void]$failures.Add('window_end')
    }
    return $failures.ToArray()
}

function Test-IsMarkdownReport {
    param([string]$Path)

    return (@(Get-MarkdownReportValidationFailures -Path $Path).Count -eq 0)
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

    # 주의: 아래 네트워크/MCP 시그니처 문자열은 Codex(gpt-5.6-sol) stderr 문구에서 가져온 것으로,
    # claude.exe의 실제 오류 문구는 다를 수 있다. 실사용 실패 사례가 쌓이면 갱신할 것.
    if ($stderrText -match "알려진 호스트가 없습니다|dns error|responses_websocket|stream disconnected before completion") {
        return "network"
    }

    if ($stderrText -match "mcp: .* failed|MCP startup failed") {
        return "mcp"
    }

    if ($ExitCode -ne 0) {
        return "claude_exit"
    }

    return "output_validation"
}

function Get-RunFailureSummary {
    param(
        [string]$Category,
        [int]$ExitCode,
        [string]$StdErrPath,
        [string[]]$ValidationFailures = @()
    )

    $detail = switch ($Category) {
        "network" { "네트워크 또는 DNS 연결 실패" }
        "mcp" { "MCP 시작 실패" }
        "timeout" { "Claude 실행 시간 제한 초과" }
        "claude_exit" { "Claude 비정상 종료" }
        default { "결과물 검증 실패" }
    }

    if (($Category -eq "output_validation") -and $ValidationFailures.Count -gt 0) {
        return ("{0} (exit code: {1}) | 실패 항목: {2}" -f $detail, $ExitCode, ($ValidationFailures -join ", "))
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

if (-not [string]::IsNullOrWhiteSpace($ValidateReportPath)) {
    if (-not (Test-Path -LiteralPath $ValidateReportPath)) {
        throw "검증할 Markdown 파일이 없습니다: $ValidateReportPath"
    }
    Repair-MarkdownReport -Path $ValidateReportPath
    $validationFailures = @(Get-MarkdownReportValidationFailures -Path $ValidateReportPath)
    if ($validationFailures.Count -gt 0) {
        Write-Output ("REPORT_VALIDATION: FAIL [{0}]" -f ($validationFailures -join ','))
        exit 2
    }
    if (-not [string]::IsNullOrWhiteSpace($ValidationHtmlOutputPath)) {
        $validationHtmlParent = Split-Path -Parent $ValidationHtmlOutputPath
        if ($validationHtmlParent -and -not (Test-Path -LiteralPath $validationHtmlParent)) {
            New-Item -ItemType Directory -Force -Path $validationHtmlParent | Out-Null
        }
        Convert-MarkdownToHtmlDocument `
            -MarkdownPath $ValidateReportPath `
            -HtmlPath $ValidationHtmlOutputPath `
            -Title ("인천교육청 언론보도 현황({0})" -f $reportDateStamp)
        if (-not (Test-NonEmptyFile -Path $ValidationHtmlOutputPath)) {
            throw "검증된 Markdown의 HTML 변환 결과가 비어 있습니다: $ValidationHtmlOutputPath"
        }
        Write-Output ("REPORT_HTML: {0}" -f $ValidationHtmlOutputPath)
    }
    Write-Output "REPORT_VALIDATION: PASS"
    exit 0
}

$folderName = "인천교육청 언론보도 현황($reportDateStamp)"
$reportDir = Join-Path $BasePath $folderName
$markdownPath = Join-Path $reportDir "인천교육청 언론보도 현황.md"
$htmlPath = Join-Path $reportDir "인천교육청 언론보도 현황.html"
$persistedCollectedJsonPath = Join-Path $reportDir "collected_articles.json"
$persistedVerifiedCollectedJsonPath = Join-Path $reportDir "verified_collected_articles.json"
$verificationManifestPath = Join-Path $reportDir "verification-manifest.json"
$verificationLogPath = Join-Path $reportDir "verification-promotion.log"
$logPath = Join-Path $reportDir "run.log"
$engineWorkRoot = Join-Path ([System.IO.Path]::GetTempPath()) "DailyNewsPickerClaudeWork"
# 고정 작업 폴더: 날짜별 폴더는 신뢰 목록에 매일 1건씩 쌓여 승인/ACL 갱신을 비대화시킴
$engineWorkDir = Join-Path $engineWorkRoot "current"
$verifiedCollectedJsonPath = Join-Path $engineWorkDir "verified_collected_articles.json"

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
New-Item -ItemType Directory -Force -Path $engineWorkDir | Out-Null
Remove-Item -Path (Join-Path $engineWorkDir "last-message.md") -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $engineWorkDir "collected_articles.json") -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $engineWorkDir "verified_collected_articles.json") -Force -ErrorAction SilentlyContinue

$prompt = @"
Read the file at C:\Users\홍주형\.codex\skills\daily-news-picker\SKILL.md and follow it exactly as your
operating instructions for this run, including its linked references/institution-scope.md and
references/media-sources.md (open both before selecting or excluding any candidate).

This run is an automated report generation job, not a conversation.
Collect and rank today's news about 인천교육청 and produce the final report immediately.
The runner will save your final Markdown to disk from your printed final answer. Treat the skill's
file-save step as already delegated to the runner — you only need to print the report text.
This is an existing user-approved scheduled task. The current run is authorized within this narrow scope: read
web sources and return the report body without pausing for confirmation.

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
- For coverage led by 인천시청, a 군청·구청, or a local-government facility/foundation, require the article body to name an Incheon education office/affiliated institution as an official partner, an Incheon school as an official participant or operator, or a direct effect on school operations, safety, facilities, curriculum, or student protection
- A local-government event, welfare/care program, award, scholarship, experience, or youth-facility activity is not education-office coverage merely because children, youth, students, or parents participate. Exclude it when the institutional link above is not confirmed
- Use original external media article links first; do not use `ice.go.kr` press releases as representative selected article links when an accessible media article exists
- Treat user-provided/reference outlet links as monitored media sources
- Run monitored outlet domain checks from media-sources.md, especially if candidate count is low
- Do not conclude that coverage is sparse until the monitored outlet domain roster has been checked
- Use education office homepage notices and press releases only for fact-checking or last-resort fallback, and label fallback official items clearly
- This is a full daily press-coverage status list, not a top-5 briefing. Include every verified relevant article in the requested window.
- Ranking controls output order only. Do not omit relevant lower-priority routine items, affiliated-institution items, library items, school-level items, or local issue articles solely because they are not top priority.
- If several outlets carry materially the same story, keep one representative external media article for that same event, but do not merge separate issues or institutions.
- In the main list, use this sharing format for each item: `■ article title - outlet` followed by the URL on the next line.
- 보고서에는 "## 주요 언론보도" 헤더를 정확히 한 번 사용한다. 다른 어떤 "##" 레벨 헤더도 만들지 않는다.
- 세부 분류 제목을 사용할 경우에는 반드시 "## 주요 언론보도" 절 안에서 "###" 헤더로만 작성한다 ("##"로 쓰지 않는다).
- If no meaningful article is found, still produce the full report structure and say `확인된 유의미 기사 없음`
- Do not ask follow-up questions
- Do not explain the workflow
- Do not mention that this is a weekend, holiday, or skipped schedule
- Do not output conversational text before or after the report
- Your entire response must be the report itself and nothing else. The very first character you print must be `#`.
- The first line after the title must be exactly: - 보고일: $reportDateDisplay
  The downstream database parser keys on the literal label 보고일 with that ISO date. Never rename it (no 기준일, 날짜, 보고 기준일) and do not move it below other lines.
- Never print a transitional or meta sentence such as "모든 검증이 끝났습니다", "최종 보고서를 출력합니다", or any similar narration about what you are about to do, in Korean or English, before the title. Do not print the title line more than once and do not use a `---` separator before the report.
- Do not output diffs, patches, tool logs, or save confirmations

Write the final answer in Korean as a complete Markdown report ready to save directly to disk.
The first line must be `# 인천교육청 언론보도 현황`.
For every collector candidate that you include after checking its article body, append this exact machine-readable
block at the very end of the report (use [] when no collector candidate is verified for publication):
<!-- DAILY_NEWS_VERIFIED_CANDIDATES
[{"original_url":"https://...","verified":true,"publication_eligible":true,"verification_basis":"본문에서 확인한 구체적 기관·학교·영향 관계"}]
DAILY_NEWS_VERIFIED_CANDIDATES -->
The runner removes this block before saving the public Markdown/HTML. Do not put a candidate in the block unless its
article body was checked and the candidate is included in the report. The verification_basis must state the concrete
body evidence, not just repeat the title or say "관련 있음".
"@

$promptPath = Join-Path $reportDir "prompt.txt"
[System.IO.File]::WriteAllText($promptPath, $prompt, $script:Utf8NoBom)

if ($DryRun) {
    Write-Log "DryRun 모드입니다."
    Write-Log "저장 폴더: $reportDir"
    Write-Log "Markdown: $markdownPath"
    Write-Log "HTML: $htmlPath"
    Write-Log "Prompt: $promptPath"
    Write-Log "엔진: $ClaudeCommand -model $Model (DryRun에서는 실행하지 않음)"
    Write-Log "1차 수집기: $(Join-Path $PSScriptRoot 'collect_news_rss.py') (DryRun에서는 실행하지 않음)"
    exit 0
}

# ---- 1차 수집: Google News RSS(+네이버 API 보강) 수집기 ----
$collectedJsonPath = Join-Path $engineWorkDir "collected_articles.json"
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
        $collectorArgs = @($collectorPath, "--start", $windowStartDisplay, "--end", $windowEndDisplay, "--out-dir", $engineWorkDir)
        $quotedCollectorArgs = $collectorArgs | ForEach-Object {
            if ($_ -match '\s|"') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
        }
        $collectorProcess = Start-Process -FilePath $PythonCommand -ArgumentList ([string]::Join(' ', $quotedCollectorArgs)) -RedirectStandardOutput $collectorStdout -RedirectStandardError $collectorStderr -PassThru -NoNewWindow
        if (-not $collectorProcess.WaitForExit($CollectorTimeoutSeconds * 1000)) {
            try { $collectorProcess.Kill($true) } catch { Stop-Process -Id $collectorProcess.Id -Force -ErrorAction SilentlyContinue }
            try {
                if ($collectorProcess.WaitForExit(5000)) {
                    $collectorProcess.WaitForExit()
                }
            } catch {
            }
            Write-RunLog -Path $logPath -Message "수집기 시간 초과 — Claude 자체 검색으로 폴백합니다."
        } elseif ($collectorProcess.ExitCode -ne 0) {
            Write-RunLog -Path $logPath -Message ("수집기 실패(exit {0}) — Claude 자체 검색으로 폴백합니다." -f $collectorProcess.ExitCode)
        } elseif (Test-NonEmptyFile -Path $collectedJsonPath) {
            $pool = Get-Content -Path $collectedJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($pool.article_count -ge 1) {
                $collectorUsed = $true
                $collectorCount = $pool.article_count
                Copy-Item -Path $collectedJsonPath -Destination $persistedCollectedJsonPath -Force
                Write-RunLog -Path $logPath -Message ("1차 수집 완료: {0}건 (수집 실패 쿼리 {1}건)" -f $pool.article_count, @($pool.failures).Count)
            } else {
                Write-RunLog -Path $logPath -Message "1차 수집 0건 — Claude 자체 검색으로 폴백합니다."
            }
        } else {
            Write-RunLog -Path $logPath -Message "수집 결과 파일이 없습니다 — Claude 자체 검색으로 폴백합니다."
        }
    } catch {
        Write-RunLog -Path $logPath -Message ("수집기 실행 오류: {0} — Claude 자체 검색으로 폴백합니다." -f $_.Exception.Message)
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
    Write-RunLog -Path $logPath -Message "수집기 스크립트가 없습니다 — Claude 자체 검색으로 진행합니다."
}

if (-not $collectorUsed) {
    Remove-Item -Path $collectedJsonPath -Force -ErrorAction SilentlyContinue
} else {
    $prompt += @"

Pre-collected candidate pool: your working directory contains ``collected_articles.json`` with $collectorCount candidate articles,
produced by the skill's deterministic collector (Google News RSS primary + Naver API supplement) for exactly the check window above,
with original media URLs already resolved. Read it with the Read tool.
- Use it as the primary candidate pool. Do not redo broad first-pass collection from scratch.
- Verify the relevance of every entry before including it. Entries with ``"engine": "naver-api"`` are unfiltered keyword matches and require an explicit relevance check.
- Use ``relevance_hint`` only as triage metadata, never as the final decision. ``likely_irrelevant`` means the title has an Incheon location or clear commercial context but no education subject; ``needs_review`` preserves exact school names and low-context titles for body verification. Collector candidates carry ``publication_eligible: false`` by default; do not treat ``likely_relevant`` or ``needs_review`` as permission to publish before article-body verification.
- Check the ``relevance_reasons``, ``location_hits``, ``education_subject_hits``, and ``student_story_hits`` fields and state a concrete inclusion relationship in your reasoning before selecting school/student items.
- Check the ``failures`` field: queries listed there may be under-collected, so supplement those specific queries with targeted web searches per the skill's recipes.
- Still apply the skill's selection, deduplication, ranking, verification, and output rules to the pool.
- The file path is: $collectedJsonPath
"@
    [System.IO.File]::WriteAllText($promptPath, $prompt, $script:Utf8NoBom)
}

# 프롬프트는 argv가 아니라 stdin으로 전달한다 (Codex 러너에서 겪은 argv 개행 절단 사고를
# 답습하지 않기 위한 예방 조치 — claude -p도 동일 패턴 유지).
$argList = @(
    "-p",
    "--output-format", "text",
    "--model", $Model,
    "--allowedTools", "Read Glob Grep WebSearch WebFetch",
    "--permission-mode", "bypassPermissions"
)

$lastMessagePath = Join-Path $engineWorkDir "last-message.md"
$stderrPath = Join-Path $reportDir "claude.stderr.log"
$generatedMarkdown = $null
$generatedHtml = $null
$process = $null
$timedOut = $false
$verificationFailed = $false
$verifiedCandidateAvailable = $false
$lastValidationFailures = @()

Write-RunLog -Path $logPath -Message "STATUS: STARTED"
Write-RunLog -Path $logPath -Message ("설정: engine=claude, model={0}, output={1}, engineWorkDir={2}, timeoutSeconds={3}" -f $Model, $reportDir, $engineWorkDir, $ClaudeTimeoutSeconds)

$gitBashPath = Set-GitBashEnvironment
if ($gitBashPath) {
    Write-RunLog -Path $logPath -Message ("Git Bash 경로 고정: {0}" -f $gitBashPath)
} else {
    Write-RunLog -Path $logPath -Message "Git Bash 경로를 찾지 못했습니다. 현재 PATH를 그대로 사용합니다."
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
        Write-RunLog -Path $logPath -Message ("Claude 실행을 시작합니다. (시도 {0}/{1})" -f $attempt, $MaxAttempts)
        $timedOut = $false
        Remove-IfExists -Path $lastMessagePath
        $process = Start-Process -FilePath $ClaudeCommand -ArgumentList $argumentString -RedirectStandardInput $promptPath -RedirectStandardOutput $lastMessagePath -RedirectStandardError $stderrPath -PassThru -NoNewWindow -WorkingDirectory $engineWorkDir
        if (-not $process.WaitForExit($ClaudeTimeoutSeconds * 1000)) {
            $timedOut = $true
            try {
                $process.Kill($true)
            } catch {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            }
            throw "Claude 실행 시간 제한 초과"
        }

        if (Test-Path $stderrPath) {
            [System.IO.File]::AppendAllText($logPath, [System.IO.File]::ReadAllText($stderrPath, [System.Text.Encoding]::UTF8), $script:Utf8NoBom)
        }

        $generatedMarkdown = if (Test-NonEmptyFile -Path $lastMessagePath) { Get-Item -LiteralPath $lastMessagePath } else { $null }
        $generatedHtml = $null

        if ($generatedMarkdown -and $generatedMarkdown.FullName -ne $markdownPath) {
            Copy-Item -Path $generatedMarkdown.FullName -Destination $markdownPath -Force
        }

        if (Test-NonEmptyFile -Path $markdownPath) {
            Repair-MarkdownReport -Path $markdownPath
        }

        if (-not (Test-IsMarkdownReport -Path $markdownPath)) {
            $generatedReportMarkdown = Get-GeneratedReportMarkdown -SearchDirs @($reportDir, $engineWorkDir)
            if ($generatedReportMarkdown -and $generatedReportMarkdown.FullName -ne $markdownPath) {
                Copy-Item -Path $generatedReportMarkdown.FullName -Destination $markdownPath -Force
            }
        }

        if (Test-NonEmptyFile -Path $markdownPath) {
            Repair-MarkdownReport -Path $markdownPath
        }

        $lastValidationFailures = @(Get-MarkdownReportValidationFailures -Path $markdownPath)
        if (($process.ExitCode -eq 0) -and ($lastValidationFailures.Count -eq 0)) {
            $reportReady = $true
            break
        }

        if ($attempt -lt $MaxAttempts) {
            $retryReason = if ($process.ExitCode -ne 0) {
                "exit code $($process.ExitCode)"
            } else {
                "보고서 검증 실패: $($lastValidationFailures -join ', ')"
            }
            if (($process.ExitCode -eq 0) -and ($lastValidationFailures.Count -gt 0)) {
                $retryPrompt = $prompt + @"

이전 출력 검증 실패 항목: $($lastValidationFailures -join ', ')
위 항목을 모두 수정한 전체 보고서를 다시 반환하세요. 특히 요구된 제목과 "## 주요 언론보도" 헤더 규칙(다른 "##" 헤더 금지, 세부 분류는 "###"만 사용)과 점검 범위를 정확히 유지하세요.
"@
                [System.IO.File]::WriteAllText($promptPath, $retryPrompt, $script:Utf8NoBom)
            }
            Write-RunLog -Path $logPath -Message ("시도 {0} 실패({1}). 부분 산출물 제거 후 재시도합니다." -f $attempt, $retryReason)
            Remove-IfExists -Path $markdownPath
            Remove-IfExists -Path $htmlPath
            if ($generatedMarkdown -and $generatedMarkdown.FullName -ne $lastMessagePath) { Remove-IfExists -Path $generatedMarkdown.FullName }
            Start-Sleep -Seconds 15
        }
    }

    if (-not $reportReady) {
        if ($process -and $process.ExitCode -ne 0) {
            throw "Claude 실행 실패"
        }
        if (-not (Test-NonEmptyFile -Path $markdownPath)) {
            throw "Markdown 결과가 비어 있거나 생성되지 않았습니다."
        }
        throw "Markdown 결과가 보고서 본문 형식이 아닙니다."
    }

    # ---- 본문 검증 후보 자동 승격 ----
    $promotionScript = Join-Path $PSScriptRoot "promote_verified_candidates.py"
    $candidateInputAvailable = $collectorUsed -and (Test-NonEmptyFile -Path $collectedJsonPath)
    $promotionArgs = @(
        $promotionScript,
        "--report", $markdownPath,
        "--output", $verifiedCollectedJsonPath,
        "--manifest-output", $verificationManifestPath
    )
    if ($candidateInputAvailable) {
        $promotionArgs = @(
            $promotionScript,
            "--input", $collectedJsonPath,
            "--report", $markdownPath,
            "--output", $verifiedCollectedJsonPath,
            "--manifest-output", $verificationManifestPath
        )
    }
    try {
        Remove-IfExists -Path $verificationLogPath
        & $PythonCommand @promotionArgs *> $verificationLogPath
        $promotionExitCode = $LASTEXITCODE
        if (($promotionExitCode -ne 0) -or (-not (Test-NonEmptyFile -Path $verifiedCollectedJsonPath))) {
            $verificationFailed = $true
            Write-RunLog -Path $logPath -Message ("본문 검증 후보 승격 실패(exit {0}) — 원본 후보는 비공개로 유지합니다: {1}" -f $promotionExitCode, $verificationLogPath)
        } else {
            Copy-Item -Path $verifiedCollectedJsonPath -Destination $persistedVerifiedCollectedJsonPath -Force
            $verifiedCandidateAvailable = $candidateInputAvailable
            $promotionSummary = Get-Content -Path $verificationLogPath -Raw -Encoding UTF8
            Write-RunLog -Path $logPath -Message ("본문 검증 후보 승격 완료 — {0}" -f $promotionSummary.Trim())
        }
    } catch {
        $verificationFailed = $true
        Write-RunLog -Path $logPath -Message ("본문 검증 후보 승격 오류 — 원본 후보는 비공개로 유지합니다: {0}" -f $_.Exception.Message)
    }

    Convert-MarkdownToHtmlDocument -MarkdownPath $markdownPath -HtmlPath $htmlPath -Title $folderName

    if (-not (Test-NonEmptyFile -Path $htmlPath)) {
        throw "HTML 결과가 비어 있거나 생성되지 않았습니다."
    }

    # ---- 하류 자동 인제스트 (edu-news-organizer) ----
    $downstreamFailed = $false
    $downstreamRequired = (-not [string]::IsNullOrWhiteSpace($SiteDir)) -or $EnablePublicPush
    $organizerScript = Join-Path $env:USERPROFILE ".codex\skills\edu-news-organizer\scripts\newsdb.py"
    if ($SkipDownstream) {
        Write-RunLog -Path $logPath -Message "STATUS: SKIPPED [DOWNSTREAM] -SkipDownstream 지정 — DB 인제스트·사이트 배포를 건너뜁니다(엔진 검증 전용 실행)."
        Write-RunLog -Path $logPath -Message "생성 완료(엔진 단계까지): $reportDir"
        exit 0
    }
    if (Test-Path $organizerScript) {
        $ingestLog = Join-Path $reportDir "organizer-ingest.log"
        Remove-IfExists -Path $ingestLog
        try {
            $env:PYTHONIOENCODING = "utf-8"
            $ingestJsonPath = if ($verifiedCandidateAvailable -and (Test-NonEmptyFile -Path $persistedVerifiedCollectedJsonPath)) {
                $persistedVerifiedCollectedJsonPath
            } elseif (Test-NonEmptyFile -Path $collectedJsonPath) {
                $collectedJsonPath
            } elseif ($collectorUsed -and (Test-NonEmptyFile -Path $persistedCollectedJsonPath)) {
                $persistedCollectedJsonPath
            } else {
                $null
            }
            Invoke-LoggedNativeCommand -Step "브리핑 인제스트" -Command $PythonCommand `
                -Arguments @($organizerScript, "ingest", "--briefing", $markdownPath) -LogPath $ingestLog
            if ($ingestJsonPath) {
                Invoke-LoggedNativeCommand -Step "후보 JSON 인제스트" -Command $PythonCommand `
                    -Arguments @($organizerScript, "ingest", "--json", $ingestJsonPath) -LogPath $ingestLog
            }
            Invoke-LoggedNativeCommand -Step "동일보도 묶음" -Command $PythonCommand `
                -Arguments @($organizerScript, "group", "--date", $reportDateDisplay) -LogPath $ingestLog
            $digestHtmlPath = Join-Path $reportDir "교육뉴스 다이제스트.html"
            Invoke-LoggedNativeCommand -Step "HTML 다이제스트 생성" -Command $PythonCommand `
                -Arguments @($organizerScript, "digest", "--date", $reportDateDisplay, "--format", "html", "--out", $digestHtmlPath) `
                -LogPath $ingestLog
            if (-not (Test-NonEmptyFile -Path $digestHtmlPath)) {
                throw "HTML 다이제스트가 생성되지 않았습니다: $digestHtmlPath"
            }
            Write-RunLog -Path $logPath -Message "하류 인제스트·다이제스트 완료 (edu-news-organizer → organizer-ingest.log, 교육뉴스 다이제스트.html)"

            if ($env:EDU_NEWS_SITE_DIR) {
                $publishScript = Join-Path $env:USERPROFILE ".codex\skills\edu-news-organizer\scripts\publish_site.py"
                $prevPythonUtf8 = $env:PYTHONUTF8
                try {
                    $env:PYTHONUTF8 = "1"
                    $publishArgs = @($publishScript, "--site-dir", $env:EDU_NEWS_SITE_DIR, "--date", $reportDateDisplay)
                    if ($env:EDU_NEWS_SITE_PUSH -eq "1") {
                        $publishArgs += "--push"
                    }
                    Invoke-LoggedNativeCommand -Step "정적 사이트 게시" -Command $PythonCommand `
                        -Arguments $publishArgs -LogPath $ingestLog
                    $archivePath = Join-Path $env:EDU_NEWS_SITE_DIR ("archive\{0}.html" -f $reportDateDisplay)
                    if (-not (Test-NonEmptyFile -Path $archivePath)) {
                        throw "날짜별 공개 아카이브가 생성되지 않았습니다: $archivePath"
                    }
                } finally {
                    $env:PYTHONUTF8 = $prevPythonUtf8
                }
                Write-RunLog -Path $logPath -Message ("정적 사이트 배포 완료 (공개 안전본 → {0}, push={1})" -f $env:EDU_NEWS_SITE_DIR, ($env:EDU_NEWS_SITE_PUSH -eq "1"))
            }
        } catch {
            $downstreamFailed = $true
            Write-RunLog -Path $logPath -Message ("하류 처리 실패(비치명): {0}" -f $_.Exception.Message)
        }
    } else {
        $message = "하류 구성요소 없음: $organizerScript"
        if ($downstreamRequired) {
            $downstreamFailed = $true
            Write-RunLog -Path $logPath -Message $message
        } else {
            Write-RunLog -Path $logPath -Message ("{0} — 로컬 브리핑만 유지합니다." -f $message)
        }
    }
    if ($downstreamFailed) {
        Write-RunLog -Path $logPath -Message "STATUS: PARTIAL [DOWNSTREAM]"
    } elseif ($verificationFailed) {
        Write-RunLog -Path $logPath -Message "STATUS: PARTIAL [VERIFICATION]"
    } else {
        Write-RunLog -Path $logPath -Message "STATUS: SUCCEEDED"
    }
    Write-RunLog -Path $logPath -Message "생성 완료: $reportDir"
    if (($downstreamFailed -or $verificationFailed) -and $downstreamRequired) {
        exit 1
    }
}
catch {
    $exitCode = if ($timedOut) { 124 } elseif ($process) { $process.ExitCode } else { -1 }
    $category = if ($timedOut) { "timeout" } else { Get-RunFailureCategory -ExitCode $exitCode -StdErrPath $stderrPath }
    $summary = Get-RunFailureSummary -Category $category -ExitCode $exitCode -StdErrPath $stderrPath -ValidationFailures $lastValidationFailures

    Remove-IfExists -Path $markdownPath
    Remove-IfExists -Path $htmlPath
    if ($collectorUsed -and (Test-NonEmptyFile -Path $persistedCollectedJsonPath)) {
        Write-RunLog -Path $logPath -Message ("수집 후보 JSON 보존: {0}" -f $persistedCollectedJsonPath)
    } else {
        Remove-IfExists -Path $persistedCollectedJsonPath
    }
    Remove-IfExists -Path $persistedVerifiedCollectedJsonPath
    Remove-IfExists -Path $verificationManifestPath
    Remove-IfExists -Path $verificationLogPath
    if ($generatedMarkdown -and $generatedMarkdown.FullName -ne $lastMessagePath) {
        Remove-IfExists -Path $generatedMarkdown.FullName
    }

    Write-RunLog -Path $logPath -Message ("STATUS: FAILED [{0}]" -f $category.ToUpperInvariant())
    Write-RunLog -Path $logPath -Message ("원인: {0}" -f $summary)
    # 원본과 달리 여기서 run.log/claude.stderr.log를 삭제하지 않는다 — 2026-08-21 실패 조사 시
    # 로그가 이미 지워져 원인 규명이 불가능했던 문제를 재발시키지 않기 위함. 대신 report 폴더
    # 자체를 다음 재시도 전까지 보존해 사후 분석 가능하게 한다.
    throw "{0}. 로그: {1}" -f $summary, $logPath
}
