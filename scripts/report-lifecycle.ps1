# Shared by both PowerShell 7 entry points. The caller holds the date lock until
# downstream processing has checkpointed its last successful step.
function Open-ReportLock([string]$Directory, [string]$Name) {
    [IO.Directory]::CreateDirectory($Directory) | Out-Null
    try {
        return [IO.File]::Open((Join-Path $Directory $Name), 'OpenOrCreate', 'ReadWrite', 'None')
    } catch [IO.IOException] {
        throw "실행 잠금을 획득할 수 없습니다 ($Directory): $($_.Exception.Message)"
    }
}

function Write-Checkpoint([string]$Path, $State) {
    $temporary = "$Path.new"
    [IO.File]::WriteAllText($temporary, ($State | ConvertTo-Json -Depth 6), $script:Utf8NoBom)
    [IO.File]::Move($temporary, $Path, $true)
}

function Write-ValidatedPreview([string]$Path, [string]$HtmlOutput) {
    $content = [IO.File]::ReadAllText($Path)
    $renderPath = $Path
    $scratch = $null
    try {
        if ($content -match 'DAILY_NEWS_(VERIFIED_CANDIDATES|SOURCE_CHECKS)') {
            $scratch = [IO.Directory]::CreateTempSubdirectory('news-preview-').FullName
            $renderPath = Join-Path $scratch 'report.md'
            [IO.File]::Copy($Path, $renderPath)
            $manifest = Join-Path $scratch 'audit.json'
            $arguments = @((Join-Path $PSScriptRoot 'promote_verified_candidates.py'),
                '--report', $renderPath, '--output', (Join-Path $scratch 'verified.json'),
                '--manifest-output', $manifest, '--coverage-roster', (Join-Path (Split-Path $PSScriptRoot) 'references/media-sources.md'))
            $pool = Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($Path))) 'collected_articles.json'
            if (Test-NonEmptyFile $pool) { $arguments += @('--input', $pool) }
            Invoke-LoggedNativeCommand -Step '보고서 표식 확인' -Command $PythonCommand -Arguments $arguments -LogPath (Join-Path $scratch 'check.log')
            $summary = (Get-Content -LiteralPath $manifest -Raw -Encoding utf8 | ConvertFrom-Json).summary
            if (-not $summary.coverage_complete -or $summary.report_incomplete) {
                throw '보고서 또는 매체 점검 미완료'
            }
        } elseif ($content -match '(?m)^(?:[-*] )?수집 미완료[ \t]*(?:\r?$|[:(])') {
            throw '수집 미완료 보고서입니다.'
        } elseif ($content -match '확인된 유의미 기사 없음') {
            $directory = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
            $state = Get-Content -LiteralPath (Join-Path $directory 'report-state.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
            $audit = Join-Path $directory 'verification-manifest.json'
            if ($state.hashes['인천교육청 언론보도 현황.md'] -ne (Get-FileHash -LiteralPath $Path).Hash -or
                $state.hashes['verification-manifest.json'] -ne (Get-FileHash -LiteralPath $audit).Hash -or
                -not (Get-Content -LiteralPath $audit -Raw -Encoding utf8 | ConvertFrom-Json).summary.coverage_complete) {
                throw '0건 보고에 대응하는 매체 점검 기록이 없습니다.'
            }
        }
        if ($HtmlOutput) {
            $parent = Split-Path -Parent ([IO.Path]::GetFullPath($HtmlOutput))
            [IO.Directory]::CreateDirectory($parent) | Out-Null
            Convert-MarkdownToHtmlDocument -MarkdownPath $renderPath -HtmlPath $HtmlOutput -Title "인천교육청 언론보도 현황($reportDateStamp)"
            if (-not (Test-NonEmptyFile $HtmlOutput)) { throw 'HTML 변환 결과가 비어 있습니다.' }
            Write-Output "REPORT_HTML: $HtmlOutput"
        }
    } finally {
        if ($scratch) {
            foreach ($name in @('report.md', 'verified.json', 'audit.json', 'check.log')) { [IO.File]::Delete((Join-Path $scratch $name)) }
            [IO.Directory]::Delete($scratch)
        }
    }
}

function Restore-ReportTransaction {
    # No local file has been replaced until every prior file is backed up.
    $journal = Join-Path $reportDir '.report-pending'
    if (-not [IO.File]::Exists($journal)) { return }
    foreach ($name in $reportFiles + 'report-state.json') {
        $old = Join-Path $backupDir $name
        $target = Join-Path $reportDir $name
        if ([IO.File]::Exists($old)) {
            [IO.File]::Copy($old, "$old.restore", $true)
            [IO.File]::Move("$old.restore", $target, $true)
        } else {
            [IO.File]::Delete($target)
        }
    }
    [IO.File]::Delete($journal)
}

function Install-ValidatedReport($State) {
    $journal = Join-Path $reportDir '.report-pending'
    $names = $reportFiles + 'report-state.json'
    Write-Checkpoint (Join-Path $stageDir 'report-state.json') $State
    [IO.Directory]::CreateDirectory($backupDir) | Out-Null
    foreach ($name in $names) {
        $old = Join-Path $backupDir $name
        $target = Join-Path $reportDir $name
        if ([IO.File]::Exists($target)) { [IO.File]::Copy($target, $old, $true) }
        else { [IO.File]::Delete($old) }
    }
    [IO.File]::WriteAllText($journal, 'prepared', $script:Utf8NoBom)
    try {
        foreach ($name in $names) {
            $new = Join-Path $stageDir $name
            $target = Join-Path $reportDir $name
            if ([IO.File]::Exists($new)) { [IO.File]::Move($new, $target, $true) }
            else { [IO.File]::Delete($target) }
        }
        [IO.File]::Delete($journal)
    } catch {
        Restore-ReportTransaction
        throw
    }
}

function Read-ValidatedState {
    if (-not [IO.File]::Exists($statePath)) { return }
    try {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        if ($state.version -ne 1 -or $state.windowStart -ne $windowStartDisplay -or
            $state.windowEnd -ne $windowEndDisplay) { return }
        if ($state.step -notin (0..4) -or $state.hashes -isnot [Collections.IDictionary]) { return }
        foreach ($name in $reportFiles) {
            if ($name -eq 'collected_articles.json' -and -not $state.hashes.Contains($name)) { continue }
            $path = Join-Path $reportDir $name
            if (-not (Test-NonEmptyFile $path) -or (Get-FileHash -LiteralPath $path).Hash -ne $state.hashes[$name]) { return }
        }
        return $state
    } catch {
        Write-RunLog -Path $logPath -Message "완료 기록을 검증할 수 없어 보고서를 다시 생성합니다."
    }
}

function Complete-Downstream($State) {
    $organizerScript = Join-Path $env:USERPROFILE '.codex\skills\edu-news-organizer\scripts\newsdb.py'
    if (-not [IO.File]::Exists($organizerScript)) {
        if ($SiteDir -or $EnablePublicPush) { throw "하류 구성요소 없음: $organizerScript" }
        Write-RunLog -Path $logPath -Message 'organizer 미설치 — 로컬 보고서 생성 완료'
        return
    }
    $ingestLog = Join-Path $reportDir 'organizer-ingest.log'
    $digest = Join-Path $reportDir '교육뉴스 다이제스트.html'
    $dbTarget = if ($env:EDU_NEWS_DB_PATH) { [IO.Path]::GetFullPath($env:EDU_NEWS_DB_PATH) }
                else { Join-Path $env:USERPROFILE 'Documents/Codex/EduNewsOrganizer/news.db' }
    if ($State.dbTarget -ne $dbTarget -or ($State.dbPersisted -and -not [IO.File]::Exists($dbTarget))) {
        $State.dbTarget = $dbTarget
        $State.dbPersisted = $false
        $State.step = 0
        $State.site = ''
    }
    $steps = @(
        @{ name = '브리핑 인제스트'; args = @($organizerScript, 'ingest', '--briefing', (Join-Path $reportDir 'selected-briefing.md')) },
        @{ name = '후보 JSON 인제스트'; args = @($organizerScript, 'ingest', '--json', (Join-Path $reportDir 'verified_collected_articles.json')) },
        @{ name = '동일보도 묶음'; args = @($organizerScript, 'group', '--date', $reportDateDisplay) },
        @{ name = 'HTML 다이제스트 생성'; args = @($organizerScript, 'digest', '--date', $reportDateDisplay, '--format', 'html', '--out', "$digest.new") }
    )
    if ($State.step -ge 4 -and (-not (Test-NonEmptyFile $digest) -or
        (Get-FileHash -LiteralPath $digest).Hash -ne $State.digestHash)) { $State.step = 3 }
    for ($i = [int]$State.step; $i -lt $steps.Count; $i++) {
        if ($i -eq 3) { [IO.File]::Delete("$digest.new") }
        Invoke-LoggedNativeCommand -Step $steps[$i].name -Command $PythonCommand -Arguments $steps[$i].args -LogPath $ingestLog
        if ($i -eq 3) {
            if (-not (Test-NonEmptyFile "$digest.new")) { throw 'HTML 다이제스트가 비어 있습니다.' }
            [IO.File]::Move("$digest.new", $digest, $true)
            $State.digestHash = (Get-FileHash -LiteralPath $digest).Hash
        }
        if ($i -eq 0) { $State.dbPersisted = [IO.File]::Exists($dbTarget) }
        $State.step = $i + 1
        Write-Checkpoint $statePath $State
    }
    if ($SiteDir) {
        $siteKey = "$([IO.Path]::GetFullPath($SiteDir))|$EnablePublicPush"
        $archivePath = Join-Path $SiteDir ("archive\{0}.html" -f $reportDateDisplay)
        # The publisher updates archive navigation when later editions are added.
        if ($State.site -eq $siteKey -and (Test-NonEmptyFile $archivePath)) { return }
        $publishScript = Join-Path (Split-Path $organizerScript) 'publish_site.py'
        $publishArgs = @($publishScript, '--site-dir', $SiteDir, '--date', $reportDateDisplay)
        if ($EnablePublicPush) { $publishArgs += '--push' }
        Invoke-LoggedNativeCommand -Step '정적 사이트 게시' -Command $PythonCommand -Arguments $publishArgs -LogPath $ingestLog
        if (-not (Test-NonEmptyFile $archivePath)) { throw "날짜별 아카이브 누락: $archivePath" }
        $State.site = $siteKey
        Write-Checkpoint $statePath $State
    }
}

function Get-CandidatePoolInstructions([string]$EngineWorkDir) {
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
            $rosterPath = Join-Path (Split-Path $PSScriptRoot) "references/media-sources.md"
            $collectorArgs = @($collectorPath, "--coverage-roster", $rosterPath, "--start", $windowStartDisplay, "--end", $windowEndDisplay, "--out-dir", $engineWorkDir)
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
                Write-RunLog -Path $logPath -Message "수집기 시간 초과 — 모델 검색으로 폴백합니다."
            } elseif ($collectorProcess.ExitCode -ne 0) {
                Write-RunLog -Path $logPath -Message ("수집기 실패(exit {0}) — 모델 검색으로 폴백합니다." -f $collectorProcess.ExitCode)
            } elseif (Test-NonEmptyFile -Path $collectedJsonPath) {
                $pool = Get-Content -LiteralPath $collectedJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($pool.window_start -ne $windowStartDisplay -or $pool.window_end -ne $windowEndDisplay -or
                    $null -eq $pool.articles -or $pool.article_count -ne $pool.articles.Count) {
                    throw '후보 JSON의 수집 창 또는 기사 수가 일치하지 않습니다.'
                }
                Copy-Item -LiteralPath $collectedJsonPath -Destination $persistedCollectedJsonPath -Force
                if ($pool.article_count -ge 1) {
                    $collectorUsed = $true
                    $collectorCount = $pool.article_count
                    Write-RunLog -Path $logPath -Message ("1차 수집 완료: {0}건 (수집 실패 쿼리 {1}건)" -f $pool.article_count, @($pool.failures).Count)
                } else {
                    Write-RunLog -Path $logPath -Message "1차 수집 0건 — 모델 검색으로 폴백합니다."
                }
            } else {
                Write-RunLog -Path $logPath -Message "수집 결과 파일이 없습니다 — 모델 검색으로 폴백합니다."
            }
        } catch {
            Write-RunLog -Path $logPath -Message ("수집기 실행 오류: {0} — 모델 검색으로 폴백합니다." -f $_.Exception.Message)
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
        Write-RunLog -Path $logPath -Message "수집기 스크립트가 없습니다 — 모델 검색으로 진행합니다."
    }

    if (-not $collectorUsed) {
        if (Test-NonEmptyFile $persistedCollectedJsonPath) {
            return "
Read collected_articles.json for the per-domain source_checks. No candidates were found. Search the uncovered outlets and institution queries."
        }
        [IO.File]::Delete($collectedJsonPath)
        return "
The collector was unavailable. Search the institution queries and each required outlet directly."
    }
    return @"

Read collected_articles.json ($collectorCount candidates). Use its search window and source_checks. Search
missing or failed queries directly. Original URLs may need resolution. Read each selected article body and
verify the Incheon school or institution relationship. Use relevance_hint only to prioritize review.
Naver results are unfiltered. Only articles included in the main list may appear in the candidate verification marker.
"@
}

function Invoke-DailyReport([string]$EngineWorkDir, [switch]$LocalOnly) {
    $folderName = "인천교육청 언론보도 현황($reportDateStamp)"
    $reportDir = [IO.Path]::GetFullPath((Join-Path $BasePath $folderName))
    $stageDir = Join-Path $reportDir '.report-stage'
    $backupDir = Join-Path $reportDir '.report-backup'
    $statePath = Join-Path $reportDir 'report-state.json'
    $logPath = Join-Path $reportDir 'run.log'
    $reportFiles = @('인천교육청 언론보도 현황.md', '인천교육청 언론보도 현황.html', 'selected-briefing.md',
        'verified_collected_articles.json', 'verification-manifest.json', 'collected_articles.json')
    $dateLock = Open-ReportLock $reportDir '.run.lock'
    $priorSite = $env:EDU_NEWS_SITE_DIR
    $priorPush = $env:EDU_NEWS_SITE_PUSH
    $priorEncoding = $env:PYTHONIOENCODING
    $priorUtf8 = $env:PYTHONUTF8
    try {
        $env:EDU_NEWS_SITE_DIR = $SiteDir
        $env:EDU_NEWS_SITE_PUSH = if ($EnablePublicPush) { '1' } else { '0' }
        $env:PYTHONIOENCODING = 'utf-8'
        $env:PYTHONUTF8 = '1'
        Restore-ReportTransaction
        $state = Read-ValidatedState
        $refreshPending = Join-Path $reportDir '.refresh-pending'
        if ($Force -or -not $state -or [IO.File]::Exists($refreshPending)) {
            $engineLock = Open-ReportLock $EngineWorkDir '.engine.lock'
            try {
                [IO.File]::WriteAllText($refreshPending, $windowEndDisplay, $script:Utf8NoBom)
                [IO.Directory]::CreateDirectory($stageDir) | Out-Null
                foreach ($name in $reportFiles + @('empty-pool.json', 'report-state.json')) {
                    [IO.File]::Delete((Join-Path $stageDir $name))
                }
                foreach ($name in @('last-message.md', 'collected_articles.json')) {
                    [IO.File]::Delete((Join-Path $EngineWorkDir $name))
                }
                $markdownPath = Join-Path $stageDir $reportFiles[0]
                $htmlPath = Join-Path $stageDir $reportFiles[1]
                $persistedCollectedJsonPath = Join-Path $stageDir 'collected_articles.json'
                Write-RunLog -Path $logPath -Message 'STATUS: STARTED'
                New-EngineReport
                $inputPool = $persistedCollectedJsonPath
                if (-not [IO.File]::Exists($inputPool)) {
                    # An empty dated snapshot also clears previous candidate selections on a forced rebuild.
                    $inputPool = Join-Path $stageDir 'empty-pool.json'
                    Write-Checkpoint $inputPool @{window_end=$windowEndDisplay; window_start=$windowStartDisplay; articles=@()}
                }
                $promotionArgs = @((Join-Path $PSScriptRoot 'promote_verified_candidates.py'),
                    '--input', $inputPool, '--report', $markdownPath,
                    '--output', (Join-Path $stageDir 'verified_collected_articles.json'),
                    '--briefing-output', (Join-Path $stageDir 'selected-briefing.md'),
                    '--manifest-output', (Join-Path $stageDir 'verification-manifest.json'),
                    '--coverage-roster', (Join-Path (Split-Path $PSScriptRoot) 'references/media-sources.md'))
                try {
                    Invoke-LoggedNativeCommand -Step '본문·매체 검증' -Command $PythonCommand -Arguments $promotionArgs -LogPath (Join-Path $reportDir 'verification-promotion.log')
                } catch {
                    Write-RunLog -Path $logPath -Message 'STATUS: FAILED [VERIFICATION]'
                    throw
                }
                Convert-MarkdownToHtmlDocument -MarkdownPath $markdownPath -HtmlPath $htmlPath -Title $folderName
                $audit = Get-Content -LiteralPath (Join-Path $stageDir 'verification-manifest.json') -Raw -Encoding utf8 | ConvertFrom-Json
                if ($audit.summary.coverage_complete -ne $true -or $audit.summary.report_incomplete) {
                    foreach ($pair in @(@($markdownPath,'수집 미완료.md'), @($htmlPath,'수집 미완료.html'),
                        @((Join-Path $stageDir 'verification-manifest.json'),'수집 미완료 점검기록.json'))) {
                        [IO.File]::Copy($pair[0], (Join-Path $reportDir $pair[1]), $true)
                    }
                    Write-RunLog -Path $logPath -Message 'STATUS: PARTIAL [COVERAGE]'
                    throw '수집 미완료. 날짜 폴더의 수집 미완료 보고서를 확인하세요.'
                }
                $state = @{version=1; windowStart=$windowStartDisplay; windowEnd=$windowEndDisplay; step=0; site=''; hashes=@{}}
                foreach ($name in $reportFiles) {
                    $path = Join-Path $stageDir $name
                    if ($name -eq 'collected_articles.json' -and -not [IO.File]::Exists($path)) { continue }
                    if (-not (Test-NonEmptyFile $path)) { throw "검증 산출물 누락: $name" }
                    $state.hashes[$name] = (Get-FileHash -LiteralPath $path).Hash
                }
                Install-ValidatedReport $state
                [IO.File]::Delete($refreshPending)
            } catch {
                Write-RunLog -Path $logPath -Message "생성 중단: $($_.Exception.Message)"
                throw
            } finally {
                $engineLock.Dispose()
            }
        }
        if ($LocalOnly) {
            Write-RunLog -Path $logPath -Message 'STATUS: SKIPPED [DOWNSTREAM]'
            return
        }
        try {
            Complete-Downstream $state
        } catch {
            Write-RunLog -Path $logPath -Message "STATUS: PARTIAL [DOWNSTREAM] $($_.Exception.Message)"
            throw
        }
        Write-RunLog -Path $logPath -Message 'STATUS: SUCCEEDED'
    } finally {
        $env:EDU_NEWS_SITE_DIR = $priorSite
        $env:EDU_NEWS_SITE_PUSH = $priorPush
        $env:PYTHONIOENCODING = $priorEncoding
        $env:PYTHONUTF8 = $priorUtf8
        $dateLock.Dispose()
    }
}
