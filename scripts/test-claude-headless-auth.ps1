# 무인(비대화형) claude.exe 인증 테스트 — Codex→Claude 예약작업 이관 사전 점검용.
# 실행: pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\test-claude-headless-auth.ps1
# 성공 기준: 30초 이내 "READY" 한 줄만 출력되고 종료(exit 0). 로그인/승인 프롬프트가 뜨면 그 화면을 캡처해서 공유해주세요.

$claudeBin = if ($env:CLAUDE_CODEX_CLAUDE_BIN) { $env:CLAUDE_CODEX_CLAUDE_BIN } else { "claude" }

Write-Host "[TEST] 사용 바이너리: $claudeBin"
Write-Host "[TEST] 실행 시작 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

$promptPath = Join-Path ([System.IO.Path]::GetTempPath()) "claude-headless-test-prompt.txt"
[System.IO.File]::WriteAllText($promptPath, "reply with exactly one word, uppercase: READY", (New-Object System.Text.UTF8Encoding($false)))

$stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) "claude-headless-test-stdout.log"
$stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) "claude-headless-test-stderr.log"
Remove-Item -Path $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue

$argList = @(
    "-p",
    "--output-format", "text",
    "--model", "sonnet",
    "--permission-mode", "bypassPermissions"
)
$quotedArgs = $argList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
$argumentString = [string]::Join(' ', $quotedArgs)

$process = Start-Process -FilePath $claudeBin -ArgumentList $argumentString `
    -RedirectStandardInput $promptPath -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath `
    -PassThru -NoNewWindow

$finished = $process.WaitForExit(30000)

if (-not $finished) {
    Write-Host "[TEST] 30초 내 종료되지 않음 — 로그인/승인 프롬프트로 멈춰있을 가능성. 강제 종료합니다."
    try { $process.Kill($true) } catch { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    Write-Host "[TEST] RESULT: TIMEOUT (FAIL로 간주)"
} else {
    Write-Host "[TEST] 종료 코드: $($process.ExitCode)"
    Write-Host "[TEST] --- stdout ---"
    Get-Content $stdoutPath -ErrorAction SilentlyContinue
    Write-Host "[TEST] --- stderr ---"
    Get-Content $stderrPath -ErrorAction SilentlyContinue
    if ($process.ExitCode -eq 0) {
        Write-Host "[TEST] RESULT: PASS (무인 실행 가능)"
    } else {
        Write-Host "[TEST] RESULT: FAIL (exit $($process.ExitCode))"
    }
}
