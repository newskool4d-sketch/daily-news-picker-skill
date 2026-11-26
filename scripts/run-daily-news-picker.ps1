param(
    [string]$BasePath = $env:DAILY_NEWS_OUTPUT_DIR,
    [string]$WorkingRoot = $env:USERPROFILE,
    [string]$CodexCommand = $(if (Test-Path (Join-Path $env:APPDATA "npm\codex.cmd")) { Join-Path $env:APPDATA "npm\codex.cmd" } else { "codex" }),
    [string]$Model = "gpt-5.6-sol",
    [string]$PythonCommand = "python",
    [string]$SiteDir = $env:EDU_NEWS_SITE_DIR,
    [bool]$EnablePublicPush = ($env:EDU_NEWS_SITE_PUSH -eq "1"),
    [timespan]$CollectionTime = ([timespan]"05:00"),
    [int]$CollectorTimeoutSeconds = 600,
    [int]$CodexTimeoutSeconds = 1800,
    [int]$MaxAttempts = 2,
    [datetime]$ReportDate = (Get-Date).Date,
    [string]$ValidateReportPath,
    [string]$ValidationHtmlOutputPath,
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

if ($EnablePublicPush -and [string]::IsNullOrWhiteSpace($SiteDir)) {
    throw "공개 배포를 켜려면 -SiteDir를 지정하거나 EDU_NEWS_SITE_DIR 환경변수를 설정하세요."
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

function Test-ReportHttpUrl {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url) -or $Url -match '\s') {
        return $false
    }
    $parsed = $null
    return ([uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$parsed) -and
        $parsed.Scheme -in @('http', 'https') -and
        -not [string]::IsNullOrWhiteSpace($parsed.Host))
}

function Get-ReportMarkdownLinkPattern {
    # Balancing groups keep parentheses inside an article URL intact.
    return '\[(?<label>[^\]\r\n]+)\]\((?<url>https?://(?:[^()\s]|\((?<paren>)|\)(?<-paren>))+(?(paren)(?!)))\)'
}

function Get-ReportArticleUrls {
    param([string]$Text)

    foreach ($line in [regex]::Split($Text, '\r?\n')) {
        $candidate = $line.Trim()
        if (Test-ReportHttpUrl -Url $candidate) {
            $candidate
            continue
        }
        foreach ($linkMatch in [regex]::Matches($line, (Get-ReportMarkdownLinkPattern))) {
            $candidate = $linkMatch.Groups['url'].Value
            if (Test-ReportHttpUrl -Url $candidate) {
                $candidate
            }
        }
    }
}

function ConvertTo-OrganizerCompatibleArticleLinks {
    param([string]$Markdown)

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in [regex]::Split($Markdown, '\r?\n')) {
        [void]$lines.Add($line)
    }
    $insideMain = $false
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^##[ \t]+(.+?)\s*$') {
            $insideMain = ($Matches[1].Trim() -eq '주요 언론보도')
            continue
        }
        if (-not $insideMain -or $lines[$index] -notmatch '^■') {
            continue
        }
        if ($index + 1 -lt $lines.Count -and $lines[$index + 1].Trim() -cmatch '^https?://' -and
            (Test-ReportHttpUrl -Url $lines[$index + 1].Trim())) {
            continue
        }
        for ($sourceIndex = $index + 1; $sourceIndex -lt $lines.Count; $sourceIndex++) {
            if ($lines[$sourceIndex] -match '^(?:■|#{1,6}(?:[ \t]+|$))') {
                break
            }
            $source = $lines[$sourceIndex].Trim()
            $url = $null
            $replacement = ''
            if (Test-ReportHttpUrl -Url $source) {
                $url = $source
            } else {
                $linkMatch = [regex]::Match($source, ('^(?:' + (Get-ReportMarkdownLinkPattern) + ')$'))
                if ($linkMatch.Success -and (Test-ReportHttpUrl -Url $linkMatch.Groups['url'].Value)) {
                    $url = $linkMatch.Groups['url'].Value
                    # Keep the link label as plain text instead of discarding it.
                    $replacement = '링크 설명: ' + $linkMatch.Groups['label'].Value
                }
            }
            if ($url) {
                $url = [regex]::Replace($url, '^https?://', { param($match) $match.Value.ToLowerInvariant() }, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                $lines[$sourceIndex] = $replacement
                $lines.Insert($index + 1, $url)
                break
            }
        }
    }
    return [string]::Join([Environment]::NewLine, $lines)
}

function ConvertTo-ReportHtmlInline {
    param([string]$Text)

    $candidate = $Text.Trim()
    if (Test-ReportHttpUrl -Url $candidate) {
        $encodedUrl = [System.Net.WebUtility]::HtmlEncode($candidate)
        return ('<a href="' + $encodedUrl + '" rel="noopener noreferrer">' + $encodedUrl + '</a>')
    }

    $html = [System.Text.StringBuilder]::new()
    $cursor = 0
    foreach ($linkMatch in [regex]::Matches($Text, (Get-ReportMarkdownLinkPattern))) {
        [void]$html.Append([System.Net.WebUtility]::HtmlEncode($Text.Substring($cursor, $linkMatch.Index - $cursor)))
        $url = $linkMatch.Groups['url'].Value
        if (Test-ReportHttpUrl -Url $url) {
            [void]$html.Append('<a href="' + [System.Net.WebUtility]::HtmlEncode($url) + '" rel="noopener noreferrer">' +
                [System.Net.WebUtility]::HtmlEncode($linkMatch.Groups['label'].Value) + '</a>')
        } else {
            [void]$html.Append([System.Net.WebUtility]::HtmlEncode($linkMatch.Value))
        }
        $cursor = $linkMatch.Index + $linkMatch.Length
    }
    [void]$html.Append([System.Net.WebUtility]::HtmlEncode($Text.Substring($cursor)))
    return $html.ToString()
}

function Convert-MarkdownToHtmlDocument {
    param(
        [string]$MarkdownPath,
        [string]$HtmlPath,
        [string]$Title
    )

    $markdown = Get-Content -LiteralPath $MarkdownPath -Raw -Encoding UTF8

    # The markdown body is built from external news-article titles/links, so it
    # is untrusted input. ConvertFrom-Markdown (markdig) passes raw inline HTML
    # through unescaped, which would let a malicious article title execute
    # script in the generated briefing. Always HTML-encode first and only
    # re-introduce structural markup (headings/lists/links) via regex on the
    # already-encoded text, so no raw tag from the source can survive.
    $escaped = (@([regex]::Split($markdown, '\r?\n') | ForEach-Object { ConvertTo-ReportHtmlInline -Text $_ }) -join "`n")
    $escaped = $escaped -replace '(?m)^### (.+)$', '<h3>$1</h3>'
    $escaped = $escaped -replace '(?m)^## (.+)$', '<h2>$1</h2>'
    $escaped = $escaped -replace '(?m)^# (.+)$', '<h1>$1</h1>'
    $escaped = $escaped -replace '(?m)^- (.+)$', '<li>$1</li>'
    $escaped = $escaped -replace '(<li>.*</li>(\r?\n)?)+', { param($m) "<ul>`n$($m.Value)</ul>`n" }
    # Inline conversion above only makes links for absolute HTTP(S) destinations.
    $escaped = $escaped -replace "(`r`n|`n){2,}", "</p><p>"
    $escaped = $escaped -replace "(`r`n|`n)", "<br>`n"
    $body = "<p>$escaped</p>"
    $safeTitle = [System.Net.WebUtility]::HtmlEncode($Title)

    $generatedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $html = @"
<!doctype html>
<html lang="ko">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="icon" href="data:,">
  <title>$safeTitle</title>
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
        <h1>$safeTitle</h1>
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

    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -Path $Path -Force -ErrorAction SilentlyContinue
    }
}

function Test-NonEmptyFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    return ($item -and $item.Length -gt 0)
}

function Repair-MarkdownReport {
    param([string]$Path)

    if (-not (Test-NonEmptyFile -Path $Path)) {
        return
    }

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $normalized = ($content -replace "^\uFEFF", "").Trim()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return
    }

    if (-not $normalized.TrimStart().StartsWith("# 인천교육청 언론보도 현황")) {
        $normalized = "# 인천교육청 언론보도 현황`r`n`r`n$normalized"
    }

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

        $reservedHeadings = @('핵심 요약', '제외 또는 참고', '검증 메모')
        $insideReserved = $false
        $firstArticleIndex = -1
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -match '^##\s+(.+?)\s*$') {
                $insideReserved = $Matches[1].Trim() -in $reservedHeadings
            } elseif ($lines[$index] -match '^#{3,6}\s+(핵심 요약|제외 또는 참고|검증 메모)\s*$') {
                $insideReserved = $true
            } elseif (-not $insideReserved -and $lines[$index] -match '^■\s+.+\s+-\s+.+$') {
                $firstArticleIndex = $index
                break
            }
        }

        if ($firstArticleIndex -ge 0) {
            $firstCategoryHeadingIndex = -1
            for ($index = $firstArticleIndex - 1; $index -ge 0; $index--) {
                if ($lines[$index] -match '^##\s+(.+?)\s*$') {
                    $heading = $Matches[1].Trim()
                    if ($heading -notin $reservedHeadings) { $firstCategoryHeadingIndex = $index }
                    break
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
    $normalized = ConvertTo-OrganizerCompatibleArticleLinks -Markdown $normalized
    [System.IO.File]::WriteAllText($Path, $normalized + [Environment]::NewLine, $script:Utf8NoBom)
}

function Get-MarkdownReportValidationFailures {
    param([string]$Path)

    if (-not (Test-NonEmptyFile -Path $Path)) {
        return @('non_empty_file')
    }

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $trimmed = $content.TrimStart()
    $failures = [System.Collections.Generic.List[string]]::new()
    if (-not ($trimmed.StartsWith("# 인천교육청 언론보도 현황") -or ($trimmed -match '^20\d{2}\.\s*\d{1,2}\.\s*\d{1,2}\.'))) {
        [void]$failures.Add('title')
    }
    # Check every date the downstream parser can select, including the legacy opening line.
    $datePattern = '(?m)^[ \t]*(?:(?:[-*][ \t]*)?보고일[ \t]*:[ \t]*|(?![^\r\n]*보고일)(?=[^\r\n]*주요 언론보도 현황입니다))(?<year>20\d{2})[ \t]*[-./][ \t]*(?<month>\d{1,2})[ \t]*[-./][ \t]*(?<day>\d{1,2})(?!\d)'
    $dates = [regex]::Matches($content, $datePattern)
    if ($dates.Count -eq 0) { [void]$failures.Add('report_date') }
    foreach ($date in $dates) {
        $isoDate = '{0}-{1:D2}-{2:D2}' -f $date.Groups['year'].Value, [int]$date.Groups['month'].Value, [int]$date.Groups['day'].Value
        if ($isoDate -ne $reportDateDisplay) { [void]$failures.Add('report_date'); break }
    }
    $mainSections = [regex]::Matches($content, '(?m)^##[ \t]+주요 언론보도[ \t]*\r?$')
    if ($mainSections.Count -ne 1) {
        [void]$failures.Add('main_section')
    } else {
        $mainContent = $content.Substring($mainSections[0].Index + $mainSections[0].Length)
        $nextSection = [regex]::Match($mainContent, '(?m)^(?:#{1,2}(?:[ \t]+|$)|#{3,6}[ \t]+(?:핵심 요약|제외 또는 참고|검증 메모)[ \t]*\r?$)')
        if ($nextSection.Success) {
            $mainContent = $mainContent.Substring(0, $nextSection.Index)
        }
        $articles = [regex]::Matches($mainContent, '(?m)^■[^\r\n]*')
        $noArticles = $mainContent -match '확인된 유의미 기사 없음'
        if ($articles.Count -eq 0 -and -not $noArticles -and $mainContent -notmatch '(?m)^(?:[-*] )?수집 미완료[ \t]*(?:\r?$|[:(])') {
            [void]$failures.Add('article_list')
        }
        if ($articles.Count -gt 0 -and $noArticles) {
            [void]$failures.Add('article_list_conflict')
        }
        for ($index = 0; $index -lt $articles.Count; $index++) {
            $articleNumber = $index + 1
            if ($articles[$index].Value -notmatch '^■[ \t]+.+[ \t]+-[ \t]+.+$') {
                [void]$failures.Add("article_${articleNumber}_title")
            }
            $blockEnd = if ($index + 1 -lt $articles.Count) { $articles[$index + 1].Index } else { $mainContent.Length }
            $block = $mainContent.Substring($articles[$index].Index, $blockEnd - $articles[$index].Index)
            $nextHeading = [regex]::Match($block, '(?m)^#{1,6}(?:[ \t]+|$)')
            if ($nextHeading.Success) {
                $block = $block.Substring(0, $nextHeading.Index)
            }
            if (@(Get-ReportArticleUrls -Text $block).Count -eq 0) {
                [void]$failures.Add("article_${articleNumber}_url")
            } else {
                $blockLines = [regex]::Split($block, '\r?\n')
                # edu-news-organizer reads the raw URL immediately after each ■ line.
                if ($blockLines.Count -lt 2 -or $blockLines[1].Trim() -cnotmatch '^https?://' -or
                    -not (Test-ReportHttpUrl -Url $blockLines[1].Trim())) {
                    [void]$failures.Add("article_${articleNumber}_url_format")
                }
            }
        }
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
        [string]$StdErrPath,
        [string[]]$ValidationFailures = @()
    )

    $detail = switch ($Category) {
        "network" { "네트워크 또는 DNS 연결 실패" }
        "mcp" { "MCP 시작 실패" }
        "timeout" { "Codex 실행 시간 제한 초과" }
        "codex_exit" { "Codex 비정상 종료" }
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

. (Join-Path $PSScriptRoot 'report-lifecycle.ps1')

$reportDate = $ReportDate.Date
$reportDateStamp = $reportDate.ToString("yyyyMMdd")
$reportDateDisplay = $reportDate.ToString("yyyy-MM-dd")
if ($DryRun) {
    Write-Log "DryRun: 보고일 $reportDateDisplay, 수집 마감 $CollectionTime, 출력 $BasePath"
    exit 0
}
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
    try {
        Write-ValidatedPreview $ValidateReportPath $ValidationHtmlOutputPath
    } catch {
        Write-Output "REPORT_VALIDATION: FAIL [$($_.Exception.Message)]"
        exit 2
    }
    Write-Output "REPORT_VALIDATION: PASS"
    exit 0
}

if (-not (Test-IsBusinessDay -Date $reportDate) -and -not $Force) {
    Write-Log "주말 또는 공휴일입니다. 기본 규칙에 따라 생성을 건너뜁니다."
    exit 0
}

function New-EngineReport {
    $skillFile = Join-Path (Split-Path $PSScriptRoot) 'SKILL.md'
    $prompt = @"
Use `$daily-news-picker at $skillFile.

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
- 보고서에는 "## 주요 언론보도" 헤더를 정확히 한 번 사용한다.
- 세부 분류 제목을 사용할 경우에는 그 아래 "###" 헤더로만 작성한다.
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
Put any "## 검증 메모" section before both machine blocks; nothing may appear between or after them.
Provide the outlet check log immediately before the verification block:
<!-- DAILY_NEWS_SOURCE_CHECKS
{"incheonin.com":"checked_found","incheontoday.com":"checked_empty"}
DAILY_NEWS_SOURCE_CHECKS -->
Use all required domains in references/media-sources.md. Record checked_found for a completed search with hits,
checked_empty for a completed search without hits, or failed for a failed or unfinished search. The example contains
only two domains. Use the collector's source_checks when available. Search unchecked or failed domains individually;
the marker records completed searches and failures. An incidental article match is not a domain check.
For every collector candidate that you include after checking its article body, append this exact machine-readable
block at the very end of the report (use [] when no collector candidate is verified for publication):
<!-- DAILY_NEWS_VERIFIED_CANDIDATES
[{"original_url":"https://...","verified":true,"publication_eligible":true,"verification_basis":"본문에서 확인한 구체적 기관·학교·영향 관계"}]
DAILY_NEWS_VERIFIED_CANDIDATES -->
The runner removes this block before saving the public Markdown/HTML. Do not put a candidate in the block unless its
article body was checked and the candidate is included in the report. The verification_basis must state the concrete
body evidence, not just repeat the title or say "관련 있음".
"@

    $prompt += Get-CandidatePoolInstructions $EngineWorkDir
    $promptPath = Join-Path $reportDir 'prompt.txt'
    [IO.File]::WriteAllText($promptPath, $prompt, $script:Utf8NoBom)

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
    $process = $null
    $timedOut = $false
    $lastValidationFailures = @()

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
            Remove-IfExists -Path (Join-Path $codexWorkDir "last-message.md")
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
            if (Test-NonEmptyFile $lastMessagePath) {
                Copy-Item -LiteralPath $lastMessagePath -Destination $markdownPath -Force
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
위 항목을 모두 수정한 전체 보고서를 다시 반환하세요. 특히 요구된 제목과 점검 범위를 정확히 유지하세요.
"@
                    [System.IO.File]::WriteAllText($promptPath, $retryPrompt, $script:Utf8NoBom)
                }
                Write-RunLog -Path $logPath -Message ("시도 {0} 실패({1}). 부분 산출물 제거 후 재시도합니다." -f $attempt, $retryReason)
                Remove-IfExists -Path $markdownPath
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

    }
    catch {
        $exitCode = if ($timedOut) { 124 } elseif ($process) { $process.ExitCode } else { -1 }
        $category = if ($timedOut) { "timeout" } else { Get-RunFailureCategory -ExitCode $exitCode -StdErrPath $stderrPath }
        $summary = Get-RunFailureSummary -Category $category -ExitCode $exitCode -StdErrPath $stderrPath -ValidationFailures $lastValidationFailures

        Write-RunLog -Path $logPath -Message ("STATUS: FAILED [{0}]" -f $category.ToUpperInvariant())
        Write-RunLog -Path $logPath -Message ("원인: {0}" -f $summary)
        throw "{0}. 로그: {1}" -f $summary, $logPath
    }
    finally {
        Remove-IfExists -Path $stdoutPath
        Remove-IfExists -Path $stderrPath
    }

}

$codexWorkDir = Join-Path ([IO.Path]::GetTempPath()) 'DailyNewsPickerCodexWork/current'
Invoke-DailyReport -EngineWorkDir $codexWorkDir
