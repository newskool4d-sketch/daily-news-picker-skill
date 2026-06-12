param(
    [string]$BasePath = $env:DAILY_NEWS_OUTPUT_DIR,
    [string]$WorkingRoot = $env:USERPROFILE,
    [string]$CodexCommand = $(if (Test-Path (Join-Path $env:APPDATA "npm\codex.cmd")) { Join-Path $env:APPDATA "npm\codex.cmd" } else { "codex" }),
    [string]$Model = "gpt-5.4",
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
  <title>$Title</title>
  <style>
    :root { color-scheme: light; }
    body { font-family: "Malgun Gothic", "Apple SD Gothic Neo", sans-serif; margin: 0; background: linear-gradient(180deg, #f4f7fb 0%, #eef3f8 100%); color: #1f2937; }
    .page { max-width: 980px; margin: 0 auto; padding: 32px 20px 60px; }
    .hero { background: #ffffff; border: 1px solid #d8e2ee; border-radius: 18px; padding: 28px 32px; box-shadow: 0 14px 40px rgba(15, 23, 42, 0.06); margin-bottom: 24px; }
    .hero p { margin: 8px 0 0; color: #475569; }
    .article { background: #ffffff; border: 1px solid #d8e2ee; border-radius: 18px; padding: 28px 32px; box-shadow: 0 14px 40px rgba(15, 23, 42, 0.05); }
    h1, h2, h3 { color: #0f172a; line-height: 1.35; }
    h1 { margin: 0; font-size: 2rem; }
    h2 { margin-top: 2.2rem; padding-bottom: 0.4rem; border-bottom: 2px solid #e2e8f0; }
    h3 { margin-top: 1.4rem; color: #1d4ed8; }
    p { margin: 0.9rem 0; }
    a { color: #0b57d0; text-decoration: none; word-break: break-all; }
    a:hover { text-decoration: underline; }
    ul { padding-left: 22px; margin: 0.8rem 0; }
    li { margin: 0.35rem 0; }
    code { background: #eff6ff; color: #1e3a8a; padding: 2px 6px; border-radius: 6px; }
    blockquote { border-left: 4px solid #93c5fd; background: #f8fbff; margin: 1rem 0; padding: 12px 16px; color: #334155; }
    table { width: 100%; border-collapse: collapse; margin: 1rem 0; }
    th, td { border: 1px solid #d8e2ee; padding: 10px 12px; vertical-align: top; }
    th { background: #f8fafc; text-align: left; }
    .meta { font-size: 0.95rem; color: #64748b; }
  </style>
</head>
<body>
  <div class="page">
    <section class="hero">
      <h1>$Title</h1>
      <p>인천광역시교육청 및 산하기관 언론보도 자동 브리핑</p>
      <p class="meta">생성 시각: $generatedAt</p>
    </section>
    <section class="article">
$body
    </section>
  </div>
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

$now = Get-Date
$reportDate = $now.Date
$reportDateStamp = $reportDate.ToString("yyyyMMdd")
$reportDateDisplay = $reportDate.ToString("yyyy-MM-dd")
$folderName = "인천교육청 언론보도 현황($reportDateStamp)"
$reportDir = Join-Path $BasePath $folderName
$markdownPath = Join-Path $reportDir "인천교육청 언론보도 현황.md"
$htmlPath = Join-Path $reportDir "인천교육청 언론보도 현황.html"
$logPath = Join-Path $reportDir "run.log"

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

$prompt = @"
Use `$daily-news-picker at C:\Users\홍주형\.codex\skills\daily-news-picker\SKILL.md.

This run is an automated report generation job, not a conversation.
Collect and rank today's news about 인천교육청 and produce the final report immediately.

Apply these rules:
- Reference date: $reportDateDisplay
- Reference time: 07:00 Asia/Seoul
- Scope: Incheon Metropolitan Office of Education, district offices of education, and affiliated institutions
- Use linked press coverage first
- Exclude education office homepage notices and routine announcements
- If several outlets carry materially the same story, keep only one representative article
- If no meaningful article is found, still produce the full report structure and say `확인된 유의미 기사 없음`
- Do not ask follow-up questions
- Do not explain the workflow
- Do not mention that this is a weekend, holiday, or skipped schedule
- Do not output conversational text before or after the report
- Do not create, edit, or propose files
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
    "-C", $reportDir,
    "-m", $Model,
    "-o", $markdownPath,
    $prompt
)

$stdoutPath = Join-Path $reportDir "codex.stdout.log"
$stderrPath = Join-Path $reportDir "codex.stderr.log"
$generatedMarkdown = $null
$generatedHtml = $null
$process = $null

Write-RunLog -Path $logPath -Message "STATUS: STARTED"
Write-RunLog -Path $logPath -Message ("설정: model={0}, bypass={1}, workdir={2}" -f $Model, $DangerouslyBypassApprovalsAndSandbox.IsPresent, $reportDir)

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

    Write-RunLog -Path $logPath -Message "Codex 실행을 시작합니다."
    $process = Start-Process -FilePath $CodexCommand -ArgumentList $argumentString -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -Wait -PassThru -NoNewWindow

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

    if ($process.ExitCode -ne 0) {
        throw "Codex 실행 실패"
    }

    if (-not (Test-NonEmptyFile -Path $markdownPath)) {
        throw "Markdown 결과가 비어 있거나 생성되지 않았습니다."
    }

    if (-not (Test-Path $htmlPath)) {
        Convert-MarkdownToHtmlDocument -MarkdownPath $markdownPath -HtmlPath $htmlPath -Title $folderName
    }

    if (-not (Test-NonEmptyFile -Path $htmlPath)) {
        throw "HTML 결과가 비어 있거나 생성되지 않았습니다."
    }

    Write-RunLog -Path $logPath -Message "STATUS: SUCCEEDED"
    Write-RunLog -Path $logPath -Message "생성 완료: $reportDir"
}
catch {
    $exitCode = if ($process) { $process.ExitCode } else { -1 }
    $category = Get-RunFailureCategory -ExitCode $exitCode -StdErrPath $stderrPath
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
