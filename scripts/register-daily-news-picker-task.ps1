[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
param(
    [string]$TaskPath = "\DailyNewsPicker\",
    [string]$TaskName = "IncheonEducationNews",
    [string]$ScriptPath = $(Join-Path $env:USERPROFILE ".codex\skills\daily-news-picker\scripts\run-daily-news-picker.ps1"),
    [string]$BasePath = $(if ($env:DAILY_NEWS_OUTPUT_DIR) { $env:DAILY_NEWS_OUTPUT_DIR } else { Join-Path $env:USERPROFILE "Documents\Codex\DailyNewsPicker" }),
    [string]$WorkingRoot = $env:USERPROFILE,
    [string]$StartTime = "05:00",
    [string]$SiteDir = $env:EDU_NEWS_SITE_DIR,
    [switch]$EnablePublicPush,
    [switch]$DangerouslyBypassApprovalsAndSandbox
)

$ErrorActionPreference = "Stop"

$PowerShellExe = if (Test-Path "C:\Program Files\PowerShell\7\pwsh.exe") {
    "C:\Program Files\PowerShell\7\pwsh.exe"
} else {
    "pwsh.exe"
}

if ($EnablePublicPush -and [string]::IsNullOrWhiteSpace($SiteDir)) {
    throw "공개 배포를 켜려면 -SiteDir를 지정하세요."
}

$runnerArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", "`"$ScriptPath`"",
    "-BasePath", "`"$BasePath`"",
    "-WorkingRoot", "`"$WorkingRoot`"",
    "-CollectionTime", "`"$StartTime`"",
    "-EnablePublicPush:$($EnablePublicPush.IsPresent)"
)

if (-not [string]::IsNullOrWhiteSpace($SiteDir)) {
    $runnerArgs += "-SiteDir"
    $runnerArgs += "`"$SiteDir`""
}

if ($DangerouslyBypassApprovalsAndSandbox) {
    $runnerArgs += "-DangerouslyBypassApprovalsAndSandbox"
}

$runnerArgumentString = [string]::Join(' ', $runnerArgs)
$taskCommand = "schtasks /Create /SC DAILY /TN `"$($TaskPath)$TaskName`" /ST $StartTime /TR `"$PowerShellExe $runnerArgumentString`" /F"

if ($PSCmdlet.ShouldProcess("$($TaskPath)$TaskName", "Register or replace daily task at $StartTime")) {
    $action = New-ScheduledTaskAction -Execute $PowerShellExe -Argument $runnerArgumentString
    $trigger = New-ScheduledTaskTrigger -Daily -At $StartTime
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
}

Write-Host "등록 대상: $($TaskPath)$TaskName"
Write-Host "실행 명령: $taskCommand"
Write-Host "정적 사이트: $(if ($SiteDir) { $SiteDir } else { '미설정 (로컬 다이제스트까지만)' })"
Write-Host "공개 push: $($EnablePublicPush.IsPresent)"
