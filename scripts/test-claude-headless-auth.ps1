# 무인 claude.exe 인증 진단. 실제 수집과 별도로 명시 실행할 때만 사용한다.
# 성공 기준: 30초 내 종료(exit 0)하고 stdout이 정확히 READY 한 단어여야 한다.
$ErrorActionPreference = "Stop"
$claudeBin = if ($env:CLAUDE_CODEX_CLAUDE_BIN) { $env:CLAUDE_CODEX_CLAUDE_BIN } else { "claude" }

Write-Host "[TEST] 사용 바이너리: $claudeBin"
Write-Host "[TEST] 실행 시작 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# 동시에 실행한 다른 진단의 파일을 덮어쓰거나 삭제하지 않는다.
$diagnosticId = [guid]::NewGuid().ToString('N')
$tempRoot = [System.IO.Path]::GetTempPath()
$promptPath = Join-Path $tempRoot "claude-headless-$diagnosticId-prompt.txt"
$stdoutPath = Join-Path $tempRoot "claude-headless-$diagnosticId-stdout.log"
$stderrPath = Join-Path $tempRoot "claude-headless-$diagnosticId-stderr.log"
[System.IO.File]::WriteAllText($promptPath, "reply with exactly one word, uppercase: READY", [System.Text.UTF8Encoding]::new($false))

# READY 진단에는 도구가 필요 없다. safe-mode는 OAuth 인증을 유지한다(--bare는 사용하지 않음).
$argList = @(
    "-p",
    "--output-format", "text",
    "--model", "sonnet",
    "--safe-mode",
    "--tools", "",
    "--permission-mode", "dontAsk",
    "--strict-mcp-config",
    "--mcp-config", '{"mcpServers":{}}'
)
$quotedArgs = $argList | ForEach-Object {
    if ([string]::IsNullOrEmpty($_) -or $_ -match '\s|"') {
        '"' + ($_ -replace '"', '\"') + '"'
    } else {
        $_
    }
}
$argumentString = [string]::Join(' ', $quotedArgs)

try {
    $process = Start-Process -FilePath $claudeBin -ArgumentList $argumentString `
        -RedirectStandardInput $promptPath -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath `
        -PassThru -WindowStyle Hidden
    if (-not $process.WaitForExit(30000)) {
        Write-Host "[TEST] 30초 내 종료되지 않음. 이 진단에서 시작한 프로세스를 종료합니다."
        try { $process.Kill($true) } catch { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
        Write-Host "[TEST] RESULT: TIMEOUT"
        exit 1
    }

    $reply = if (Test-Path -LiteralPath $stdoutPath) { [System.IO.File]::ReadAllText($stdoutPath).Trim() } else { '' }
    if ($process.ExitCode -eq 0 -and $reply -ceq 'READY') {
        Write-Host "[TEST] RESULT: PASS (READY, exit 0)"
        exit 0
    }
    Write-Host "[TEST] RESULT: FAIL (exit $($process.ExitCode), READY 응답 확인 실패)"
    Write-Host "[TEST] 진단 stderr: $stderrPath"
    exit 1
} catch {
    Write-Host "[TEST] RESULT: FAIL (프로세스 실행 오류: $($_.Exception.Message))"
    exit 1
}
