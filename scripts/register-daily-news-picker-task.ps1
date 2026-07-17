param(
    [string]$TaskPath = "\DailyNewsPicker\",
    [string]$TaskName = "IncheonEducationNews",
    [string]$ScriptPath = $(Join-Path $env:USERPROFILE ".codex\skills\daily-news-picker\scripts\run-daily-news-picker.ps1"),
    [string]$BasePath = $(if ($env:DAILY_NEWS_OUTPUT_DIR) { $env:DAILY_NEWS_OUTPUT_DIR } else { Join-Path $env:USERPROFILE "Documents\Codex\DailyNewsPicker" }),
    [string]$WorkingRoot = $env:USERPROFILE,
    [string]$StartTime = "09:00",
    [switch]$DangerouslyBypassApprovalsAndSandbox
)

$ErrorActionPreference = "Stop"

$PowerShellExe = if (Test-Path "C:\Program Files\PowerShell\7\pwsh.exe") {
    "C:\Program Files\PowerShell\7\pwsh.exe"
} else {
    "pwsh.exe"
}

$runnerArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", "`"$ScriptPath`"",
    "-BasePath", "`"$BasePath`"",
    "-WorkingRoot", "`"$WorkingRoot`""
)

if ($DangerouslyBypassApprovalsAndSandbox) {
    $runnerArgs += "-DangerouslyBypassApprovalsAndSandbox"
}

$runnerArgumentString = [string]::Join(' ', $runnerArgs)
$taskCommand = "schtasks /Create /SC DAILY /TN `"$($TaskPath)$TaskName`" /ST $StartTime /TR `"$PowerShellExe $runnerArgumentString`" /F"

$action = New-ScheduledTaskAction -Execute $PowerShellExe -Argument $runnerArgumentString
$trigger = New-ScheduledTaskTrigger -Daily -At $StartTime
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null

Write-Host "등록 완료: $($TaskPath)$TaskName"
Write-Host "실행 명령: $taskCommand"
